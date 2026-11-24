import Foundation
import ChirpMLS
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private final class AttachmentLifecycleURLProtocol: URLProtocol, @unchecked Sendable {
    struct State {
        var started: [String: Int] = [:]
        var stopped: [String: Int] = [:]
    }
    static let state = Mutex(State())

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let id = url.host else { return }
        Self.state.withLock { $0.started[id, default: 0] += 1 }
        if url.pathComponents.contains("headers") { return }
        if url.pathComponents.contains("redirect") {
            let destination = URL(string: "https://redirect-destination.invalid/complete")!
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": destination.absoluteString])!
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: destination), redirectResponse: response)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if url.pathComponents.contains("body") {
            client?.urlProtocol(self, didLoad: Data("{\"server_id\":".utf8))
            return // Keep the body pending until cancellation.
        }
        client?.urlProtocol(self, didLoad: Data(#"{"server_id":"fixture","room_id":"friends","revision":1,"attachments":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        guard let id = request.url?.host else { return }
        Self.state.withLock { $0.stopped[id, default: 0] += 1 }
    }
}

@Suite(.serialized)
struct AttachmentSessionLifecycleTests {
    private func transport(_ phase: String = "headers") throws -> (AttachmentTransport, String) {
        let id = UUID().uuidString.lowercased() + ".invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentLifecycleURLProtocol.self]
        let transport = AttachmentTransport(baseURL: try #require(URL(string: "https://\(id)/\(phase)")),
            credential: "synthetic", admission: RoomAdmission(roomID: "friends", entryID: "entry", identity: "peer"),
            configuration: configuration)
        return (transport, id)
    }

    private func waitFor(_ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    private func expectCancellation(_ transport: AttachmentTransport) async {
        do {
            _ = try await transport.catalog()
            Issue.record("A closed or cancelled request must not return a catalog")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    private func dataSession(_ phase: String = "headers") throws -> (HTTPDataSession, URLRequest, String) {
        let id = UUID().uuidString.lowercased() + ".invalid"
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AttachmentLifecycleURLProtocol.self]
        return (HTTPDataSession(configuration: configuration),
                URLRequest(url: try #require(URL(string: "https://\(id)/\(phase)"))), id)
    }

    private func expectCancellation(_ session: HTTPDataSession, request: URLRequest) async {
        do {
            _ = try await session.data(for: request)
            Issue.record("A closed or cancelled data request must fail")
        } catch {
            #expect(error is CancellationError || (error as? URLError)?.code == .cancelled)
        }
    }

    @Test func requestsAfterCloseAreRejectedWithoutCreatingTasks() async throws {
        let (transport, id) = try transport()
        let copy = transport
        transport.close()
        copy.close()
        // This reliably triggers the original NSGenericException, even without
        // a network connection or concurrent task scheduling.
        await expectCancellation(copy)
        #expect(AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] } == 0)
    }

    @Test func apiRequestsAfterCloseReturnCancellation() async throws {
        let client = APIClient(baseURL: try #require(URL(string: "https://closed-api.invalid")), credential: "synthetic")
        let copy = client
        client.close()
        copy.close()
        await #expect(throws: CancellationError.self) { _ = try await copy.me() }
        await #expect(throws: CancellationError.self) { _ = try await copy.setAvatar(Data([1])) }
    }

    @Test func groupRequestsAfterCloseReturnCancellation() async throws {
        let login = try ClientSession(data: JSONSerialization.data(withJSONObject: [
            "member": ["id": "member_test", "display_name": "Test"],
            "credential": "chirp_" + String(repeating: "c", count: 43),
            "participant_identity": "member_test.login_test", "expires_at": Int(Date().timeIntervalSince1970) + 3600,
        ]), connection: testServerConnection)
        let admission = RoomAdmission(roomID: "friends", entryID: "entry", identity: "member_test.login_test.entry")
        let client = GroupTransport(baseURL: try #require(URL(string: "https://closed-group.invalid")), login: login,
            admission: admission, native: try MLSClient(identity: admission.identity), publicKey: "synthetic")
        client.close()
        await #expect(throws: CancellationError.self) { _ = try await client.configuration() }
    }

    @Test(arguments: ["headers", "body"])
    func closingAnInFlightRequestFinishesItsContinuation(phase: String) async throws {
        let (transport, id) = try transport(phase)
        defer { transport.close() }
        let request = Task { await expectCancellation(transport) }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] > 0 } }
        } catch {
            transport.close(); await request.value; throw error
        }
        transport.close()
        await request.value
        try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.stopped[id, default: 0] > 0 } }
    }

    @Test func cancellingARequestDoesNotInvalidateTheSharedSession() async throws {
        let (transport, id) = try transport()
        defer { transport.close() }
        let request = Task { await expectCancellation(transport) }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] == 1 } }
        } catch {
            request.cancel(); await request.value; throw error
        }
        request.cancel()
        await request.value
        let next = Task { await expectCancellation(transport) }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] == 2 } }
        } catch {
            next.cancel(); await next.value; throw error
        }
        next.cancel()
        await next.value
    }

    @Test func closingACopyCompletesEveryPendingRequest() async throws {
        let (transport, id) = try transport()
        let copy = transport
        defer { transport.close() }
        let requests = (0..<8).map { _ in Task { await expectCancellation(transport) } }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] == 8 } }
        } catch {
            copy.close()
            for request in requests { await request.value }
            throw error
        }
        copy.close()
        for request in requests { await request.value }
    }

    @Test func concurrentCreationAndRepeatedCloseHaveBoundedCompletion() async throws {
        for _ in 0..<128 {
            let (transport, _) = try transport()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { await expectCancellation(transport) } }
                group.addTask { transport.close(); transport.close() }
            }
            transport.close()
        }
    }

    @Test func independentSessionsCanStillCompleteAfterAnotherSessionCloses() async throws {
        let (closed, _) = try transport()
        closed.close()
        let (active, _) = try transport("complete")
        defer { active.close() }
        #expect(try await active.catalog().attachments.isEmpty)
        await expectCancellation(closed)
    }

    @Test(arguments: ["headers", "body"])
    func dataSessionCloseCompletesPendingRequests(phase: String) async throws {
        let (session, request, id) = try dataSession(phase)
        defer { session.close() }
        let pending = Task { await expectCancellation(session, request: request) }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] > 0 } }
        } catch {
            session.close(); await pending.value; throw error
        }
        session.close()
        await pending.value
    }

    @Test func dataSessionCancellationDoesNotCloseThePool() async throws {
        let (session, request, id) = try dataSession()
        defer { session.close() }
        let pending = Task { await expectCancellation(session, request: request) }
        do {
            try await waitFor { AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] == 1 } }
        } catch {
            pending.cancel(); await pending.value; throw error
        }
        pending.cancel()
        await pending.value
        var next = request
        next.url = URL(string: "https://\(id)/complete")
        let (data, response) = try await session.data(for: next)
        #expect((response as? HTTPURLResponse)?.statusCode == 200 && !data.isEmpty)
    }

    @Test func aCancelledTaskCanReachDataSessionBeforeRequestRegistration() async throws {
        let (session, request, id) = try dataSession()
        defer { session.close() }
        let pending = Task {
            try? await Task.sleep(for: .seconds(10))
            await expectCancellation(session, request: request)
        }
        pending.cancel()
        await pending.value
        #expect(AttachmentLifecycleURLProtocol.state.withLock { $0.started[id, default: 0] } == 0)
    }

    @Test func dataSessionCreationAndCloseAreSerialized() async throws {
        for _ in 0..<128 {
            let (session, request, _) = try dataSession()
            await withTaskGroup(of: Void.self) { group in
                for _ in 0..<8 { group.addTask { await expectCancellation(session, request: request) } }
                group.addTask { session.close(); session.close() }
            }
            await expectCancellation(session, request: request)
        }
    }

    @Test func dataSessionStillRejectsRedirects() async throws {
        let (session, request, _) = try dataSession("redirect")
        defer { session.close() }
        var bounded = request
        bounded.timeoutInterval = 2
        let (_, response) = try await session.data(for: bounded)
        #expect((response as? HTTPURLResponse)?.statusCode == 302)
        #expect(AttachmentLifecycleURLProtocol.state.withLock { $0.started["redirect-destination.invalid", default: 0] } == 0)
    }
}
