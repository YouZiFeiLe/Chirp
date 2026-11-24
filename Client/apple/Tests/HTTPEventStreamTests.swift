import ChirpMLS
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private final class EventLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var started = Set<String>()
        var stopped = Set<String>()
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.state.withLock { _ = $0.started.insert(url.lastPathComponent) }
        if url.pathComponents.contains("body") {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "text/event-stream"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("event: ready\ndata: {}\n\n".utf8))
        }
        // Deliberately keep both header and body requests open until cancelled.
    }
    override func stopLoading() {
        guard let id = request.url?.lastPathComponent else { return }
        Self.state.withLock { _ = $0.stopped.insert(id) }
    }
}

@Suite(.serialized)
struct HTTPEventConnectionTests {
    private func connection(_ phase: String = "headers") throws -> (HTTPEventConnection, String) {
        let id = UUID().uuidString
        let url = try #require(URL(string: "https://events.invalid/\(phase)/\(id)"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EventLifecycleURLProtocol.self]
        return (HTTPEventConnection(request: URLRequest(url: url), configuration: configuration), id)
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    private func nextEvent(_ events: AsyncThrowingStream<HTTPEvent, Error>) async throws -> HTTPEvent? {
        try await withThrowingTaskGroup(of: HTTPEvent?.self) { group in
            group.addTask {
                var iterator = events.makeAsyncIterator()
                return try await iterator.next()
            }
            group.addTask {
                try await Task.sleep(for: .seconds(2))
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        }
    }

    private func expectCancellation(_ events: AsyncThrowingStream<HTTPEvent, Error>) async throws {
        do {
            _ = try await nextEvent(events)
            Issue.record("Cancelled producer should finish with a cancellation error")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    @Test func startupCancellationDoesNotRaceRequestCreation() async throws {
        for _ in 0..<256 {
            let (connection, _) = try connection()
            connection.cancel()
            connection.cancel()
            try await expectCancellation(connection.events)
        }
    }

    @Test(arguments: ["headers", "body"])
    func cancellationStopsAnIdleNetworkRead(phase: String) async throws {
        let (connection, id) = try connection(phase)
        defer { connection.cancel() }
        try await waitFor { EventLifecycleURLProtocol.state.withLock { $0.started.contains(id) } }
        if phase == "body" {
            #expect(try await nextEvent(connection.events)?.name == "ready")
        }
        connection.cancel()
        try await expectCancellation(connection.events)
        try await waitFor { EventLifecycleURLProtocol.state.withLock { $0.stopped.contains(id) } }
    }

    @Test func cancellingTheConsumerAlsoStopsTheConnection() async throws {
        let (connection, id) = try connection("body")
        defer { connection.cancel() }
        let consumer = Task { for try await _ in connection.events {} }
        try await waitFor { EventLifecycleURLProtocol.state.withLock { $0.started.contains(id) } }
        consumer.cancel()
        _ = try? await consumer.value
        try await waitFor { EventLifecycleURLProtocol.state.withLock { $0.stopped.contains(id) } }
    }

    @Test func releasingAConnectionCancelsItsWorker() async throws {
        var owner: HTTPEventConnection? = try connection().0
        let events = try #require(owner).events
        owner = nil
        try await expectCancellation(events)
    }
}

@Test func eventDecoderHandlesUTF8FramingCommentsAndMultilineData() throws {
    var decoder = HTTPEventDecoder()
    var events: [HTTPEvent] = []
    let wire = "\u{FEFF}: keepalive\r\nevent: state\rid: 42\ndata: {\"name\":\r\ndata: \"房间 😀\"}\r\n\r\n: ping\n\nevent:\ndata:\n\n"
    for byte in wire.utf8 { if let event = try decoder.append(byte) { events.append(event) } }
    #expect(events == [HTTPEvent(name: "state", data: Data("{\"name\":\n\"房间 😀\"}".utf8)), HTTPEvent(name: "message", data: Data())])
    // A connection ending partway through a frame must not dispatch a hint.
    for byte in "event: state\ndata: {\"revision\":999}".utf8 { #expect(try decoder.append(byte) == nil) }
}

@Test func eventDecoderRejectsUnboundedFramesAndInvalidUTF8() throws {
    for wire in [Array(repeating: UInt8(120), count: 4097),
                 Array(("data: " + String(repeating: "x", count: 2100) + "\n").utf8) + Array(("data: " + String(repeating: "y", count: 2100) + "\n").utf8),
                 Array(String(repeating: ": comment\n", count: 1000).utf8), [255, 10],
                 Array(("event: " + String(repeating: "x", count: 129) + "\n").utf8)] {
        var decoder = HTTPEventDecoder()
        #expect(throws: (any Error).self) { for byte in wire { _ = try decoder.append(byte) } }
    }
}

@Test func nativeSignerRequiresTheCurrentProofDomain() async throws {
    let native = try MLSClient(identity: "member_test.login_test.entry_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    let signature = try await native.sign(Data("Chirp group request v5\ntest".utf8))
    #expect(Data(base64Encoded: signature)?.count == 64)
    for invalid in ["Chirp group request v3\ntest", "Chirp group request v2\ntest", "Chirp group request v1\ntest", "unrelated signing request", "Chirp group request v5\n" + String(repeating: "x", count: 5000)] {
        await #expect(throws: (any Error).self) { try await native.sign(Data(invalid.utf8)) }
    }
}
