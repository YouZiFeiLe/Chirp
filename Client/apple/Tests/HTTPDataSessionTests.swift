import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private final class BoundedDataURLProtocol: URLProtocol, @unchecked Sendable {
    static let stopped = Mutex(Set<String>())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let mode = url.lastPathComponent
        var headers = ["Content-Type": "application/json"]
        if mode == "declared" { headers["Content-Length"] = "9" }
        let response = HTTPURLResponse(url: url, statusCode: mode == "error" ? 503 : 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if mode == "declared" { return }
        if mode != "empty" {
            client?.urlProtocol(self, didLoad: Data(repeating: 97, count: 4))
            client?.urlProtocol(self, didLoad: Data(repeating: 98, count: mode == "exact" ? 4 : 5))
        }
        // An oversized body intentionally stays open. The client must reject
        // it immediately rather than wait for EOF or the resource deadline.
        if mode == "exact" || mode == "empty" { client?.urlProtocolDidFinishLoading(self) }
    }

    override func stopLoading() {
        if let id = request.url?.host { Self.stopped.withLock { _ = $0.insert(id) } }
    }
}

struct HTTPDataSessionTests {
    private func session() -> HTTPDataSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BoundedDataURLProtocol.self]
        configuration.timeoutIntervalForRequest = 1
        configuration.timeoutIntervalForResource = 2
        return HTTPDataSession(configuration: configuration)
    }

    @Test(arguments: ["declared", "streamed", "error"])
    func oversizedResponsesAreCancelledBeforeEndOfStream(mode: String) async throws {
        let session = session()
        defer { session.close() }
        let id = UUID().uuidString.lowercased() + ".invalid"
        defer { BoundedDataURLProtocol.stopped.withLock { _ = $0.remove(id) } }
        let url = try #require(URL(string: "https://\(id)/\(mode)"))
        do {
            _ = try await session.data(for: URLRequest(url: url), maxBytes: 8)
            Issue.record("Oversized responses must fail before the server finishes sending")
        } catch {
            #expect((error as? ClientFailure)?.code == ClientErrorCode.invalidResponse.rawValue)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !BoundedDataURLProtocol.stopped.withLock({ $0.contains(id) }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(BoundedDataURLProtocol.stopped.withLock { $0.contains(id) })
        // Rejecting one response must leave the connection pool usable.
        let valid = try #require(URL(string: "https://\(id)/exact"))
        #expect(try await session.data(for: URLRequest(url: valid), maxBytes: 8).0 == Data("aaaabbbb".utf8))
    }

    @Test func emptyResponsesAndExactLimitsSucceed() async throws {
        let session = session()
        defer { session.close() }
        let empty = try #require(URL(string: "https://bounded-data.invalid/empty"))
        #expect(try await session.data(for: URLRequest(url: empty), maxBytes: 0).0.isEmpty)
        let exact = try #require(URL(string: "https://bounded-data.invalid/exact"))
        #expect(try await session.data(for: URLRequest(url: exact), maxBytes: 8).0.count == 8)
    }
}
