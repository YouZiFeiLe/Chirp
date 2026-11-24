import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor private final class StateSnapshotGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class StateFeedFixture: Sendable {
    struct Reply: Sendable { let snapshot: ClientStateSnapshot; var gate: StateSnapshotGate? }
    struct State {
        var replies: [Reply]
        var snapshots = 0, connections = 0, sources = 0, closes = 0
        var continuations: [AsyncThrowingStream<HTTPEvent, Error>.Continuation] = []
    }
    let state: Mutex<State>
    init(_ replies: [Reply]) { state = Mutex(State(replies: replies)) }
    func source(_ login: ClientSession) -> ClientStateSource {
        state.withLock { $0.sources += 1 }
        return ClientStateSource(snapshot: { [self] in
            let reply = state.withLock { value in
                value.snapshots += 1
                return value.replies.count > 1 ? value.replies.removeFirst() : value.replies[0]
            }
            await reply.gate?.wait()
            return reply.snapshot
        }, connect: { [self] in
            let pair = AsyncThrowingStream<HTTPEvent, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
            state.withLock { $0.connections += 1; $0.continuations.append(pair.continuation) }
            return ClientStateStream(events: pair.stream, cancel: { pair.continuation.finish() })
        }, close: { [self] in state.withLock { $0.closes += 1 } })
    }
    func hint(_ revision: UInt64, server: String = "server-one") throws {
        let data = try JSONSerialization.data(withJSONObject: ["server_id": server, "revision": revision])
        state.withLock { $0.continuations.last }?.yield(HTTPEvent(name: "state", data: data))
    }
    func disconnect() { state.withLock { $0.continuations.last }?.finish(throwing: URLError(.networkConnectionLost)) }
}

private func stateLogin(_ marker: String = "a") throws -> ClientSession {
    try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "member": ["id": "member_test", "display_name": "Member"],
        "credential": "chirp_" + String(repeating: marker, count: 43),
        "participant_identity": "member_test.login_" + marker, "expires_at": Date().timeIntervalSince1970 + 3600,
    ]), connection: testServerConnection)
}

private func stateSnapshot(_ revision: UInt64, server: String = "server-one", name: String = "Room") -> ClientStateSnapshot {
    ClientStateSnapshot(serverID: server, revision: revision,
        rooms: [RoomOverview(roomID: "friends", displayName: name, keyProtocol: VoiceRooms.keyProtocol, maxParticipants: 0,
                             participants: [], mediaStatus: "available", passwordRequired: false, isDefault: true)],
        members: [MemberProfile(id: "member_test", displayName: name, profileRevision: Int64(revision), avatarRevision: nil)])
}

@MainActor private func waitForState(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "state synchronization timeout", code: 1) }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor @Test func foregroundWindowsShareOneFeedAndReconnectFromAFullSnapshot() async throws {
    let login = try stateLogin(), directory = RoomDirectory(), profiles = MemberProfiles()
    profiles.reset(credential: login.credential, server: login.connection.apiURL)
    let fixture = StateFeedFixture([.init(snapshot: stateSnapshot(2)), .init(snapshot: stateSnapshot(4, name: "Updated")),
                                    .init(snapshot: stateSnapshot(1, server: "server-restarted", name: "Restarted"))])
    var invalid: ClientFailure?
    let sync = ClientStateSync(directory: directory, profiles: profiles, makeSource: { fixture.source($0) }) { invalid = $0 }
    let one = UUID(), two = UUID()
    sync.reset(for: login); sync.setVisible(one, true); sync.setVisible(two, true)
    defer { sync.reset(for: nil); profiles.reset(credential: nil, server: nil) }
    try await waitForState { directory.isFresh }
    #expect(fixture.state.withLock { $0.sources == 1 && $0.connections == 1 && $0.snapshots == 1 })
    try fixture.hint(2); try fixture.hint(1)
    try await Task.sleep(for: .milliseconds(30))
    #expect(fixture.state.withLock { $0.snapshots } == 1)
    try fixture.hint(4)
    try await waitForState { directory.rooms.first?.displayName == "Updated" }
    #expect(profiles.members["member_test"]?.displayName == "Updated")
    try fixture.hint(3)
    try await Task.sleep(for: .milliseconds(30))
    #expect(fixture.state.withLock { $0.snapshots } == 2)
    sync.setVisible(one, false)
    #expect(fixture.state.withLock { $0.closes } == 0)
    fixture.disconnect()
    try await waitForState { !directory.isFresh }
    try await waitForState { directory.rooms.first?.displayName == "Restarted" && directory.isFresh }
    #expect(fixture.state.withLock { $0.connections == 2 && $0.snapshots == 3 })
    #expect(invalid == nil)
    sync.setVisible(two, false)
    #expect(!directory.isFresh && fixture.state.withLock { $0.closes } == 1)
}

@MainActor @Test func lateSnapshotsFromRetiredLoginCannotOverwriteTheNewAccount() async throws {
    let old = try stateLogin(), new = try stateLogin("b"), directory = RoomDirectory(), profiles = MemberProfiles(), gate = StateSnapshotGate()
    profiles.reset(credential: old.credential, server: old.connection.apiURL)
    let fixture = StateFeedFixture([.init(snapshot: stateSnapshot(9, name: "Retired"), gate: gate), .init(snapshot: stateSnapshot(1, name: "New login"))])
    let sync = ClientStateSync(directory: directory, profiles: profiles, makeSource: { fixture.source($0) }) { _ in Issue.record("Unexpected invalidation") }
    defer { sync.reset(for: nil); profiles.reset(credential: nil, server: nil) }
    sync.setVisible(UUID(), true); sync.reset(for: old)
    try await waitForState { gate.entered }
    profiles.reset(credential: new.credential, server: new.connection.apiURL); sync.reset(for: new)
    try await waitForState { directory.isFresh }
    gate.release()
    try await Task.sleep(for: .milliseconds(30))
    #expect(directory.rooms.first?.displayName == "New login" && profiles.members["member_test"]?.displayName == "New login")
    #expect(fixture.state.withLock { $0.sources == 2 && $0.closes == 1 })
}

@MainActor @Test func olderSnapshotsAreRejectedBeforeApplyingAndRevocationInvalidatesLogin() async throws {
    let login = try stateLogin(), directory = RoomDirectory(), profiles = MemberProfiles()
    profiles.reset(credential: login.credential, server: login.connection.apiURL)
    let fixture = StateFeedFixture([.init(snapshot: stateSnapshot(5, name: "Current")), .init(snapshot: stateSnapshot(4, name: "Stale"))])
    var invalid: ClientFailure?
    let sync = ClientStateSync(directory: directory, profiles: profiles, makeSource: { fixture.source($0) }) { invalid = $0 }
    defer { sync.reset(for: nil); profiles.reset(credential: nil, server: nil) }
    sync.setVisible(UUID(), true); sync.reset(for: login)
    try await waitForState { directory.isFresh }
    try fixture.hint(6)
    try await waitForState { !directory.isFresh }
    #expect(directory.rooms.first?.displayName == "Current" && profiles.members["member_test"]?.displayName == "Current")
    // Reconnect also preserves the minimum accepted version for this server.
    try await waitForState { fixture.state.withLock { $0.connections >= 2 && $0.snapshots >= 3 } }
    #expect(directory.rooms.first?.displayName == "Current")
    sync.reset(for: nil)
    fixture.state.withLock { $0.replies = [.init(snapshot: stateSnapshot(7))] }
    sync.reset(for: login)
    try await waitForState { directory.isFresh }
    fixture.state.withLock { $0.continuations.last }?.yield(HTTPEvent(name: "revoked", data: Data("{}".utf8)))
    try await waitForState { invalid != nil }
    #expect(invalid?.code == "UNAUTHORIZED")
}
