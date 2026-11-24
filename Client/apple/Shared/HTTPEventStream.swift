import Foundation

struct HTTPEvent: Equatable, Sendable {
    let name: String
    let data: Data
}

/// Incremental UTF-8 SSE framing with explicit bounds before buffering a line.
/// Notifications are hints; they never carry media sending authorization.
struct HTTPEventDecoder: Sendable {
    private var line = Data()
    private var payload = Data()
    private var name = "message"
    private var frameBytes = 0
    private var afterCR = false
    private var firstLine = true
    mutating func append(_ byte: UInt8) throws -> HTTPEvent? {
        if afterCR { afterCR = false; if byte == 10 { return nil } }
        if byte != 10 && byte != 13 {
            guard line.count < 4_096 else { throw ClientFailure(.invalidResponse) }
            line.append(byte); return nil
        }
        afterCR = byte == 13
        guard var text = String(data: line, encoding: .utf8) else { throw ClientFailure(.invalidResponse) }
        if firstLine { firstLine = false; if text.hasPrefix("\u{FEFF}") { text.removeFirst() } }
        frameBytes += line.count + 1; line.removeAll(keepingCapacity: true)
        guard frameBytes <= 8_192 else { throw ClientFailure(.invalidResponse) }
        if text.isEmpty {
            defer { payload.removeAll(keepingCapacity: true); name = "message"; frameBytes = 0 }
            guard !payload.isEmpty else { return nil }
            payload.removeLast()
            return HTTPEvent(name: name, data: payload)
        }
        if text.hasPrefix(":") { return nil }
        let fields = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(fields[0])
        var value = fields.count == 2 ? String(fields[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }
        if field == "event" {
            guard value.utf8.count <= 128 else { throw ClientFailure(.invalidResponse) }
            name = value.isEmpty ? "message" : value
        } else if field == "data" {
            guard payload.count + value.utf8.count + 1 <= 4_096 else { throw ClientFailure(.invalidResponse) }
            payload.append(contentsOf: value.utf8); payload.append(10)
        }
        return nil
    }
}

/// One independently cancellable connection. The app retains only the newest
/// pending hint; a slow consumer cannot accumulate a queue of state snapshots.
final class HTTPEventConnection: Sendable {
    let events: AsyncThrowingStream<HTTPEvent, Error>
    private let task: Task<Void, Never>

    init(request: URLRequest, configuration: URLSessionConfiguration? = nil, operation: StaticString = #function) {
        let configuration = configuration ?? .ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 15; configuration.timeoutIntervalForResource = 24 * 3600
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        let pair = AsyncThrowingStream<HTTPEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        events = pair.stream
        let task = Task.detached {
            // Only the worker invalidates its session, after it can no longer
            // create a request. Cancellation may arrive before this task starts.
            defer { session.invalidateAndCancel() }
            let span = ClientLog.shared.begin()
            do {
                try Task.checkCancellation()
                let (bytes, result) = try await session.bytes(for: request)
                guard let response = result as? HTTPURLResponse else { throw ClientFailure(.invalidResponse) }
                if response.statusCode != 200 {
                    var data = Data()
                    for try await byte in bytes { if data.count >= 4_096 { break }; data.append(byte) }
                    if response.statusCode == 401 { throw APIError.unauthorized }
                    let failure = ClientFailure.response(data: data, status: response.statusCode, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
                    if response.statusCode == 403, failure.code == "MEMBER_DISABLED" { throw APIError.disabled }
                    throw failure
                }
                guard response.value(forHTTPHeaderField: "Content-Type")?.split(separator: ";").first?.lowercased() == "text/event-stream" else {
                    throw ClientFailure(.invalidResponse)
                }
                ClientLog.shared.finish(span, .network, operation, status: response.statusCode)
                var decoder = HTTPEventDecoder()
                for try await byte in bytes {
                    try Task.checkCancellation()
                    if let event = try decoder.append(byte) { pair.continuation.yield(event) }
                }
                try Task.checkCancellation()
                throw URLError(.networkConnectionLost)
            } catch {
                ClientLog.shared.finish(span, .network, "eventStreamEnded", error: error)
                pair.continuation.finish(throwing: error)
            }
        }
        self.task = task
        pair.continuation.onTermination = { @Sendable _ in task.cancel() }
    }
    func cancel() { task.cancel() }
    deinit { cancel() }
}
