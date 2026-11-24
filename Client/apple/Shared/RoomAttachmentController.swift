import Foundation
import Combine
import CryptoKit
import UniformTypeIdentifiers

struct AttachmentAudience: Sendable, Equatable { let groupID: String; let identities: [String] }
struct AttachmentPreview: Identifiable {
    let info: AttachmentInfo
    let image: AttachmentImage
    var id: String { info.id }
}

/// Work belongs to this admission, never to a row or preview's lifetime.
@MainActor
final class RoomAttachmentController: ObservableObject {
    typealias TransportFactory = @Sendable (ClientSession, RoomAdmission, AttachmentBandwidth) -> any AttachmentServing
    private struct Outgoing {
        let info: AttachmentInfo
        let audience: AttachmentAudience
        var thumbnail: Data?
        var reservationAttempted = false
        var publicationAttempted = false
        var announced = false
        var cancellationRequested = false
    }
    private struct Download {
        let id: UUID
        let task: Task<Void, Error>
    }
    private let cache: AttachmentCache
    private let makeTransport: TransportFactory
    init(cache: AttachmentCache = .shared, makeTransport: @escaping TransportFactory = {
        AttachmentTransport(baseURL: $0.connection.apiURL, credential: $0.credential, admission: $1, bandwidth: $2)
    }) { self.cache = cache; self.makeTransport = makeTransport }

    @Published private(set) var states: [String: AttachmentTransferState] = [:]
    @Published private(set) var isSending = false
    @Published private(set) var error: ClientFailure?
    @Published private(set) var revision = UUID()
    @Published private(set) var networkPolicy: AttachmentNetworkPolicy = .normal
    @Published var preview: AttachmentPreview?
    private var login: ClientSession?
    private var lease: AttachmentLease?
    private var admission: RoomAdmission?
    private var transport: (any AttachmentServing)?
    private var bandwidth = AttachmentBandwidth()
    private var authorize: (@Sendable () async throws -> Void)?
    private var audience: (@MainActor () throws -> AttachmentAudience)?
    private var announce: (@MainActor (AttachmentDescriptor, String) async throws -> Void)?
    private var infos: [String: AttachmentInfo] = [:]
    private var outgoing: [String: Outgoing] = [:]
    private var sending: Task<Void, Never>?
    private var sendingID: String?
    private var sendingJob = UUID()
    private var downloads: [String: Download] = [:]
    private var cancellations: [String: Task<Void, Never>] = [:]
    private var watcher: Task<Void, Never>?
    private var subscription: AttachmentEventSubscription?
    private var refresh: Task<Void, Never>?
    private var automaticDownloads: Task<Void, Never>?
    private var downloadQueue: [String] = []
    private var receipts: [String: Task<Void, Never>] = [:]
    private var acknowledged: Set<String> = []

    var unpublished: [AttachmentInfo] {
        outgoing.values.filter { !$0.publicationAttempted }.map(\.info).sorted { $0.id < $1.id }
    }

    func begin(login: ClientSession, admission: RoomAdmission,
               authorize: @escaping @Sendable () async throws -> Void,
               audience: @escaping @MainActor () throws -> AttachmentAudience,
               announce: @escaping @MainActor (AttachmentDescriptor, String) async throws -> Void) {
        end()
        self.login = login; self.admission = admission
        self.authorize = authorize; self.audience = audience; self.announce = announce
        createTransport()
    }

    private func createTransport() {
        guard let login, let admission else { return }
        bandwidth = AttachmentBandwidth()
        transport = makeTransport(login, admission, bandwidth)
        updatePolicy(networkPolicy)
        do { lease = try cache.begin(); startEvents() } catch { self.error = ClientFailure(.attachmentCacheFailed) }
    }

    private func stop() {
        // Revoke synchronously before canceling requests or scheduling cleanup.
        if let lease { cache.end(lease) }; lease = nil
        let ids = outgoing.values.filter { states[$0.info.id]?.remoteState?.isUploaded != true }.map { $0.info.id }
        if let transport, !ids.isEmpty { Task { await transport.reportCancellation(ids) } }
        transport?.close(); transport = nil
        sendingJob = UUID(); sending?.cancel(); sending = nil; sendingID = nil
        for download in downloads.values { download.task.cancel() }; downloads.removeAll()
        for cancellation in cancellations.values { cancellation.cancel() }; cancellations.removeAll()
        watcher?.cancel(); watcher = nil; subscription?.cancel(); subscription = nil
        refresh?.cancel(); refresh = nil
        automaticDownloads?.cancel(); automaticDownloads = nil; downloadQueue.removeAll()
        for receipt in receipts.values { receipt.cancel() }; receipts.removeAll(); acknowledged.removeAll()
        infos.removeAll(); outgoing.removeAll(); states.removeAll()
        preview = nil; isSending = false; error = nil; revision = UUID()
    }

    func end() {
        stop()
        login = nil; admission = nil; authorize = nil; audience = nil; announce = nil
    }

    func cacheWasCleared() {
        // Keep text and voice, but give new files a new lease and request session.
        stop(); createTransport()
    }

    func updatePolicy(_ policy: AttachmentNetworkPolicy) {
        networkPolicy = policy
        let bandwidth = bandwidth
        Task { await bandwidth.update(policy) }
    }

    func available(_ info: AttachmentInfo) -> Bool { lease?.contains(info.id) == true }

    func receive(_ descriptor: AttachmentDescriptor) -> Bool {
        guard descriptor.isValid, let lease, descriptor.info.roomID == admission?.roomID,
              infos[descriptor.info.id] == nil, infos.count < RoomChat.maxMessages else { return false }
        var registered = false
        do {
            try lease.register(descriptor.info, key: descriptor.key); registered = true
            if let thumbnail = descriptor.thumbnail {
                let url = try lease.url(descriptor.info.id, thumbnail: true)
                try lease.withKey(descriptor.info.id) { _ in try thumbnail.write(to: url, options: .atomic) }
            }
            infos[descriptor.info.id] = descriptor.info
            states[descriptor.info.id] = AttachmentTransferState()
            startEvents(); requestSnapshot()
            return true
        } catch {
            if registered { lease.discard(descriptor.info) }
            self.error = ClientFailure.capture(error, fallback: .attachmentInvalid); return false
        }
    }

    func send(source: URL) {
        ClientLog.shared.record(.attachment, "selectFile")
        send { lease, admission in
            try await attachmentWork { try Self.prepareFile(source: source, lease: lease, admission: admission) }
        }
    }
    func send(photo: AttachmentPhotoSource) {
        ClientLog.shared.record(.attachment, "selectPhoto")
        send { lease, admission in try await photo.prepare(lease: lease, admission: admission) }
    }

    /// Consume provider files synchronously: their URLs expire when the callback returns.
    nonisolated static func prepareFile(source: URL, lease: AttachmentLease, admission: RoomAdmission,
                                        contentType: UTType? = nil, name: String? = nil) throws -> AttachmentDescriptor {
        try lease.check()
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0, size <= AttachmentInfo.maxFileBytes else { throw ClientFailure(.attachmentQuota) }
        let type = contentType ?? UTType(filenameExtension: source.pathExtension)
        let mime = type?.preferredMIMEType ?? "application/octet-stream"
        let id = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var metadata = AttachmentInfo(version: 1, id: id, roomID: admission.roomID, sender: admission.identity,
            name: name ?? source.lastPathComponent, mimeType: mime, size: size, digest: String(repeating: "0", count: 64),
            hasThumbnail: mime.hasPrefix("image/") && ["image/jpeg", "image/png", "image/heic", "image/heif", "image/webp", "image/gif"].contains(mime))
        guard !metadata.isImage || size <= AttachmentInfo.maxImageBytes else { throw ClientFailure(.attachmentQuota) }
        guard metadata.isValid else { throw ClientFailure(.attachmentInvalid) }
        var key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        defer { key.resetBytes(in: 0..<key.count) }
        try lease.register(metadata, key: key)
        var prepared = false
        defer { if !prepared { lease.discard(metadata) } }
        metadata = try AttachmentCrypto.encrypt(source: source, info: metadata, lease: lease)
        var thumbnail: Data?
        if metadata.hasThumbnail {
            var plaintext = try AttachmentImages.thumbnail(source: source)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            thumbnail = try AttachmentCrypto.thumbnail(plaintext, info: metadata, lease: lease, decrypt: false)
            let url = try lease.url(id, thumbnail: true)
            try lease.withKey(id) { _ in try thumbnail!.write(to: url, options: .atomic) }
        }
        prepared = true
        return AttachmentDescriptor(info: metadata, key: key, thumbnail: thumbnail)
    }

    private func send(prepare: @escaping @Sendable (AttachmentLease, RoomAdmission) async throws -> AttachmentDescriptor) {
        guard !isSending, outgoing.count < 16, infos.count < RoomChat.maxMessages,
              let lease, let admission, let audience, let authorize else { return }
        let token = revision, job = UUID()
        sendingJob = job; isSending = true; error = nil
        sending = Task { [weak self] in
            guard let self else { return }
            defer { finishSending(job) }
            do {
                var descriptor = try await prepare(lease, admission)
                defer { descriptor.key.resetBytes(in: 0..<descriptor.key.count) }
                var retained = false
                defer { if !retained { lease.discard(descriptor.info) } }
                try check(token, job: job); try lease.check()
                try await authorize(); try check(token, job: job)
                let captured = try audience()
                infos[descriptor.info.id] = descriptor.info
                outgoing[descriptor.info.id] = Outgoing(info: descriptor.info, audience: captured, thumbnail: descriptor.thumbnail)
                states[descriptor.info.id] = AttachmentTransferState(phase: .reserving, cached: true, outgoing: true)
                sendingID = descriptor.info.id; retained = true
                startEvents()
                try await sendPrepared(descriptor.info.id, token: token, job: job)
            } catch {
                guard revision == token, sendingJob == job else { return }
                if let id = sendingID { await failSending(id, error: error, token: token) }
                else if !(error is CancellationError) { self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed) }
            }
        }
    }

    private func sendPrepared(_ id: String, token: UUID, job: UUID) async throws {
        guard let lease, let transport, let authorize, let audience, let announce, let record = outgoing[id],
              !record.cancellationRequested else { throw CancellationError() }
        try await authorize(); try check(token, job: job); try lease.check()
        if !record.announced {
            let beforePublish = try audience()
            guard beforePublish.groupID == record.audience.groupID, Set(beforePublish.identities) == Set(record.audience.identities) else {
                throw ClientFailure(.groupStateChanged)
            }
            outgoing[id]?.reservationAttempted = true
            let remote = try await transport.create(record.info, recipients: record.audience.identities)
            try check(token, job: job); try lease.check(); try apply(remote)
            try remote.requireActive()
            let current = try audience()
            guard current.groupID == record.audience.groupID, Set(current.identities) == Set(record.audience.identities) else {
                throw ClientFailure(.groupStateChanged)
            }
            var key = try lease.withKey(id) { $0.withUnsafeBytes { Data($0) } }
            defer { key.resetBytes(in: 0..<key.count) }
            // A failed publish can have reached some peers. Never redistribute
            // this key or replay its descriptor through a later generation.
            outgoing[id]?.publicationAttempted = true
            try await announce(AttachmentDescriptor(info: record.info, key: key, thumbnail: record.thumbnail), record.audience.groupID)
            try check(token, job: job)
            outgoing[id]?.announced = true; outgoing[id]?.thumbnail = nil
        }
        states[id]?.phase = .uploading
        let remote = try await transport.upload(record.info, lease: lease, authorize: authorize) { [weak self] progress in
            await self?.update(id, progress: progress, token: token, job: job, upload: true)
        }
        try check(token, job: job); try lease.check(); try apply(remote)
        guard remote.state.isUploaded else { throw ClientFailure(.attachmentInvalid) }
        ClientLog.shared.record(.attachment, "upload", outcome: .succeeded)
        states[id]?.phase = .completed; states[id]?.progress = 1
        outgoing[id] = nil
    }

    private func failSending(_ id: String, error: Error, token: UUID) async {
        ClientLog.shared.record(.attachment, "upload", outcome: .failed, failure: ClientFailure.capture(error))
        guard let record = outgoing[id], revision == token else { return }
        if states[id]?.remoteState?.isTerminal == true { return }
        self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed)
        // Only a known unpublished reservation or an announced immutable file
        // may retry. An ambiguous key publication always resolves via cancel.
        if (record.publicationAttempted && !record.announced) || !AttachmentTransport.retryable(error) {
            states[id]?.phase = .failed
            cancelUpload(record.info)
        } else {
            states[id]?.phase = .retryableFailure
            if record.reservationAttempted, let transport {
                Task { await transport.pause(id) }
            }
        }
    }

    private func finishSending(_ job: UUID) {
        guard sendingJob == job else { return }
        sending = nil; sendingID = nil; isSending = false
    }
    private func check(_ token: UUID, job: UUID? = nil) throws {
        try Task.checkCancellation()
        guard revision == token, job == nil || job == sendingJob else { throw CancellationError() }
    }
    private func update(_ id: String, progress: Double, token: UUID, job: UUID, upload: Bool) {
        guard revision == token, upload ? sendingJob == job : downloads[id]?.id == job,
              states[id]?.remoteState?.isTerminal != true, states[id]?.phase != .downloadPaused else { return }
        states[id]?.progress = min(1, max(0, progress))
        if !upload { states[id]?.phase = progress >= 1 ? .verifying : .downloading }
    }

    func canRetry(_ info: AttachmentInfo) -> Bool {
        guard available(info), states[info.id]?.phase == .retryableFailure || states[info.id]?.phase == .downloadPaused else { return false }
        return outgoing[info.id] != nil ? !isSending : downloads[info.id] == nil
    }
    func retry(_ info: AttachmentInfo) {
        ClientLog.shared.record(.attachment, "retryUpload")
        guard canRetry(info) else { return }
        error = nil
        guard outgoing[info.id] != nil else {
            Task { _ = await prepareExport(info) }; return
        }
        let token = revision, job = UUID()
        sendingJob = job; sendingID = info.id; isSending = true; states[info.id]?.phase = .reserving
        sending = Task { [weak self] in
            guard let self else { return }
            defer { finishSending(job) }
            do { try await sendPrepared(info.id, token: token, job: job) }
            catch {
                if revision == token, sendingJob == job { await failSending(info.id, error: error, token: token) }
            }
        }
    }

    func cancelPreparation() {
        ClientLog.shared.record(.attachment, "cancelPreparation")
        if let sendingID, let info = infos[sendingID] { cancelUpload(info); return }
        sendingJob = UUID(); sending?.cancel(); sending = nil; isSending = false
    }
    func canCancel(_ info: AttachmentInfo) -> Bool {
        guard let state = states[info.id], state.outgoing, outgoing[info.id] != nil,
              state.remoteState?.isUploaded != true, state.remoteState?.isTerminal != true else { return false }
        return cancellations[info.id] == nil
    }
    func cancelUpload(_ info: AttachmentInfo) {
        ClientLog.shared.record(.attachment, "cancelUpload")
        guard canCancel(info), let transport, let lease, let record = outgoing[info.id] else { return }
        let token = revision, oldTask = sendingID == info.id ? sending : nil
        if sendingID == info.id { cancelActiveSend() }
        outgoing[info.id]?.cancellationRequested = true; states[info.id]?.phase = .cancelling
        if !record.reservationAttempted {
            lease.discard(info); states[info.id]?.phase = .cancelled; states[info.id]?.cached = false
            outgoing[info.id] = nil; return
        }
        cancellations[info.id] = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { cancellations[info.id] = nil } }
            // Drain callbacks from the old job before asking the server which
            // terminal state won. Cancellation itself may be retried safely.
            await oldTask?.value
            do {
                try check(token)
                let remote = try await transport.cancel(info)
                try check(token); try apply(remote)
                guard remote.state.isUploaded || remote.state.isTerminal else { throw ClientFailure(.attachmentInvalid) }
                outgoing[info.id] = nil
            } catch {
                guard revision == token, !(error is CancellationError) else { return }
                self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed)
                // A lost cancel response is unknown, never permission to upload.
                states[info.id]?.phase = .cancelling
            }
        }
    }
    private func cancelActiveSend() {
        sendingJob = UUID(); sending?.cancel(); sending = nil; sendingID = nil; isSending = false
    }
    func pauseDownload(_ info: AttachmentInfo) {
        ClientLog.shared.record(.attachment, "pauseDownload")
        guard let download = downloads[info.id] else { return }
        download.task.cancel()
        states[info.id]?.phase = .downloadPaused
    }

    func ensureDownloaded(_ info: AttachmentInfo) async throws {
        guard let lease, let transport, let authorize, available(info) else { throw ClientFailure(.attachmentUnavailable) }
        if states[info.id]?.cached == true {
            let url = try lease.url(info.id)
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            if (attributes?[.size] as? NSNumber)?.int64Value == info.ciphertextSize {
                try lease.check(); sendReceipt(info); return
            }
            states[info.id]?.cached = false
        }
        guard states[info.id]?.remoteState?.isTerminal != true, states[info.id]?.remoteState != .delivered else {
            throw ClientFailure(states[info.id]?.remoteState == .cancelled ? .attachmentCancelled : .attachmentExpired)
        }
        // An outgoing incomplete file must never be downloaded over itself.
        guard outgoing[info.id] == nil else { throw ClientFailure(.attachmentPending) }
        if let pending = downloads[info.id] { try await pending.task.value; return }
        guard downloads.count < 2 else { throw ClientFailure(.attachmentBusy) }
        let token = revision, job = UUID()
        states[info.id]?.phase = states[info.id]?.remoteState == .completed ? .downloading : .waitingForUpload
        let task = Task { [weak self] in
            guard let self else { throw CancellationError() }
            let span = ClientLog.shared.begin()
            ClientLog.shared.record(.attachment, "download", outcome: .started)
            do {
                try await transport.download(info, lease: lease, authorize: authorize) { [weak self] progress in
                    await self?.update(info.id, progress: progress, token: token, job: job, upload: false)
                }
                try lease.check(); try check(token)
                guard downloads[info.id]?.id == job else { throw CancellationError() }
                states[info.id]?.phase = .completed; states[info.id]?.cached = true; states[info.id]?.progress = 1
                downloads[info.id] = nil
                sendReceipt(info)
                ClientLog.shared.finish(span, .attachment, "download")
            } catch {
                ClientLog.shared.finish(span, .attachment, "download", error: error)
                if revision == token, downloads[info.id]?.id == job {
                    downloads[info.id] = nil
                    states[info.id]?.phase = error is CancellationError ? .downloadPaused : AttachmentTransport.retryable(error) ? .retryableFailure : .failed
                    let failure = ClientFailure.capture(error, fallback: .attachmentTransferFailed)
                    if failure.code == ClientErrorCode.attachmentCancelled.rawValue { states[info.id]?.phase = .cancelled; lease.discard(info) }
                    if failure.code == ClientErrorCode.attachmentExpired.rawValue { states[info.id]?.phase = .expired; lease.discard(info) }
                }
                throw error
            }
        }
        downloads[info.id] = Download(id: job, task: task)
        try await task.value
    }

    private func apply(_ remote: RemoteAttachment) throws {
        guard let info = infos[remote.id], var state = states[remote.id] else { return }
        try remote.validate(info)
        guard remote.revision >= state.remoteRevision else { return }
        // Late snapshots cannot roll back a terminal result or a completed file.
        if state.remoteState?.isTerminal == true, !remote.state.isTerminal { return }
        if state.remoteState == .delivered, remote.state != .delivered { return }
        if state.remoteState == .completed, !remote.state.isUploaded && remote.state != .expired { return }
        state.remoteState = remote.state; state.remoteRevision = remote.revision; state.completedAt = remote.completed_at
        if remote.state == .cancelled || (remote.state == .expired && (!state.cached || remote.completed_at == 0))
            || (remote.state == .delivered && !state.cached) {
            state.phase = remote.state == .cancelled ? .cancelled : .expired
            state.cached = false
            if sendingID == info.id { cancelActiveSend() }
            downloads.removeValue(forKey: info.id)?.task.cancel()
            lease?.discard(info); outgoing[info.id] = nil
            if preview?.id == info.id { preview = nil }
        } else if remote.state.isUploaded, state.outgoing {
            state.phase = .completed; state.progress = 1; outgoing[info.id] = nil
        } else if outgoing[info.id]?.cancellationRequested == true {
            state.phase = .cancelling
        }
        states[info.id] = state
    }

    private func apply(_ catalog: AttachmentCatalog, token: UUID) throws {
        try check(token)
        guard let admission else { throw CancellationError() }
        try catalog.validate(room: admission.roomID)
        for remote in catalog.attachments { try apply(remote) }
        let present = Set(catalog.attachments.map(\.id))
        for (id, info) in infos where !present.contains(id) && outgoing[id] == nil
            && states[id]?.remoteState != nil && states[id]?.cached != true {
            states[id]?.phase = .expired
            lease?.discard(info)
        }
        scheduleAutomaticDownloads()
    }

    private func scheduleAutomaticDownloads() {
        for info in infos.values.sorted(by: { $0.id < $1.id }) {
            guard let state = states[info.id], !state.outgoing, !state.cached, state.phase == .waiting,
                  state.remoteState == .completed, available(info), !downloadQueue.contains(info.id) else { continue }
            downloadQueue.append(info.id)
        }
        guard automaticDownloads == nil, !downloadQueue.isEmpty else { return }
        let token = revision
        automaticDownloads = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { automaticDownloads = nil } }
            while !Task.isCancelled, revision == token, !downloadQueue.isEmpty {
                let id = downloadQueue.removeFirst()
                guard let info = infos[id], states[id]?.remoteState == .completed,
                      states[id]?.phase == .waiting, available(info) else { continue }
                while downloads.count >= 2 {
                    do { try await Task.sleep(for: .milliseconds(50)); try check(token) }
                    catch { return }
                }
                do { try await ensureDownloaded(info) }
                catch { /* The transfer state owns retry and failure presentation. */ }
            }
        }
    }

    private func sendReceipt(_ info: AttachmentInfo) {
        guard info.sender != admission?.identity, states[info.id]?.cached == true,
              !acknowledged.contains(info.id), receipts[info.id] == nil, let transport, let lease else { return }
        let token = revision
        receipts[info.id] = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { receipts[info.id] = nil } }
            let deadline = ContinuousClock.now.advanced(by: .seconds(900))
            while !Task.isCancelled, revision == token, ContinuousClock.now < deadline {
                do {
                    try lease.check()
                    let remote = try await transport.received(info)
                    try check(token); try lease.check(); try apply(remote)
                    acknowledged.insert(info.id); return
                } catch {
                    guard revision == token, AttachmentTransport.retryable(error) else { return }
                    do { try await Task.sleep(for: .seconds(2)) } catch { return }
                }
            }
        }
    }

    private func requestSnapshot() {
        guard refresh == nil, let transport else { return }
        let token = revision
        refresh = Task { [weak self] in
            guard let self else { return }
            defer { if revision == token { refresh = nil } }
            do { try apply(try await transport.catalog(), token: token) }
            catch { /* The owned stream reconnects with a fresh full snapshot. */ }
        }
    }
    private func startEvents() {
        guard watcher == nil, let transport, let admission else { return }
        let token = revision
        watcher = Task { [weak self] in
            guard let self else { return }
            var failures = 0
            while !Task.isCancelled, revision == token {
                let stream = transport.events(); subscription = stream
                do {
                    var catalog = try await transport.catalog(); try apply(catalog, token: token)
                    for try await event in stream.events {
                        try check(token)
                        if event.name == "revoked" { end(); return }
                        guard event.name == "state" else { throw URLError(.networkConnectionLost) }
                        struct Hint: Decodable { let server_id: String; let room_id: String; let revision: UInt64 }
                        let hint = try JSONDecoder().decode(Hint.self, from: event.data)
                        guard hint.room_id == admission.roomID, !hint.server_id.isEmpty, hint.server_id.utf8.count <= 128,
                              hint.revision > 0 else { throw ClientFailure(.attachmentInvalid) }
                        failures = 0
                        if hint.server_id != catalog.server_id || hint.revision > catalog.revision {
                            catalog = try await transport.catalog(); try apply(catalog, token: token)
                        }
                    }
                    throw URLError(.networkConnectionLost)
                } catch {
                    stream.cancel()
                    guard !Task.isCancelled, revision == token else { return }
                    subscription = nil
                    if case APIError.unauthorized = error { end(); return }
                    if case APIError.disabled = error { end(); return }
                    if let failure = error as? ClientFailure, [401, 403].contains(failure.httpStatus) { end(); return }
                    failures = min(4, failures + 1)
                    do { try await Task.sleep(for: .milliseconds([500, 1_000, 2_000, 5_000][failures - 1])) } catch { return }
                }
            }
        }
    }

    func thumbnail(_ info: AttachmentInfo) async -> AttachmentImage? {
        guard let lease, info.hasThumbnail, available(info) else { return nil }
        return try? await attachmentWork {
            let file = try FileHandle(forReadingFrom: lease.url(info.id, thumbnail: true))
            defer { try? file.close() }
            let ciphertext = try file.read(upToCount: AttachmentInfo.maxThumbnailBytes + 1) ?? Data()
            guard ciphertext.count <= AttachmentInfo.maxThumbnailBytes else { throw ClientFailure(.attachmentInvalid) }
            var plaintext = try AttachmentCrypto.thumbnail(ciphertext, info: info, lease: lease, decrypt: true)
            defer { plaintext.resetBytes(in: 0..<plaintext.count) }
            let image = try AttachmentImages.decode(plaintext, maxPixels: 256)
            try lease.check(); return image
        }
    }

    func showPreview(_ info: AttachmentInfo) async {
        ClientLog.shared.record(.attachment, "previewAttachment")
        let token = revision
        do {
            guard info.isImage else { return }; try await ensureDownloaded(info)
            guard let lease, revision == token else { return }
            let image = try await attachmentWork {
                var plaintext = Data()
                defer { plaintext.resetBytes(in: 0..<plaintext.count) }
                try AttachmentCrypto.decrypt(info: info, lease: lease) { data in
                    guard plaintext.count + data.count <= AttachmentInfo.maxImageBytes else { throw ClientFailure(.attachmentQuota) }
                    plaintext.append(data)
                }
                let image = try AttachmentImages.decode(plaintext)
                try lease.check(); return image
            }
            guard revision == token, available(info) else { return }
            preview = AttachmentPreview(info: info, image: image)
        } catch {
            if revision == token, !(error is CancellationError) {
                self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed)
            }
        }
    }

    func prepareExport(_ info: AttachmentInfo) async -> Bool {
        ClientLog.shared.record(.attachment, "prepareExport")
        let token = revision
        do { try await ensureDownloaded(info); return available(info) }
        catch { if revision == token, !(error is CancellationError) { self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed) }; return false }
    }

    func export(_ info: AttachmentInfo, to directory: URL) async {
        ClientLog.shared.record(.attachment, "exportAttachment")
        guard let lease, available(info) else { return }
        let token = revision
        do {
            try await attachmentWork {
                let scoped = directory.startAccessingSecurityScopedResource()
                defer { if scoped { directory.stopAccessingSecurityScopedResource() } }
                try lease.check()
                // An explicit folder selection is the user-controlled export
                // boundary. Never stage a plaintext copy in an app cache.
                let destination = directory.appendingPathComponent(info.name)
                try Data().write(to: destination, options: .withoutOverwriting)
                var succeeded = false
                defer { if !succeeded { try? FileManager.default.removeItem(at: destination) } }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
                let output = try FileHandle(forWritingTo: destination); defer { try? output.close() }
                try AttachmentCrypto.decrypt(info: info, lease: lease) { data in try output.write(contentsOf: data) }
                try lease.check(); try output.synchronize(); succeeded = true
            }
        } catch { if revision == token, !(error is CancellationError) { self.error = ClientFailure.capture(error, fallback: .attachmentTransferFailed) } }
    }

    #if DEBUG
    /// Static presentation fixtures: no login, sockets, microphone or user files.
    static func transferReference() -> (RoomAttachmentController, [AttachmentInfo]) {
        let controller = RoomAttachmentController(cache: AttachmentCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)))
        controller.lease = try? controller.cache.begin()
        let samples: [(AttachmentTransferPhase, Bool, RemoteAttachmentState)] = [
            (.uploading, true, .uploading), (.retryableFailure, true, .paused),
            (.downloadPaused, false, .completed), (.cancelling, true, .uploading),
            (.cancelled, false, .cancelled), (.expired, false, .expired), (.completed, false, .completed)]
        let infos = samples.enumerated().map { index, sample in
            let info = AttachmentInfo(version: 1, id: String(format: "%032x", index + 1), roomID: "friends", sender: "sample.login.entry",
                name: "weekend-plan-\(index + 1).pdf", mimeType: "application/pdf", size: 2_048_000,
                digest: String(repeating: "0", count: 64), hasThumbnail: false)
            controller.infos[info.id] = info
            if !sample.2.isTerminal { try? controller.lease?.register(info, key: Data(repeating: 7, count: 32)) }
            if sample.1 {
                controller.outgoing[info.id] = Outgoing(info: info, audience: AttachmentAudience(groupID: "friends/preview/1", identities: [info.sender]),
                    publicationAttempted: true, announced: true)
            }
            controller.states[info.id] = AttachmentTransferState(phase: sample.0, progress: 0.42,
                remoteState: sample.2, outgoing: sample.1)
            return info
        }
        return (controller, infos)
    }
    #endif
}
