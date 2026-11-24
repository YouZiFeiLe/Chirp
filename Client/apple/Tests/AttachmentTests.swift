import Foundation
import CryptoKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Testing
import ChirpMLS
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private func attachmentInfo(id: String = String(repeating: "a", count: 32), size: Int64) -> AttachmentInfo {
    AttachmentInfo(version: 1, id: id, roomID: "friends", sender: "alice.login.entry", name: "example.bin",
        mimeType: "application/octet-stream", size: size, digest: String(repeating: "0", count: 64), hasThumbnail: false)
}

@Test func attachmentStreamsLargeFilesAndRetiresAllKeysOnClear() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("source")
    #expect(FileManager.default.createFile(atPath: source.path, contents: nil))
    let writer = try FileHandle(forWritingTo: source)
    let chunk = Data(repeating: 0x6b, count: AttachmentInfo.chunkBytes)
    var sourceHash = SHA256()
    for _ in 0..<400 { try writer.write(contentsOf: chunk); sourceHash.update(data: chunk) }
    try writer.close()
    let cache = AttachmentCache(directory: root.appendingPathComponent("cache", isDirectory: true))
    let lease = try cache.begin()
    let info = attachmentInfo(size: AttachmentInfo.maxFileBytes)
    try lease.register(info, key: Data(repeating: 0x5d, count: 32))
    let encrypted = try AttachmentCrypto.encrypt(source: source, info: info, lease: lease)
    #expect(throws: (any Error).self) { try AttachmentCrypto.encrypt(source: source, info: info, lease: lease) }
    var decodedHash = SHA256(), maximumChunk = 0, count = 0
    try AttachmentCrypto.decrypt(info: encrypted, lease: lease) { data in
        maximumChunk = max(maximumChunk, data.count); decodedHash.update(data: data); count += 1
    }
    #expect(decodedHash.finalize() == sourceHash.finalize())
    #expect(maximumChunk == AttachmentInfo.chunkBytes && count == 400)
    #expect(cache.size() == encrypted.ciphertextSize)
    let file = try lease.url(info.id)
    try cache.clearAll()
    #expect(!lease.contains(info.id))
    #expect(cache.size() == 0 && !FileManager.default.fileExists(atPath: file.path))
    #expect(throws: (any Error).self) { try AttachmentCrypto.decrypt(info: encrypted, lease: lease) { _ in } }
    #expect(throws: (any Error).self) { try lease.register(info, key: Data(repeating: 1, count: 32)) }
    let reentry = try cache.begin()
    #expect(!reentry.contains(info.id))
    cache.end(reentry)
}

@Test func attachmentRejectsTamperingTruncationReorderingAndWrongContext() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("original")
    try Data(repeating: 7, count: AttachmentInfo.chunkBytes * 2 + 11).write(to: source)
    let cache = AttachmentCache(directory: root.appendingPathComponent("cache", isDirectory: true)), lease = try cache.begin()
    let info = attachmentInfo(size: Int64(AttachmentInfo.chunkBytes * 2 + 11))
    try lease.register(info, key: Data(repeating: 8, count: 32))
    let encrypted = try AttachmentCrypto.encrypt(source: source, info: info, lease: lease)
    let url = try lease.url(info.id), ciphertext = try Data(contentsOf: url)
    #expect(!ciphertext.prefix(64).allSatisfy { $0 == 7 })
    var tampered = ciphertext; tampered[0] ^= 1
    let boundary = AttachmentInfo.chunkBytes + 16
    let reordered = ciphertext.subdata(in: boundary..<(boundary * 2)) + ciphertext.prefix(boundary) + ciphertext.suffix(27)
    for invalid in [tampered, Data(ciphertext.dropLast()), ciphertext + Data([0]), reordered] {
        try invalid.write(to: url)
        #expect(throws: (any Error).self) { try AttachmentCrypto.validateCiphertext(info: encrypted, lease: lease) }
    }
    try ciphertext.write(to: url)
    let wrong = AttachmentInfo(version: encrypted.version, id: encrypted.id, roomID: "other", sender: encrypted.sender,
        name: encrypted.name, mimeType: encrypted.mimeType, size: encrypted.size, digest: encrypted.digest, hasThumbnail: false)
    #expect(throws: (any Error).self) { try AttachmentCrypto.validateCiphertext(info: wrong, lease: lease) }
    let thumb = try AttachmentCrypto.thumbnail(Data("private thumbnail".utf8), info: encrypted, lease: lease, decrypt: false)
    #expect(try AttachmentCrypto.thumbnail(thumb, info: encrypted, lease: lease, decrypt: true) == Data("private thumbnail".utf8))
    cache.end(lease)
}

@Test func attachmentEmptyFilesAndStartupRecoveryNeverRestoreKeysOrFollowSymlinks() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let outside = root.appendingPathComponent("user-saved-file")
    try Data("keep".utf8).write(to: outside)
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(at: cacheURL.appendingPathComponent("escaped"), withDestinationURL: outside)
    try Data("old ciphertext".utf8).write(to: cacheURL.appendingPathComponent("crashed.partial"))
    let cache = AttachmentCache(directory: cacheURL)
    #expect(cache.size() == 0)
    #expect(try Data(contentsOf: outside) == Data("keep".utf8))
    let lease = try cache.begin(), info = attachmentInfo(size: 0)
    let empty = root.appendingPathComponent("empty"); try Data().write(to: empty)
    try lease.register(info, key: Data(repeating: 9, count: 32))
    let encrypted = try AttachmentCrypto.encrypt(source: empty, info: info, lease: lease)
    #expect(encrypted.ciphertextSize == 16)
    try AttachmentCrypto.validateCiphertext(info: encrypted, lease: lease)
    cache.end(lease)
}

@Test func attachmentChatBindsMetadataAndKeysToThePublishingGeneration() throws {
    let a = RoomAdmission(roomID: "friends", entryID: "entry", identity: "alice.login.entry")
    let b = RoomAdmission(roomID: "friends", entryID: "entryB", identity: "bob.login.entryB")
    let members = [a,b].map { MLSPeer(identity: $0.identity, name: "friend", publicKey: "", keyPackage: "") }
    var alice = RoomChat(), bob = RoomChat()
    alice.begin(a); bob.begin(b)
    for generation in ["friends/server/session/1"] {
        alice.install(groupID: generation, members: members); alice.activate()
        bob.install(groupID: generation, members: members); bob.activate()
    }
    let descriptor = AttachmentDescriptor(info: attachmentInfo(size: 32), key: Data(repeating: 5, count: 32), thumbnail: nil)
    let (envelope, wire) = try alice.prepareAttachment(descriptor)
    #expect(wire.count < RoomChat.maxPacketBytes)
    #expect({ !bob.receive(wire, sender: a.identity, encrypted: false, onAttachment: { _ in true }) }())
    var accepted = 0
    #expect({ bob.receive(wire, sender: a.identity, encrypted: true, onAttachment: { _ in accepted += 1; return true }) }())
    #expect(accepted == 1 && bob.messages.last?.attachment == descriptor.info && bob.messages.last?.text == "")
    #expect({ !bob.receive(wire, sender: a.identity, encrypted: true, onAttachment: { _ in accepted += 1; return true }) }())
    alice.pause(); alice.install(groupID: "friends/server/session/2", members: members); alice.activate()
    #expect(alice.pendingID == nil && alice.messages.last?.messageID == envelope.id)
    bob.end(); bob.begin(b); bob.install(groupID: "friends/server/session/2", members: members); bob.activate()
    #expect({ !bob.receive(wire, sender: a.identity, encrypted: true, onAttachment: { _ in true }) }())
    #expect(bob.messages.isEmpty)
}

@Test @MainActor func attachmentControllerClearsAllWindowsAndAllowsNewFilesWithoutRestoringOldKeys() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let cache = AttachmentCache(directory: root)
    let login = try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "member": ["id": "member_test", "display_name": "Test"],
        "credential": "chirp_" + String(repeating: "c", count: 43),
        "participant_identity": "member_test.login_test", "expires_at": Int(Date().timeIntervalSince1970) + 3600
    ]), connection: testServerConnection)
    let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "member_test.login_test.entry")
    let windows = [RoomAttachmentController(cache: cache), RoomAttachmentController(cache: cache)]
    let descriptor = AttachmentDescriptor(info: attachmentInfo(size: 32), key: Data(repeating: 6, count: 32), thumbnail: nil)
    for window in windows {
        window.begin(login: login, admission: admission, authorize: {},
            audience: { AttachmentAudience(groupID: "friends/server/session/1", identities: [admission.identity]) }, announce: { _, _ in })
        #expect(window.receive(descriptor))
        #expect(window.available(descriptor.info))
    }
    try cache.clearAll()
    for window in windows {
        #expect(!window.available(descriptor.info))
        window.cacheWasCleared()
        #expect(window.states.isEmpty && !window.isSending && window.preview == nil)
        let fresh = AttachmentDescriptor(info: attachmentInfo(id: String(repeating: "b", count: 32), size: 32), key: Data(repeating: 7, count: 32), thumbnail: nil)
        #expect(window.receive(fresh))
        #expect(window.available(fresh.info) && !window.available(descriptor.info))
        window.end()
        #expect(!window.receive(fresh))
    }
}

@Test func attachmentImagePipelineDownsamplesBeforeDisplaying() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let context = try #require(CGContext(data: nil, width: 4096, height: 32, bitsPerComponent: 8, bytesPerRow: 4096 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 4096, height: 32))
    let image = try #require(context.makeImage()), url = root.appendingPathComponent("image.png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    let thumbnail = try AttachmentImages.thumbnail(source: url)
    #expect(thumbnail.count <= AttachmentInfo.maxThumbnailBytes - 28)
    let small = try AttachmentImages.decode(thumbnail, maxPixels: 256)
    #expect(small.image.width <= 256 && small.image.height > 0)
    let preview = try AttachmentImages.decode(Data(contentsOf: url))
    #expect(preview.image.width <= 2048)
    #expect(throws: (any Error).self) { try AttachmentImages.decode(Data("invalid image".utf8)) }
}

private func photoFixture(in root: URL) throws -> URL {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let context = try #require(CGContext(data: nil, width: 80, height: 48, bitsPerComponent: 8, bytesPerRow: 80 * 4,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.3, green: 0.6, blue: 0.2, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: 80, height: 48))
    let image = try #require(context.makeImage()), url = root.appendingPathComponent("original.png")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return url
}

@Test func photoProviderEncryptsItsTemporaryFileWithoutPersistingPlaintext() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try photoFixture(in: root), original = try Data(contentsOf: url)
    let provider = NSItemProvider()
    provider.suggestedName = "Holiday"
    provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { reply in
        reply(url, false, nil); return nil
    }
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    let cache = AttachmentCache(directory: cacheURL), lease = try cache.begin()
    let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "alice.login.entry")
    var descriptor = try await AttachmentPhotoSource(provider: provider).prepare(lease: lease, admission: admission)
    defer { descriptor.key.resetBytes(in: 0..<descriptor.key.count) }
    #expect(descriptor.info.name == "Holiday.png" && descriptor.info.mimeType == "image/png")
    #expect(descriptor.info.sender == admission.identity && descriptor.info.roomID == admission.roomID)
    #expect(descriptor.info.hasThumbnail && descriptor.thumbnail != nil)
    try FileManager.default.removeItem(at: url)
    var restored = Data()
    try AttachmentCrypto.decrypt(info: descriptor.info, lease: lease) { restored.append($0) }
    #expect(restored == original)
    let files = try #require(FileManager.default.enumerator(at: cacheURL, includingPropertiesForKeys: [.isRegularFileKey]))
    for case let file as URL in files.allObjects where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
        #expect(["cipher", "thumb"].contains(file.pathExtension))
        #expect(try Data(contentsOf: file) != original)
    }
    cache.end(lease)
    #expect(!lease.contains(descriptor.info.id) && cache.size() == 0)
}

private final class PendingPhotoProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var reply: (@Sendable (URL?, Bool, (any Error)?) -> Void)?
    let progress = Progress(totalUnitCount: 1)
    var requested: Bool { lock.withLock { reply != nil } }

    func provider() -> NSItemProvider {
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { [self] reply in
            lock.withLock { self.reply = reply }; return progress
        }
        return provider
    }

    func complete(with url: URL) { lock.withLock { reply }?(url, false, nil) }
}

@Test func photoImportCancelsCloudLoadingAndIgnoresResultsAfterCacheClear() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try photoFixture(in: root)
    let cache = AttachmentCache(directory: root.appendingPathComponent("cache")), lease = try cache.begin()
    let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "alice.login.entry")
    let pending = PendingPhotoProvider(), source = AttachmentPhotoSource(provider: pending.provider())
    let task = Task { try await source.prepare(lease: lease, admission: admission) }
    for _ in 0..<200 where !pending.requested { try await Task.sleep(for: .milliseconds(5)) }
    try #require(pending.requested)
    try cache.clearAll()
    task.cancel()
    do { _ = try await task.value; Issue.record("Cancelled photo import returned an attachment") }
    catch { #expect(error is CancellationError) }
    #expect(pending.progress.isCancelled)
    pending.complete(with: url)
    try await Task.sleep(for: .milliseconds(50))
    #expect(cache.size() == 0)
    #expect(throws: (any Error).self) {
        try RoomAttachmentController.prepareFile(source: url, lease: lease, admission: admission)
    }
}

@Test func photoPreparationRejectsOversizeAndInvalidImagesWithoutLeavingCacheFiles() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let cache = AttachmentCache(directory: root.appendingPathComponent("cache")), lease = try cache.begin()
    let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "alice.login.entry")
    let url = root.appendingPathComponent("provider-file")
    try Data().write(to: url)
    let writer = try FileHandle(forWritingTo: url)
    try writer.truncate(atOffset: UInt64(AttachmentInfo.maxImageBytes + 1)); try writer.close()
    do {
        _ = try RoomAttachmentController.prepareFile(source: url, lease: lease, admission: admission, contentType: .jpeg, name: "Photo.jpg")
        Issue.record("Oversize photo accepted")
    } catch let error as ClientFailure { #expect(error.code == ClientErrorCode.attachmentQuota.rawValue) }
    #expect(cache.size() == 0)
    try Data("invalid image".utf8).write(to: url)
    #expect(throws: (any Error).self) {
        try RoomAttachmentController.prepareFile(source: url, lease: lease, admission: admission, contentType: .jpeg, name: "Photo.jpg")
    }
    #expect(cache.size() == 0)
    cache.end(lease)
}
