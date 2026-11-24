import Foundation
import CryptoKit
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Suite(.serialized) struct AttachmentHTTPTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_ATTACHMENT_TEST_CONFIG"] != nil))
    func interoperabilityAndFailureRecovery() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["CHIRP_ATTACHMENT_TEST_CONFIG"])
        struct Client: Decodable {
            let credential: String; let room_id: String; let entry_id: String; let identity: String
            var admission: RoomAdmission { RoomAdmission(roomID: room_id, entryID: entry_id, identity: identity) }
        }
        struct Fixture: Decodable { let url: URL; let clients: [Client] }
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: URL(filePath: path)))
        let a = fixture.clients[0], b = fixture.clients[1], late = fixture.clients[2]
        let budget = AttachmentBandwidth()
        let sender = AttachmentTransport(baseURL: fixture.url, credential: a.credential, admission: a.admission, bandwidth: budget)
        let receiver = AttachmentTransport(baseURL: fixture.url, credential: b.credential, admission: b.admission, bandwidth: budget)
        let outsider = AttachmentTransport(baseURL: fixture.url, credential: late.credential, admission: late.admission)
        let control = URLSession(configuration: .ephemeral)
        defer { sender.close(); receiver.close(); outsider.close(); control.invalidateAndCancel() }
        func fault(method: String, path: String, kind: String, remaining: Int) async throws {
            var request = URLRequest(url: fixture.url.appendingPathComponent("test/fault")); request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["method": method, "path": path, "kind": kind, "remaining": remaining])
            let (_, response) = try await control.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 204)
        }
        func counts() async throws -> [String: [Int]] {
            let (data,_) = try await control.data(from: fixture.url.appendingPathComponent("test/requests"))
            return try JSONDecoder().decode([String:[Int]].self, from: data)
        }
        let senderEvents = sender.events(), receiverEvents = receiver.events()
        defer { senderEvents.cancel(); receiverEvents.cancel() }
        var senderIterator = senderEvents.events.makeAsyncIterator()
        var receiverIterator = receiverEvents.events.makeAsyncIterator()
        _ = try await senderIterator.next(); _ = try await receiverIterator.next()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let original = Data(repeating: 0x78, count: AttachmentTransport.chunkBytes * 3 + 19)
        let source = root.appendingPathComponent("original"); try original.write(to: source)
        let cache = AttachmentCache(directory: root.appendingPathComponent("cache", isDirectory: true))
        let alice = try cache.begin(), bob = try cache.begin()
        let metadata = AttachmentInfo(version: 1, id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            roomID: a.room_id, sender: a.identity, name: "interop.bin", mimeType: "application/octet-stream",
            size: Int64(original.count), digest: String(repeating: "0", count: 64), hasThumbnail: false)
        let key = Data(repeating: 3, count: 32)
        try alice.register(metadata, key: key)
        let info = try AttachmentCrypto.encrypt(source: source, info: metadata, lease: alice)
        let sealed = try Data(contentsOf: alice.url(info.id))
        try FileManager.default.removeItem(at: source)
        try bob.register(info, key: key)
        let remote = try await sender.create(info, recipients: [a.identity, b.identity])
        #expect(remote.state == .reserved && remote.chunk_bytes == AttachmentTransport.chunkBytes)
        _ = try await sender.create(info, recipients: [b.identity, a.identity, b.identity])
        let pending = try await receiver.status(info)
        #expect(pending.uploaded_chunks == 0 && pending.chunk_sha256 == nil)
        let base = "/v1/rooms/\(a.room_id)/attachments/\(info.id)"
        try await fault(method: "PUT", path: base + "/chunks/0", kind: "lost_ack", remaining: 1)
        try await fault(method: "PUT", path: base + "/chunks/1", kind: "busy", remaining: 1)
        try await fault(method: "PUT", path: base + "/chunks/2", kind: "unavailable", remaining: 4)
        let start = ContinuousClock.now
        do { _ = try await sender.upload(info, lease: alice, authorize: {}, progress: { _ in }); Issue.record("Persistent service failure completed an upload") }
        catch let error as ClientFailure { #expect(error.httpStatus == 503) }
        #expect(start.duration(to: .now) >= .seconds(1))
        let partial = try await receiver.status(info)
        #expect(partial.state == .uploading && partial.uploaded_chunks == 2 && partial.chunk_sha256?.count == 2)
        let before = try await counts()
        // A server progress claim is not trusted without matching local bytes.
        try await fault(method: "GET", path: base, kind: "bad_prefix", remaining: 1)
        do { _ = try await sender.upload(info, lease: alice, authorize: {}, progress: { _ in }); Issue.record("Mismatching committed prefix accepted") }
        catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentIntegrity.rawValue) }
        #expect(try await counts() == before)
        let completed = try await sender.upload(info, lease: alice, authorize: {}, progress: { _ in })
        #expect(completed.state == .completed && completed.uploaded_chunks == completed.chunkCount)
        let afterUpload = try await counts()
        #expect(afterUpload["PUT " + base + "/chunks/0"] == before["PUT " + base + "/chunks/0"])
        #expect(afterUpload["PUT " + base + "/chunks/1"] == before["PUT " + base + "/chunks/1"])
        #expect(try Data(contentsOf: alice.url(info.id)) == sealed)
        // Download a verified prefix, repeatedly tear the next response, then
        // corrupt one local chunk. Resume must retain only the valid prefix.
        try await fault(method: "GET", path: base + "/chunks/2", kind: "torn_download", remaining: 4)
        do { try await receiver.download(info, lease: bob, authorize: {}, progress: { _ in }); Issue.record("Torn response completed a download") }
        catch { #expect(AttachmentTransport.retryable(error)) }
        let saved = try bob.partialURL(info.id)
        var bytes = try Data(contentsOf: saved)
        #expect(bytes.count == 2 * AttachmentTransport.chunkBytes)
        #expect(!FileManager.default.fileExists(atPath: try bob.url(info.id).path))
        bytes[AttachmentTransport.chunkBytes] ^= 1; try bytes.write(to: saved)
        let beforeResume = try await counts()
        try await receiver.download(info, lease: bob, authorize: {}, progress: { _ in })
        let afterResume = try await counts()
        #expect(afterResume["GET " + base + "/chunks/0"] == beforeResume["GET " + base + "/chunks/0"])
        #expect(afterResume["GET " + base + "/chunks/1"]?.count == (beforeResume["GET " + base + "/chunks/1"]?.count ?? 0) + 1)
        #expect(!FileManager.default.fileExists(atPath: saved.path))
        var restored = Data()
        try AttachmentCrypto.decrypt(info: info, lease: bob) { restored.append($0) }
        #expect(restored == original)
        #expect(try await sender.cancel(info).state == .completed)
        do { _ = try await outsider.status(info); Issue.record("Non-recipient obtained metadata") }
        catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentUnavailable.rawValue) }
        do { _ = try await sender.create(info, recipients: [a.identity, b.identity, late.identity]); Issue.record("Retry expanded the original audience") }
        catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentConflict.rawValue) }
        // Completed retries do not upload any chunks or need the source file.
        let beforeNoop = try await counts()
        _ = try await sender.upload(info, lease: alice, authorize: {}, progress: { _ in })
        #expect(try await counts() == beforeNoop)
        let cancelInfo = AttachmentInfo(version: 1, id: String(repeating: "f", count: 32), roomID: a.room_id,
            sender: a.identity, name: "cancel.bin", mimeType: "application/octet-stream", size: 32,
            digest: String(repeating: "0", count: 64), hasThumbnail: false)
        _ = try await sender.create(cancelInfo, recipients: [a.identity,b.identity])
        let cancelled = try await sender.cancel(cancelInfo)
        let receiverCancelled = try await receiver.status(cancelInfo)
        #expect(cancelled.state == .cancelled && receiverCancelled.state == .cancelled)
        do { _ = try await sender.create(cancelInfo, recipients: [a.identity,b.identity]); Issue.record("Cancelled object restarted") }
        catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentCancelled.rawValue) }
        // A receipt response can disappear after the last client triggers deletion.
        try await fault(method: "POST", path: base + "/received", kind: "lost_ack", remaining: 1)
        let delivered = try await receiver.received(info)
        #expect(delivered.state == .delivered)
        #expect(try await receiver.received(info).state == .delivered)
        #expect(try await sender.upload(info, lease: alice, authorize: {}, progress: { _ in }).state == .delivered)
        var stillLocal = Data()
        try AttachmentCrypto.decrypt(info: info, lease: bob) { stillLocal.append($0) }
        #expect(stillLocal == original)
        // Exercise enough data to leave startup bursts behind and report actual
        // loopback throughput. This is not a WAN or simultaneous voice benchmark.
        let largeBytes = Data(repeating: 0x71, count: 32 * 1024 * 1024)
        let largeSource = root.appendingPathComponent("large.bin"); try largeBytes.write(to: largeSource)
        let largeMetadata = AttachmentInfo(version: 1, id: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased(),
            roomID: a.room_id, sender: a.identity, name: "large.bin", mimeType: "application/octet-stream",
            size: Int64(largeBytes.count), digest: String(repeating: "0", count: 64), hasThumbnail: false)
        let largeKey = Data(repeating: 9, count: 32)
        try alice.register(largeMetadata, key: largeKey)
        let large = try AttachmentCrypto.encrypt(source: largeSource, info: largeMetadata, lease: alice)
        try bob.register(large, key: largeKey)
        _ = try await sender.create(large, recipients: [a.identity, b.identity])
        let uploadStart = ContinuousClock.now
        _ = try await sender.upload(large, lease: alice, authorize: {}, progress: { _ in })
        let downloadStart = ContinuousClock.now
        try await receiver.download(large, lease: bob, authorize: {}, progress: { _ in })
        let downloadEnd = ContinuousClock.now
        var decodedHash = SHA256()
        try AttachmentCrypto.decrypt(info: large, lease: bob) { decodedHash.update(data: $0) }
        #expect(decodedHash.finalize() == SHA256.hash(data: largeBytes))
        #expect(try await receiver.received(large).state == .delivered)
        func seconds(_ duration: Duration) -> Double {
            Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        }
        let uploadSeconds = seconds(uploadStart.duration(to: downloadStart))
        let downloadSeconds = seconds(downloadStart.duration(to: downloadEnd))
        print(String(format: "Attachment loopback benchmark: 32 MiB, upload %.2f MiB/s, download %.2f MiB/s, total %.2f s (8 MiB/s policy; no voice or WAN).",
            32 / uploadSeconds, 32 / downloadSeconds, uploadSeconds + downloadSeconds))
        let api = APIClient(baseURL: fixture.url, credential: b.credential)
        try await api.leave(b.admission); api.close()
        do { _ = try await receiver.status(info); Issue.record("Departed entry retained permission") }
        catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentUnavailable.rawValue) }
        try cache.clearAll()
        #expect(!alice.contains(info.id) && !bob.contains(info.id))
        print("Attachment fault checks: uploaded prefix resumed at chunk 2; download retained chunk 0 and replaced corrupt chunk 1; 429 Retry-After and lost ACK recovered; ciphertext unchanged.")
    }
}
