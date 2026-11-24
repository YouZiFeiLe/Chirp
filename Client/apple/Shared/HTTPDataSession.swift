import Foundation

/// A pooled data session with synchronous admission and closure. Checking a
/// boolean before awaiting URLSession.data(for:) is insufficient: closure can
/// invalidate the session before that async method creates its native task.
final class HTTPDataSession: Sendable {
    private let session: URLSession
    private let responses: HTTPDataDelegate
    private let log: ClientLog

    init(configuration: URLSessionConfiguration, log: ClientLog = .shared) {
        self.log = log
        let responses = HTTPDataDelegate()
        self.responses = responses
        session = URLSession(configuration: configuration, delegate: responses, delegateQueue: nil)
    }

    deinit { responses.close(session) }

    func close() { responses.close(session) }

    func data(for request: URLRequest, maxBytes: Int = 2 * 1_024 * 1_024, operation: StaticString = #function) async throws -> (Data, URLResponse) {
        guard maxBytes >= 0 else { throw ClientFailure(.invalidResponse) }
        let span = log.begin()
        do {
            let result = try await responses.data(for: request, session: session, maxBytes: maxBytes)
            if span != nil, let status = (result.1 as? HTTPURLResponse)?.statusCode {
                var failure: ClientFailure?
                if !(200..<300).contains(status) {
                    failure = result.0.count <= 16_384 ? ClientFailure.response(data: result.0, status: status)
                        : ClientFailure(.httpFailure, httpStatus: status)
                }
                log.finish(span, .network, operation, error: failure, status: status)
            }
            return result
        } catch {
            log.finish(span, .network, operation, error: error)
            throw error
        }
    }
}

/// A completion-handler data task buffers the entire response inside URLSession
/// before the caller can inspect its size. Bound both declared and streamed
/// bytes here, including chunked responses and error bodies.
private final class HTTPDataDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    private var requests: [Int: HTTPDataRequest] = [:]

    func close(_ session: URLSession) {
        let shouldInvalidate = lock.withLock {
            guard !closed else { return false }
            closed = true
            return true
        }
        if shouldInvalidate { session.invalidateAndCancel() }
    }

    func data(for request: URLRequest, session: URLSession, maxBytes: Int) async throws -> (Data, URLResponse) {
        let pending = HTTPDataRequest(maxBytes: maxBytes)
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                let task = lock.withLock { () -> URLSessionDataTask? in
                    guard !closed else { return nil }
                    let task = session.dataTask(with: request)
                    // A close or cancellation completion cannot get ahead of
                    // continuation registration, even if resume has not run.
                    pending.prepare(task, continuation: continuation)
                    requests[task.taskIdentifier] = pending
                    return task
                }
                guard let task else { continuation.resume(throwing: CancellationError()); return }
                pending.resume(task)
            }
        } onCancel: { pending.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
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

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        let pending = lock.withLock {
            closed = true
            let pending = Array(requests.values)
            requests.removeAll()
            return pending
        }
        for request in pending { request.finish(error ?? URLError(.cancelled)) }
    }
}

private final class HTTPDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var cancelled = false
    private var data = Data()
    private var response: URLResponse?
    private var failure: Error?

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func prepare(_ task: URLSessionDataTask, continuation: CheckedContinuation<(Data, URLResponse), Error>) {
        lock.withLock { self.task = task; self.continuation = continuation }
    }

    func resume(_ task: URLSessionDataTask) {
        if lock.withLock({ cancelled }) { task.cancel() }
        task.resume()
    }

    func cancel() {
        let task = lock.withLock { cancelled = true; return self.task }
        task?.cancel()
    }

    func receive(_ response: URLResponse) -> Bool {
        lock.withLock {
            guard !cancelled, response.expectedContentLength <= Int64(maxBytes) else {
                failure = ClientFailure(.invalidResponse)
                return false
            }
            self.response = response
            return true
        }
    }

    func append(_ bytes: Data) {
        let task = lock.withLock { () -> URLSessionDataTask? in
            guard !cancelled, failure == nil else { return self.task }
            guard bytes.count <= maxBytes - data.count else {
                failure = ClientFailure(.invalidResponse)
                return self.task
            }
            data.append(bytes)
            return nil
        }
        task?.cancel()
    }

    func finish(_ error: Error?) {
        let result: (CheckedContinuation<(Data, URLResponse), Error>?, Result<(Data, URLResponse), Error>) = lock.withLock {
            defer { continuation = nil; task = nil; data = Data(); response = nil }
            if cancelled { return (continuation, .failure(CancellationError())) }
            if let error = failure ?? error { return (continuation, .failure(error)) }
            guard let response else { return (continuation, .failure(ClientFailure(.invalidResponse))) }
            return (continuation, .success((data, response)))
        }
        result.0?.resume(with: result.1)
    }
}
