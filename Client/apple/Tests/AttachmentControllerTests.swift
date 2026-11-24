import Foundation
import CryptoKit
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private final class TransferFixture: AttachmentServing, @unchecked Sendable {
    private let lock = NSLock()
    private var infos: [String: AttachmentInfo] = [:]
    private var values: [String: RemoteAttachment] = [:]
    private var continuations: [AsyncThrowingStream<HTTPEvent, Error>.Continuation] = []
    private var revision: UInt64 = 1
    private var createCount = 0, uploadCount = 0, cancelCount = 0
    private var downloadCount = 0, receiptCount = 0
    private var incoming: [String: Data] = [:]
    var failFirstReceipt = false
    var deliveryCounts: (Int, Int) { lock.withLock { (downloadCount, receiptCount) } }
    func provide(_ id: String, ciphertext: Data) { lock.withLock { incoming[id] = ciphertext } }
    private var bodies: [Data] = []
    private var cleanup: [String] = []
    private var pending: CheckedContinuation<Void, Never>?
    var failCreate = false, failUpload = false, holdUpload = false, completeWins = false
    var counts: (Int,Int,Int) { lock.withLock { (createCount, uploadCount, cancelCount) } }
    var uploadedBodies: [Data] { lock.withLock { bodies } }
    var cleaned: [String] { lock.withLock { cleanup } }
    func info(_ id: String) -> AttachmentInfo? { lock.withLock { infos[id] } }
    var isHeld: Bool { lock.withLock { pending != nil } }
    var streamCount: Int { lock.withLock { continuations.count } }
    func failFeed(_ error: Error) {
        let targets = lock.withLock { continuations }
        for continuation in targets { continuation.finish(throwing: error) }
    }

    func value(_ info: AttachmentInfo, state: RemoteAttachmentState, revision: UInt64) -> RemoteAttachment {
        let full = state.isUploaded
        let count = Int((info.ciphertextSize + Int64(AttachmentTransport.chunkBytes) - 1) / Int64(AttachmentTransport.chunkBytes))
        return RemoteAttachment(id: info.id, room_id: info.roomID, ciphertext_size: info.ciphertextSize,
            uploaded_chunks: full ? count : 0, ciphertext_sha256: info.digest, state: state, revision: revision,
            updated_at: Int64(Date().timeIntervalSince1970), completed_at: full ? Int64(Date().timeIntervalSince1970) : 0,
            expires_at: Int64(Date().timeIntervalSince1970) + 900, protocol_version: 3,
            chunk_bytes: AttachmentTransport.chunkBytes, chunk_sha256: nil)
    }
    func create(_ info: AttachmentInfo, recipients: [String]) async throws -> RemoteAttachment {
        let result = lock.withLock {
            createCount += 1; infos[info.id] = info
            let result = value(info, state: .reserved, revision: 1); values[info.id] = result
            return result
        }
        if failCreate { throw URLError(.networkConnectionLost) }
        return result
    }
    func status(_ info: AttachmentInfo) async throws -> RemoteAttachment { try lock.withLock {
        guard let value = values[info.id] else { throw ClientFailure(.attachmentUnavailable, httpStatus: 404) }; return value
    } }
    func catalog() async throws -> AttachmentCatalog { lock.withLock {
        AttachmentCatalog(server_id: "fixture", room_id: "friends", revision: revision, attachments: Array(values.values))
    } }
    func events() -> AttachmentEventSubscription {
        let pair = AsyncThrowingStream<HTTPEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        lock.withLock { continuations.append(pair.continuation) }
        return AttachmentEventSubscription(events: pair.stream, cancel: { pair.continuation.finish() })
    }
    func publish(_ info: AttachmentInfo, state: RemoteAttachmentState, objectRevision: UInt64) throws {
        let event = try lock.withLock {
            infos[info.id] = info; values[info.id] = value(info, state: state, revision: objectRevision); revision += 1
            return HTTPEvent(name: "state", data: try JSONSerialization.data(withJSONObject: [
                "server_id": "fixture", "room_id": "friends", "revision": revision]))
        }
        let targets = lock.withLock { continuations }
        for continuation in targets { continuation.yield(event) }
    }
    func upload(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                progress: @escaping @Sendable (Double) async -> Void) async throws -> RemoteAttachment {
        let attempt = try lock.withLock {
            uploadCount += 1; bodies.append(try Data(contentsOf: lease.url(info.id))); return uploadCount
        }
        await progress(0.5)
        if failUpload && attempt == 1 { throw URLError(.networkConnectionLost) }
        if holdUpload { await withCheckedContinuation { continuation in lock.withLock { pending = continuation } } }
        // Deliberately uncooperative: exercise stale progress and completion.
        await progress(1)
        return value(info, state: .completed, revision: 5)
    }
    func release() { lock.withLock { let held = pending; pending = nil; return held }?.resume() }
    func download(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        try await authorize()
        let ciphertext = try lock.withLock {
            downloadCount += 1
            guard let ciphertext = incoming[info.id] else { throw URLError(.networkConnectionLost) }
            return ciphertext
        }
        try ciphertext.write(to: lease.url(info.id))
        try AttachmentCrypto.validateCiphertext(info: info, lease: lease)
        await progress(1)
    }
    func cancel(_ info: AttachmentInfo) async throws -> RemoteAttachment {
        lock.withLock { cancelCount += 1 }
        return value(info, state: completeWins ? .completed : .cancelled, revision: 6)
    }
    func received(_ info: AttachmentInfo) async throws -> RemoteAttachment {
        let count = lock.withLock { receiptCount += 1; return receiptCount }
        if failFirstReceipt && count == 1 { throw URLError(.networkConnectionLost) }
        return value(info, state: .delivered, revision: 7)
    }
    func pause(_ id: String) async {}
    func reportCancellation(_ ids: [String]) async { lock.withLock { cleanup.append(contentsOf: ids) } }
    func close() {}
}

@MainActor private final class TransferControllerHarness {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let fixture = TransferFixture()
    let controller: RoomAttachmentController
    let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "member_test.login_test.entry")
    var audience = AttachmentAudience(groupID: "friends/server/session/1", identities: ["member_test.login_test.entry"])
    var announcements = 0
    var failAnnouncement = false
    init() throws {
        let cache = AttachmentCache(directory: root.appendingPathComponent("cache"))
        let fixture = fixture
        controller = RoomAttachmentController(cache: cache, makeTransport: { _,_,_ in fixture })
        let login = try ClientSession(data: JSONSerialization.data(withJSONObject: [
            "member": ["id": "member_test", "display_name": "Test"],
            "credential": "chirp_" + String(repeating: "c", count: 43),
            "participant_identity": "member_test.login_test", "expires_at": Int(Date().timeIntervalSince1970) + 3600
        ]), connection: testServerConnection)
        controller.begin(login: login, admission: admission, authorize: {}, audience: { [unowned self] in audience },
            announce: { [unowned self] _,_ in
                announcements += 1
                if failAnnouncement { throw URLError(.networkConnectionLost) }
            })
    }
    func send() throws {
        let url = root.appendingPathComponent("source.bin")
        try Data(repeating: 0x5a, count: 4096).write(to: url)
        controller.send(source: url)
    }
    func close() { controller.end(); fixture.release(); try? FileManager.default.removeItem(at: root) }
    func incomingFile(corrupt: Bool = false) throws -> AttachmentDescriptor {
        let cache = AttachmentCache(directory: root.appendingPathComponent("sender-cache")), lease = try cache.begin()
        defer { cache.end(lease) }
        let source = root.appendingPathComponent("incoming.bin")
        try Data(repeating: 0x67, count: 65_537).write(to: source)
        let info = AttachmentInfo(version: 1, id: UUID().uuidString.replacingOccurrences(of: "-",with:"").lowercased(),
            roomID: "friends", sender: "peer.login.entry", name: "incoming.bin", mimeType: "application/octet-stream",
            size: 65_537, digest: String(repeating:"0",count:64), hasThumbnail:false)
        let key = Data(repeating: 5, count: 32)
        try lease.register(info, key: key)
        let encrypted = try AttachmentCrypto.encrypt(source: source, info: info, lease: lease)
        var bytes = try Data(contentsOf: lease.url(info.id))
        if corrupt { bytes[0] ^= 1 }
        fixture.provide(info.id, ciphertext: bytes)
        return AttachmentDescriptor(info: encrypted, key: key, thumbnail: nil)
    }
    func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<400 { if predicate() { return }; try await Task.sleep(for: .milliseconds(5)) }
        Issue.record("Attachment operation did not reach its expected state")
        throw URLError(.timedOut)
    }
}

@Test @MainActor func attachmentAutomaticallyDownloadsAfterCompletionAndKeepsCacheAfterReceipt() async throws {
    let h = try TransferControllerHarness(); defer { h.close() }
    let descriptor = try h.incomingFile(), info = descriptor.info
    #expect(h.controller.receive(descriptor))
    try h.fixture.publish(info, state: .uploading, objectRevision: 2)
    try await h.wait { h.controller.states[info.id]?.remoteRevision == 2 }
    #expect(h.fixture.deliveryCounts.0 == 0 && h.fixture.deliveryCounts.1 == 0)
    try h.fixture.publish(info, state: .completed, objectRevision: 5)
    try await h.wait { h.controller.states[info.id]?.remoteState == .delivered }
    #expect(h.fixture.deliveryCounts.0 == 1 && h.fixture.deliveryCounts.1 == 1)
    #expect(h.controller.available(info) && h.controller.states[info.id]?.cached == true)
    #expect(h.controller.states[info.id]?.phase == .completed)
    try h.fixture.publish(info, state: .completed, objectRevision: 5)
    try await Task.sleep(for: .milliseconds(40))
    #expect(h.fixture.deliveryCounts.0 == 1 && h.controller.states[info.id]?.remoteState == .delivered)
}

@Test @MainActor func attachmentNeverAcknowledgesCorruptAutomaticDownload() async throws {
    let h = try TransferControllerHarness(); defer { h.close() }
    let descriptor = try h.incomingFile(corrupt: true), info = descriptor.info
    #expect(h.controller.receive(descriptor))
    try h.fixture.publish(info, state: .completed, objectRevision: 5)
    try await h.wait { h.controller.states[info.id]?.phase == .failed }
    #expect(h.fixture.deliveryCounts.0 == 1 && h.fixture.deliveryCounts.1 == 0)
    #expect(h.controller.states[info.id]?.cached == false)
}

@Test @MainActor func attachmentReceiptRetriesWithoutDownloadingAgain() async throws {
    let h = try TransferControllerHarness(); defer { h.close() }
    h.fixture.failFirstReceipt = true
    let descriptor = try h.incomingFile(), info = descriptor.info
    #expect(h.controller.receive(descriptor))
    try h.fixture.publish(info, state: .completed, objectRevision: 5)
    try await h.wait { h.controller.states[info.id]?.cached == true && h.fixture.deliveryCounts.1 == 1 }
    #expect(h.controller.states[info.id]?.phase == .completed)
    for _ in 0..<600 {
        if h.controller.states[info.id]?.remoteState == .delivered { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(h.fixture.deliveryCounts.0 == 1 && h.fixture.deliveryCounts.1 == 2)
    #expect(h.controller.states[info.id]?.remoteState == .delivered)
}

@Test @MainActor func uploadRetriesCiphertextWithoutReannouncingToChangedMembership() async throws {
    let h=try TransferControllerHarness(); defer { h.close() }
    h.fixture.failUpload = true
    try h.send(); try await h.wait { h.controller.states.values.first?.phase == .retryableFailure && !h.controller.isSending }
    let id = try #require(h.controller.states.keys.first)
    let info = try #require(h.fixture.info(id))
    h.audience = AttachmentAudience(groupID: "friends/server/session/2", identities: [h.admission.identity,"late.login.entry"])
    h.controller.retry(info)
    try await h.wait { h.controller.states[info.id]?.phase == .completed && !h.controller.isSending }
    #expect(h.announcements == 1 && h.fixture.counts.0 == 1 && h.fixture.counts.1 == 2)
    #expect(h.fixture.uploadedBodies.count == 2 && h.fixture.uploadedBodies[0] == h.fixture.uploadedBodies[1])
}

@Test @MainActor func unpublishedReservationCannotRetryThroughANewGroupAndAmbiguousPublicationCancels() async throws {
    for ambiguous in [false,true] {
        let h=try TransferControllerHarness(); defer { h.close() }
        h.fixture.failCreate = !ambiguous; h.failAnnouncement = ambiguous
        try h.send()
        if !ambiguous {
            try await h.wait { h.controller.states.values.first?.phase == .retryableFailure && !h.controller.isSending }
            let info=try #require(h.controller.unpublished.first)
            h.audience = AttachmentAudience(groupID:"friends/server/session/2",identities:[h.admission.identity])
            h.controller.retry(info)
        }
        try await h.wait { h.controller.states.values.first?.phase == .cancelled }
        #expect(h.fixture.counts.1 == 0 && h.fixture.counts.2 == 1)
        #expect(h.announcements == (ambiguous ? 1 : 0))
        #expect(h.controller.unpublished.isEmpty)
    }
}

@Test @MainActor func cancelUsesServerWinnerAndCacheClearIgnoresLateProgressAndCompletion() async throws {
    for clear in [false,true] {
        let h=try TransferControllerHarness(); defer { h.close() }
        h.fixture.holdUpload=true; h.fixture.completeWins=true
        try h.send(); try await h.wait { h.fixture.isHeld }
        let id=try #require(h.controller.states.keys.first)
        let info=try #require(h.fixture.info(id))
        if clear {
            h.controller.cacheWasCleared()
            #expect(h.controller.states.isEmpty && !h.controller.available(info) && !h.controller.isSending)
        } else {
            h.controller.cancelUpload(info)
            #expect(h.controller.states[id]?.phase == .cancelling)
        }
        h.fixture.release()
        if clear {
            try await h.wait { h.fixture.cleaned.contains(id) }
            try await Task.sleep(for:.milliseconds(40))
            #expect(h.controller.states.isEmpty && !h.controller.available(info))
        } else {
            try await h.wait { h.controller.states[id]?.phase == .completed }
            #expect(h.controller.available(info) && h.controller.states[id]?.cached == true)
        }
    }
}

@Test @MainActor func receiverObservesCancellationWithoutStartingDownloadAndRejectsLateSnapshot() async throws {
    let h=try TransferControllerHarness(); defer { h.close() }
    let info=AttachmentInfo(version:1,id:String(repeating:"a",count:32),roomID:"friends",sender:"peer.login.entry",name:"file.bin",mimeType:"application/octet-stream",size:32,digest:String(repeating:"0",count:64),hasThumbnail:false)
    #expect(h.controller.receive(AttachmentDescriptor(info:info,key:Data(repeating:7,count:32),thumbnail:nil)))
    try h.fixture.publish(info,state:.reserved,objectRevision:1)
    try await h.wait { h.controller.states[info.id]?.remoteRevision == 1 }
    try h.fixture.publish(info,state:.cancelled,objectRevision:4)
    try await h.wait { h.controller.states[info.id]?.phase == .cancelled }
    #expect(!h.controller.available(info))
    try h.fixture.publish(info,state:.uploading,objectRevision:2)
    try await Task.sleep(for:.milliseconds(40))
    #expect(h.controller.states[info.id]?.phase == .cancelled && h.controller.states[info.id]?.remoteRevision == 4)
}

@Test @MainActor func attachmentStreamAuthenticationLossSynchronouslyRetiresAdmissionKeys() async throws {
    let h=try TransferControllerHarness(); defer { h.close() }
    let info=AttachmentInfo(version:1,id:String(repeating:"b",count:32),roomID:"friends",sender:"peer.login.entry",name:"file.bin",mimeType:"application/octet-stream",size:32,digest:String(repeating:"0",count:64),hasThumbnail:false)
    let descriptor=AttachmentDescriptor(info:info,key:Data(repeating:7,count:32),thumbnail:nil)
    #expect(h.controller.receive(descriptor))
    try await h.wait { h.fixture.streamCount == 1 }
    h.fixture.failFeed(APIError.unauthorized)
    try await h.wait { !h.controller.available(info) }
    #expect(h.controller.states.isEmpty && !h.controller.receive(descriptor))
}
