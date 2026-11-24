import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private final class AdmissionURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: Data; var held = false }
    struct Record: Sendable { let path: String; let body: Data; let query: String? }
    static let state = Mutex((replies: [Reply](), records: [Record]()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let record = Record(path: request.url!.path, body: body, query: request.url!.query)
        let reply = Self.state.withLock { state -> Reply? in
            state.records.append(record)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return }
        if reply.held { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func passwordTestLogin() throws -> ClientSession {
    try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "member": ["id": "member_test", "display_name": "Oliver"],
        "credential": "chirp_" + String(repeating: "c", count: 43),
        "participant_identity": "member_test.login_test", "expires_at": Int(Date().timeIntervalSince1970) + 3600
    ]), connection: testServerConnection)
}

@Suite(.serialized) struct RoomPasswordNetworkTests {
    private func json(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func preflight(_ overrides: [String: Any] = [:]) throws -> Data {
        var value: [String: Any] = ["room_id": "room-2", "join_sequence": 2, "preflight_proof": "payload.signature", "expires_at": Int(Date().timeIntervalSince1970) + 30]
        value.merge(overrides) { _, new in new }; return try json(value)
    }
    private func joined(_ overrides: [String: Any] = [:]) throws -> Data {
        let entry = "entry_" + String(repeating: "a", count: 32)
        var value: [String: Any] = ["room_id": "room-2", "join_sequence": 2, "entry_id": entry,
            "display_name": "朋友们", "admission_expires_at": Int(Date().timeIntervalSince1970) + 30,
            "participant_identity": "member_test.login_test." + entry, "token": "synthetic",
            "livekit_url": "wss://rtc.example.com", "key_protocol": VoiceRooms.keyProtocol,
            "media_transport": "udp", "e2ee_required": true]
        value.merge(overrides) { _, new in new }; return try json(value)
    }
    private func api(_ replies: [AdmissionURLProtocol.Reply]) -> APIClient {
        AdmissionURLProtocol.state.withLock { $0 = (replies, []) }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [AdmissionURLProtocol.self]
        return APIClient(baseURL: URL(string: "https://chirp.example.com")!, credential: "synthetic", configuration: config)
    }

    @Test func wrongPasswordOrChangedPolicyCannotReturnAnAdmissionForHandoff() async throws {
        let login = try passwordTestLogin()
        for code in ["ROOM_PASSWORD_REQUIRED", "ROOM_PASSWORD_INCORRECT", "ROOM_PASSWORD_CHANGED", "ROOM_PREFLIGHT_EXPIRED"] {
            let error = try json(["error": ["code": code, "message": "retry password"]])
            let formal = code == "ROOM_PASSWORD_CHANGED" || code == "ROOM_PREFLIGHT_EXPIRED"
            let client = try api((formal ? [.init(status: 200, body: preflight())] : []) + [.init(status: formal ? 409 : 403, body: error)])
            defer { client.close() }
            do {
                _ = try await client.authorizeRoom(roomID: "room-2", sequence: 2, login: login, password: "incorrect password")
                Issue.record("Password failure returned a target admission")
            } catch let error as APIError { #expect(error.needsRoomPassword) }
            let records = AdmissionURLProtocol.state.withLock { $0.records }
            #expect(records.count == (formal ? 2 : 1))
            #expect(!records.contains { $0.path.hasSuffix("/leave") || $0.path.contains("/group/") })
        }
    }

    @Test func joinSequenceIsBoundToTheMemberAndLoginInOneRequest() async throws {
        let login = try passwordTestLogin()
        for (member, identity) in [(login.member.id, login.participantIdentity), ("other", login.participantIdentity), (login.member.id, "member_test.login_old")] {
            let body = try json(["member": ["id": member, "display_name": "Name"], "participant_identity": identity, "join_sequence": 4])
            let client = api([.init(status: 200, body: body)])
            defer { client.close() }
            if member == login.member.id && identity == login.participantIdentity {
                #expect(try await client.joinSequence(for: login) == 4)
            } else {
                await #expect(throws: APIError.self) { try await client.joinSequence(for: login) }
            }
            #expect(AdmissionURLProtocol.state.withLock { $0.records.map(\.path) } == ["/v1/session"])
        }
    }

    @Test func passwordOnlyGoesToPreflightAndFormalJoinContainsOnlyScopedProof() async throws {
        let client = try api([.init(status: 200, body: preflight()), .init(status: 200, body: joined())])
        defer { client.close() }
        let response = try await client.authorizeRoom(roomID: "room-2", sequence: 2, login: passwordTestLogin(), password: "private-room-pass")
        #expect(response.roomID == "room-2")
        let records = AdmissionURLProtocol.state.withLock { $0.records }
        #expect(records.map(\.path) == ["/v1/rooms/room-2/preflight", "/v1/rooms/room-2/join"])
        #expect(records.allSatisfy { $0.query == nil })
        let first = try #require(try JSONSerialization.jsonObject(with: records[0].body) as? [String: Any])
        let second = try #require(try JSONSerialization.jsonObject(with: records[1].body) as? [String: Any])
        #expect(first["password"] as? String == "private-room-pass")
        #expect(second["password"] == nil && second["preflight_proof"] as? String == "payload.signature")
        #expect(Set(second.keys) == Set(["join_sequence", "preflight_proof"]))
    }

    @Test func invalidPreflightCannotAdvanceToJoinAndBadPolicyCleansOnlyTargetEntry() async throws {
        let login = try passwordTestLogin()
        for changed in [["room_id": "room-3"], ["join_sequence": 1], ["expires_at": 1], ["preflight_proof": "invalid proof"]] as [[String: Any]] {
            let client = try api([.init(status: 200, body: preflight(changed))]); defer { client.close() }
            await #expect(throws: (any Error).self) { try await client.authorizeRoom(roomID: "room-2", sequence: 2, login: login, password: nil) }
            #expect(AdmissionURLProtocol.state.withLock { $0.records.count } == 1)
        }
        let client = try api([.init(status: 200, body: preflight()), .init(status: 200, body: joined(["e2ee_required": false])), .init(status: 204, body: Data())])
        defer { client.close() }
        await #expect(throws: (any Error).self) { try await client.authorizeRoom(roomID: "room-2", sequence: 2, login: login, password: nil) }
        let records = AdmissionURLProtocol.state.withLock { $0.records }
        #expect(records.map(\.path) == ["/v1/rooms/room-2/preflight", "/v1/rooms/room-2/join", "/v1/rooms/room-2/leave"])
    }

    @Test func cancelingReadOnlyPreflightNeverCreatesAnAdmission() async throws {
        let client = api([.init(status: 200, body: Data(), held: true)]); defer { client.close() }
        let login = try passwordTestLogin()
        let task = Task { try await client.authorizeRoom(roomID: "room-2", sequence: 2, login: login, password: "private pass") }
        for _ in 0..<100 {
            if AdmissionURLProtocol.state.withLock({ !$0.records.isEmpty }) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Canceled preflight returned admission") } catch { /* No handoff. */ }
        #expect(AdmissionURLProtocol.state.withLock { $0.records.map(\.path) } == ["/v1/rooms/room-2/preflight"])
    }
}

// Opt-in only: scripts/test-client-admission.py supplies disposable loopback credentials.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_PASSWORD_TEST_URL"] != nil))
func roomPasswordAdmissionIntegration() async throws {
    let env = ProcessInfo.processInfo.environment
    let rawURL = try #require(env["CHIRP_PASSWORD_TEST_URL"])
    let url = try #require(URL(string: rawURL))
    #expect(url.scheme == "http" && url.host == "127.0.0.1")
    guard url.scheme == "http", url.host == "127.0.0.1" else { throw NSError(domain: "RoomPasswordTests", code: 1) }
    let login = try ClientSession(data: Data(try #require(env["CHIRP_PASSWORD_TEST_LOGIN"]).utf8), connection: ServerConnection(apiURL: url, passkeyOrigin: testServerConnection.passkeyOrigin))
    let password = try #require(env["CHIRP_PASSWORD_TEST_PASSWORD"])
    let roomID = try #require(env["CHIRP_PASSWORD_TEST_ROOM"])
    let api = APIClient(baseURL: url, credential: login.credential); defer { api.close() }
    // Exercise the production Swift decoders and authenticated event transport
    // against the actual container API, in addition to admission mutations.
    let publicState = try await api.state().validated(defaultRoomID: login.connection.defaultRoomID)
    #expect(publicState.members.contains { $0.id == login.member.id })
    let source = ClientStateSource.live(login), stream = source.connect()
    defer { stream.cancel(); source.close() }
    var receivedHint = false
    for try await event in stream.events {
        #expect(event.name == "state")
        let hint = try JSONDecoder().decode(ClientStateHint.self, from: event.data)
        #expect(hint.serverID == publicState.serverID && hint.revision >= publicState.revision)
        receivedHint = true
        break
    }
    #expect(receivedHint)
    stream.cancel()
    let first = try await api.authorizeRoom(roomID: "friends", sequence: 1, login: login, password: nil)
    do {
        _ = try await api.authorizeRoom(roomID: roomID, sequence: 2, login: login, password: "incorrect password")
        Issue.record("Wrong password switched real server admission")
    } catch let error as APIError { #expect(error.needsRoomPassword) }
    #expect(try await api.joinSequence(for: login) == 1)
    let second = try await api.authorizeRoom(roomID: roomID, sequence: 2, login: login, password: password)
    #expect(second.entryID != first.entryID)
    try await api.leave(first.admission)
    let retry = try await api.authorizeRoom(roomID: roomID, sequence: 2, login: login, password: password)
    #expect(retry.entryID == second.entryID)
    try await api.leave(second.admission)
}
