import Foundation
import CryptoKit

struct AttachmentTransport: AttachmentServing {
    static let chunkBytes = 1024 * 1024
    let baseURL: URL
    let credential: String
    let admission: RoomAdmission
    let bandwidth: AttachmentBandwidth
    private let session: URLSession
    private let responses: AttachmentResponseDelegate

    init(baseURL: URL, credential: String, admission: RoomAdmission, configuration: URLSessionConfiguration? = nil,
         bandwidth: AttachmentBandwidth = AttachmentBandwidth()) {
        self.baseURL = baseURL; self.credential = credential; self.admission = admission; self.bandwidth = bandwidth
        let configuration = configuration ?? .ephemeral
        configuration.urlCache = nil; configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 45
        let responses = AttachmentResponseDelegate()
        self.responses = responses
        session = URLSession(configuration: configuration, delegate: responses, delegateQueue: nil)
    }
    func close() { responses.close(session: session) }
    private func url(_ suffix: String) -> URL { baseURL.appendingPathComponent("v1/rooms/\(admission.roomID)/attachments\(suffix)") }
    private func makeRequest(_ suffix: String, method: String = "GET", body: Data? = nil, binary: Bool = false) -> URLRequest {
        var request = URLRequest(url: url(suffix)); request.httpMethod = method; request.httpBody = body
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(admission.entryID, forHTTPHeaderField: "X-Chirp-Entry")
        request.setValue(binary ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
        return request
    }
    func create(_ info: AttachmentInfo, recipients: [String]) async throws -> RemoteAttachment {
        guard info.isValid, info.sender == admission.identity, info.roomID == admission.roomID else { throw ClientFailure(.attachmentInvalid) }
        struct Create: Encodable { let id: String; let entry_id: String; let ciphertext_size: Int64; let ciphertext_sha256: String; let recipients: [String] }
        let body = try JSONEncoder().encode(Create(id: info.id, entry_id: admission.entryID, ciphertext_size: info.ciphertextSize,
                                                 ciphertext_sha256: info.digest, recipients: recipients))
        let data = try await request("", method: "POST", body: body, maxBytes: 4096)
        let result = try JSONDecoder().decode(RemoteAttachment.self, from: data); try result.validate(info); try result.requireActive(); return result
    }
    func status(_ info: AttachmentInfo) async throws -> RemoteAttachment {
        let data = try await request("/\(info.id)", maxBytes: 256 * 1024)
        let result = try JSONDecoder().decode(RemoteAttachment.self, from: data); try result.validate(info, requireDigests: true); return result
    }
    func catalog() async throws -> AttachmentCatalog {
        let data = try await request("", maxBytes: 1024 * 1024)
        let result = try JSONDecoder().decode(AttachmentCatalog.self, from: data); try result.validate(room: admission.roomID); return result
    }
    func events() -> AttachmentEventSubscription {
        var request = makeRequest("/events"); request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let stream = HTTPEventConnection(request: request, configuration: session.configuration)
        return AttachmentEventSubscription(events: stream.events, cancel: { stream.cancel() })
    }
    func cancel(_ info: AttachmentInfo) async throws -> RemoteAttachment {
        let data = try await request("/\(info.id)/cancel", method: "POST", maxBytes: 4096)
        let result = try JSONDecoder().decode(RemoteAttachment.self, from: data); try result.validate(info); return result
    }
    func received(_ info: AttachmentInfo) async throws -> RemoteAttachment {
        let body = try JSONEncoder().encode(["ciphertext_sha256": info.digest])
        let data = try await request("/\(info.id)/received", method: "POST", body: body, maxBytes: 4096)
        let result = try JSONDecoder().decode(RemoteAttachment.self, from: data)
        try result.validate(info)
        guard result.state.isUploaded else { try result.requireActive(); throw ClientFailure(.attachmentInvalid) }
        return result
    }
    func pause(_ id: String) async {
        guard AttachmentInfo.validID(id) else { return }
        _ = try? await request("/\(id)/pause", method: "POST", maxBytes: 4096, timeout: 3)
    }
    func reportCancellation(_ ids: [String]) async {
        // Cleanup has its own short-lived session and contains no plaintext
        // metadata or keys. Closing the transfer session cannot cancel it.
        let reporter = AttachmentTransport(baseURL: baseURL, credential: credential, admission: admission, configuration: session.configuration, bandwidth: bandwidth)
        defer { reporter.close() }
        await withTaskGroup(of: Void.self) { group in
            for id in ids.prefix(16) where AttachmentInfo.validID(id) {
                group.addTask { _ = try? await reporter.request("/\(id)/cancel", method: "POST", maxBytes: 4096, timeout: 3) }
            }
        }
    }

    @concurrent func upload(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                progress: @escaping @Sendable (Double) async -> Void) async throws -> RemoteAttachment {
        guard info.sender == admission.identity else { throw ClientFailure(.attachmentInvalid) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        try lease.check(); try await authorized(authorize, until: deadline)
        // Never re-encrypt on retry. Validate this exact sealed file and compare
        // every server-committed prefix hash before skipping a single byte.
        try await attachmentWork { try AttachmentCrypto.validateCiphertext(info: info, lease: lease) }
        let remote = try await status(info); try remote.requireActive()
        let file = try FileHandle(forReadingFrom: lease.url(info.id)); defer { try? file.close() }
        let hashes = remote.chunk_sha256 ?? []
        var offset: Int64 = 0
        for index in 0..<remote.uploaded_chunks {
            try lease.check()
            let count = Int(min(Int64(Self.chunkBytes), info.ciphertextSize - offset))
            let data = try AttachmentCrypto.read(file, count: count)
            guard Self.hash(data) == hashes[index] else { throw ClientFailure(.attachmentIntegrity) }
            offset += Int64(count)
        }
        await progress(Double(offset) / Double(info.ciphertextSize))
        if remote.state.isUploaded { return remote }
        for index in remote.uploaded_chunks..<remote.chunkCount {
            try lease.check(); try await authorized(authorize, until: deadline)
            let count = Int(min(Int64(Self.chunkBytes), info.ciphertextSize - offset))
            let data = try AttachmentCrypto.read(file, count: count)
            try await bandwidth.acquire(count, deadline: deadline); try lease.check()
            _ = try await request("/\(info.id)/chunks/\(index)", method: "PUT", body: data, binary: true, maxBytes: 4096,
                                  transferDeadline: deadline, budgetBytes: count)
            try lease.check(); offset += Int64(count)
            await progress(Double(offset) / Double(info.ciphertextSize))
        }
        let data = try await request("/\(info.id)/complete", method: "POST", maxBytes: 4096, transferDeadline: deadline)
        let completed = try JSONDecoder().decode(RemoteAttachment.self, from: data); try completed.validate(info)
        guard completed.state.isUploaded else { try completed.requireActive(); throw ClientFailure(.attachmentInvalid) }
        return completed
    }

    @concurrent func download(_ info: AttachmentInfo, lease: AttachmentLease, authorize: @escaping @Sendable () async throws -> Void,
                  progress: @escaping @Sendable (Double) async -> Void) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(900))
        var remote: RemoteAttachment
        while true {
            try lease.check(); try await authorized(authorize, until: deadline)
            remote = try await status(info); try remote.requireActive()
            if remote.state == .completed { break }
            if remote.state == .delivered { throw ClientFailure(.attachmentExpired) }
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .seconds(2))
        }
        let partial = try lease.partialURL(info.id), destination = try lease.url(info.id)
        if !FileManager.default.fileExists(atPath: partial.path) {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw ClientFailure(.attachmentCacheFailed) }
        }
        let output = try FileHandle(forUpdating: partial); defer { try? output.close() }
        let length = try output.seekToEnd(); try output.seek(toOffset: 0)
        let hashes = remote.chunk_sha256 ?? []
        var offset: Int64 = 0, next = 0
        // Preserve only complete authenticated ciphertext network chunks. A
        // torn/corrupt local prefix is truncated rather than trusted by length.
        while next < remote.chunkCount {
            try lease.check()
            let count = Int(min(Int64(Self.chunkBytes), info.ciphertextSize - offset))
            guard UInt64(offset) + UInt64(count) <= length else { break }
            let data = try AttachmentCrypto.read(output, count: count)
            guard Self.hash(data) == hashes[next] else { break }
            offset += Int64(count); next += 1
        }
        try output.truncate(atOffset: UInt64(offset)); try output.seek(toOffset: UInt64(offset))
        await progress(Double(offset) / Double(info.ciphertextSize))
        while next < remote.chunkCount {
            try lease.check(); try await authorized(authorize, until: deadline)
            let count = Int(min(Int64(Self.chunkBytes), info.ciphertextSize - offset))
            try await bandwidth.acquire(count, direction: .download, deadline: deadline); try lease.check()
            let data = try await request("/\(info.id)/chunks/\(next)", binary: true, maxBytes: count,
                                         transferDeadline: deadline, budgetBytes: count)
            guard data.count == count, Self.hash(data) == hashes[next] else { throw ClientFailure(.attachmentIntegrity) }
            try lease.check(); try output.write(contentsOf: data)
            offset += Int64(count); next += 1
            await progress(Double(offset) / Double(info.ciphertextSize))
        }
        try output.synchronize()
        do {
            try await attachmentWork { try AttachmentCrypto.validateCiphertext(info: info, lease: lease, source: partial) }
        } catch {
            try lease.check()
            try? FileManager.default.removeItem(at: partial)
            throw ClientFailure(.attachmentIntegrity)
        }
        try lease.check()
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.moveItem(at: partial, to: destination)
    }
    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func authorized(_ authorize: @escaping @Sendable () async throws -> Void, until deadline: ContinuousClock.Instant) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await authorize() }
            group.addTask { try await Task.sleep(until: deadline); throw URLError(.timedOut) }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    static func retryable(_ error: Error) -> Bool {
        if let error = error as? URLError {
            return [.timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code)
        }
        if let error = error as? ClientFailure, let status = error.httpStatus { return status == 408 || status == 429 || status >= 500 }
        return false
    }

    private func request(_ suffix: String, method: String = "GET", body: Data? = nil, binary: Bool = false, maxBytes: Int,
                         timeout: Double = 30, transferDeadline: ContinuousClock.Instant? = nil, budgetBytes: Int = 0, operation: StaticString = #function) async throws -> Data {
        let deadline = min(ContinuousClock.now.advanced(by: .seconds(timeout)), transferDeadline ?? .now.advanced(by: .seconds(timeout)))
        for attempt in 0..<4 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            let span = ClientLog.shared.begin()
            do {
                let request = makeRequest(suffix, method: method, body: body, binary: binary)
                let data = try await withThrowingTaskGroup(of: Data.self) { group in
                    group.addTask { try await perform(request, binaryDownload: binary && method == "GET", maxBytes: maxBytes) }
                    group.addTask { try await Task.sleep(until: deadline); throw URLError(.timedOut) }
                    defer { group.cancelAll() }
                    guard let first = try await group.next() else { throw CancellationError() }; return first
                }
                ClientLog.shared.finish(span, .network, operation)
                return data
            } catch {
                ClientLog.shared.finish(span, .network, operation, error: error)
                try Task.checkCancellation()
                guard attempt < 3, Self.retryable(error) else { throw error }
                let delay = max(Double((error as? ClientFailure)?.retryAfter ?? 0), 0.25 * pow(2, Double(attempt))) + Double.random(in: 0...0.15)
                guard ContinuousClock.now.advanced(by: .seconds(delay)) < deadline else { throw error }
                try await Task.sleep(for: .seconds(delay))
                if budgetBytes > 0 { try await bandwidth.acquire(budgetBytes, direction: method == "GET" ? .download : .upload, deadline: deadline) }
            }
        }
        throw ClientFailure(.attachmentUnavailable)
    }
    private func perform(_ request: URLRequest, binaryDownload: Bool, maxBytes: Int) async throws -> Data {
        try await responses.perform(request, session: session, maxBytes: maxBytes, binaryDownload: binaryDownload)
    }
}

/// URLSession delivers bounded buffers instead of iterating every byte through
/// an async iterator. All requests share the session's connection pool.
private final class AttachmentResponseDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Int: AttachmentResponse] = [:]
    private var closed = false

    func close(session: URLSession) {
        // Request creation and closure share one admission lock. A cancelled
        // task may still reach perform(), including through a copied transport.
        let shouldInvalidate = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        // Invalidation can deliver delegate callbacks; never hold their lock.
        if shouldInvalidate { session.invalidateAndCancel() }
    }

    func perform(_ request: URLRequest, session: URLSession, maxBytes: Int, binaryDownload: Bool) async throws -> Data {
        let response = AttachmentResponse(maxBytes: maxBytes, binaryDownload: binaryDownload)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !closed else { return nil }
                    let task = session.dataTask(with: request)
                    // Publish the continuation before the task can be observed
                    // by close() or receive a cancellation completion callback.
                    response.prepare(task, continuation: continuation)
                    requests[task.taskIdentifier] = response
                    return task
                }
                guard let task else { continuation.resume(throwing: CancellationError()); return }
                response.resume(task)
            }
        } onCancel: { response.cancel() }
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let pending = lock.withLock {
            closed = true
            let pending = Array(requests.values)
            requests.removeAll()
            return pending
        }
        // Ensure every continuation completes even if invalidation precedes an
        // individual task's completion. Late task callbacks then find no entry.
        for response in pending { response.finish(error ?? URLError(.cancelled)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let pending = lock.withLock { requests[dataTask.taskIdentifier] }
        completionHandler(pending?.receive(response) == true ? .allow : .cancel)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.withLock { requests[dataTask.taskIdentifier] }?.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }?.finish(error)
    }
}

private final class AttachmentResponse: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private let binaryDownload: Bool
    private var limit: Int
    private var data = Data()
    private var response: HTTPURLResponse?
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Data, Error>?
    private var cancelled = false
    private var failure: Error?

    init(maxBytes: Int, binaryDownload: Bool) {
        self.maxBytes = maxBytes; self.binaryDownload = binaryDownload; limit = maxBytes
    }
    func prepare(_ task: URLSessionDataTask, continuation: CheckedContinuation<Data, Error>) {
        lock.withLock { self.task = task; self.continuation = continuation }
    }
    func resume(_ task: URLSessionDataTask) {
        let cancel = lock.withLock { cancelled }
        if cancel { task.cancel() }
        task.resume()
    }
    func cancel() {
        let task = lock.withLock { cancelled = true; return task }
        task?.cancel()
    }
    func receive(_ result: URLResponse) -> Bool {
        lock.withLock {
            guard let response = result as? HTTPURLResponse else { failure = ClientFailure(.invalidResponse); return false }
            self.response = response
            let success = (200..<300).contains(response.statusCode)
            limit = success ? maxBytes : 4096
            guard response.expectedContentLength <= Int64(limit),
                  !success || !binaryDownload || response.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream" else {
                failure = ClientFailure(.attachmentInvalid); return false
            }
            data.reserveCapacity(min(limit, AttachmentTransport.chunkBytes))
            return true
        }
    }
    func append(_ bytes: Data) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard failure == nil, bytes.count <= limit - data.count else {
                failure = failure ?? ClientFailure(.attachmentInvalid); return self.task
            }
            data.append(bytes); return nil
        }
        task?.cancel()
    }
    func finish(_ error: Error?) {
        let result: (CheckedContinuation<Data, Error>?, Result<Data, Error>) = lock.withLock {
            defer { continuation = nil; task = nil; data = Data() }
            if cancelled { return (continuation, .failure(CancellationError())) }
            if let error = failure ?? error { return (continuation, .failure(error)) }
            guard let response else { return (continuation, .failure(ClientFailure(.invalidResponse))) }
            guard (200..<300).contains(response.statusCode) else {
                return (continuation, .failure(ClientFailure.response(data: data, status: response.statusCode,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"))))
            }
            return (continuation, .success(data))
        }
        result.0?.resume(with: result.1)
    }
}
