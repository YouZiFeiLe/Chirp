import ChirpMLS
import CryptoKit
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor
private final class StartupGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor
private final class TestPeer {
    let login: ClientSession
    let identityStore: DeviceIdentityStore
    let admission: RoomAdmission
    let url: URL
    var identity: String { admission.identity }
    var session: GroupSession!
    var keys: [String: Data] = [:]
    var members: [String] = []
    var readyCount = 0
    var pauses = 0
    var failure: ClientFailure?
    var installedSenderKeys = Set<Data>()
    var reinstalledRetiredKey = false
    var stagedKeys: [String: Data] = [:]
    var rotations = 0
    var retiredIndices: [Int32] = []
    var mediaActive = false
    var native: MLSClient?
    var pauseGate: StartupGate?
    var allReadyGroupID: String?
    var startedAt: ContinuousClock.Instant?
    var readyAt: ContinuousClock.Instant?
    var roomIdentity: RoomIdentity?
    var publicInformation: RoomPublicInformation?

    init(_ index: Int, url: URL, roomID: String = "friends", startupDelay: Duration = .zero, gate: StartupGate? = nil, installGate: StartupGate? = nil,
         smoothRotation: Bool = false, rotationGate: StartupGate? = nil, rejectRotation: Bool = false, approve: Bool = true,
         fixture: V5TestIdentity? = nil) throws {
        self.url = url
        identityStore = try testIdentityStore(String(format: "group-peer-%02d", index), fixture: fixture)
        let id = String(format: "member%02d", index)
        let payload: [String: Any] = ["device_identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(identityStore.requireDevice())), "member": ["id": id, "display_name": "Peer \(index)"],
            "credential": String(format: "chirp_%02d", index) + String(repeating: "a", count: 41),
            "participant_identity": id + ".login_test", "expires_at": Date().timeIntervalSince1970 + 3600]
        login = try ClientSession(data: JSONSerialization.data(withJSONObject: payload), connection: ServerConnection(apiURL: url, passkeyOrigin: testServerConnection.passkeyOrigin))
        let entryID = "entry_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        admission = RoomAdmission(roomID: roomID, entryID: entryID, identity: login.participantIdentity + "." + entryID)
        var prepare: GroupSession.Prepare?
        var switching: GroupSession.Switch?
        var retire: GroupSession.Switch?
        if smoothRotation {
            prepare = { @MainActor @Sendable [weak self] native, members, _ in
                guard let self else { return }
                if rejectRotation { throw CancellationError() }
                var next: [String: Data] = [:]
                for peer in members { next[peer.identity] = try await native.senderKey(for: peer.identity, staged: true) }
                if let rotationGate, !rotationGate.entered { await rotationGate.wait() }
                self.stagedKeys = next
            }
            switching = { @MainActor @Sendable [weak self] _ in
                guard let self else { return }
                self.keys = self.stagedKeys; self.rotations += 1
            }
            retire = { @MainActor @Sendable [weak self] index in self?.retiredIndices.append(index) }
        }
        session = try GroupSession(baseURL: url.appendingPathComponent("v1/group"), login: login, admission: admission, identity: identityStore, onPause: { [weak self] in
            #expect(self?.session.maySend != true)
            self?.pauses += 1
            self?.mediaActive = false
            if let gate = self?.pauseGate { await gate.wait() }
        }, onInstall: { [weak self] native, members in
            guard let self else { return }
            self.native = native
            var next: [String: Data] = [:]
            for peer in members { next[peer.identity] = try await native.senderKey(for: peer.identity) }
            if let ownKey = next[self.identity] {
                if !self.installedSenderKeys.insert(ownKey).inserted { self.reinstalledRetiredKey = true }
            }
            self.keys = next
            if let installGate, !installGate.entered { await installGate.wait() }
        }, onReady: { [weak self] members in
            try self?.roomIdentity?.keysReady()
            if self?.readyCount == 0 { try await Task.sleep(for: startupDelay) }
            if let gate { await gate.wait() }
            self?.members = members.map(\.identity).sorted()
            self?.readyCount += 1
            self?.mediaActive = true
            self?.readyAt = .now
        }, onFailure: { [weak self] message in self?.failure = message }, onPrepare: prepare, onSwitch: switching, onRetire: retire, approveRoster: { [weak self] peers in
            if peers.allSatisfy({ $0.ready != nil }) { self?.allReadyGroupID = peers.first?.ready?.groupID }
            if let room = self?.roomIdentity { return try room.approveRoster(peers) }
            return approve ? V5Crypto.hash(Data("locally verified test roster".utf8)) : nil
        }, authorizationDeadline: { [weak self] in
            if let room = self?.roomIdentity { return room.social.sendingDeadline }
            return .now.advanced(by: .seconds(60))
        }, onRoomInformation: { [weak self] information in
            if let information { self?.publicInformation = information }
            else { self?.publicInformation?.unavailable = true }
        })
    }
    func start() async throws {
        var request = URLRequest(url: url.appendingPathComponent("test/admission")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["member_id": login.member.id, "room_id": admission.roomID, "entry_id": admission.entryID, "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(identityStore.requireDevice()))])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw NSError(domain: "GroupSessionTests", code: 1) }
        if !admission.roomID.hasPrefix("mutual-") { try await trustFixtureRoom(identityStore, url: url, roomID: admission.roomID) }
        startedAt = .now
        session.start()
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func changedServerDuringMediaConnectRequiresFreshGroupConfiguration() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let peer = try TestPeer(0, url: url, roomID: "mutual-prefetch")
    do {
        await peer.session.prepareConfiguration()
        #expect(peer.session.groupID == nil && peer.keys.isEmpty && !peer.session.maySend)
        var restart = URLRequest(url: url.appendingPathComponent("test/restart"))
        restart.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: restart)
        try #require((response as? HTTPURLResponse)?.statusCode == 204)
        try await peer.start()
        try await waitUntil("freshly verified group after server restart") { peer.mediaActive && peer.session.maySend }
        #expect(peer.failure == nil && peer.readyCount == 1)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupPauseErasesBothRoundsWhileMediaIsBlocked() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let preparing = StartupGate(), pausing = StartupGate()
    let peer = try TestPeer(0, url: url, roomID: "pause-both-rounds", smoothRotation: true, rotationGate: preparing)
    do {
        try await peer.start()
        try await waitUntil("two live MLS rounds") { preparing.entered }
        let native = try #require(peer.native)
        let identityKey = try await native.publicKey()
        let old = try await native.senderKey(for: peer.identity)
        let candidate = try await native.senderKey(for: peer.identity, staged: true)
        #expect(candidate != old)
        peer.pauseGate = pausing
        let pause = Task { try await peer.session.suspend() }
        try await waitUntil("media pause is still in progress") { pausing.entered }
        #expect(!peer.session.maySend)
        for staged in [false, true] {
            await #expect(throws: MLSError.self) { try await native.senderKey(for: peer.identity, staged: staged) }
            await #expect(throws: MLSError.self) { try await native.keyLifetimeMilliseconds(staged: staged) }
        }
        #expect(try await native.publicKey() == identityKey)
        peer.pauseGate = nil; pausing.release(); preparing.release()
        try await pause.value
        try await peer.session.refresh()
        try await waitUntil("fresh authorized MLS round") { peer.session.maySend && peer.keys[peer.identity] != old }
        #expect(try await native.senderKey(for: peer.identity) != candidate)
        await peer.session.stop()
    } catch {
        peer.pauseGate = nil; pausing.release(); preparing.release()
        await peer.session.stop(); throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupResumesOnlyAfterEveryReadyAndFirstLease() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let room = "first-playout-lease", gate = StartupGate()
    let alice = try TestPeer(0, url: url, roomID: room)
    let bob = try TestPeer(1, url: url, roomID: room, installGate: gate)
    do {
        try await alice.start()
        try await waitUntil("existing active participant") { alice.mediaActive }
        try await bob.start()
        try await waitUntil("one member still owes confirmation") { gate.entered && alice.keys.count == 2 }
        #expect(!alice.mediaActive && !bob.mediaActive && !alice.session.maySend)
        let groupID = try #require(alice.session.groupID)
        try await setGroupDelay("lease", roomID: room, url: url, requestMS: 0, responseMS: 1_200)
        gate.release()
        try await waitUntil("both see the full set of signed ready proofs") {
            alice.allReadyGroupID == groupID && bob.allReadyGroupID == groupID
        }
        #expect(!alice.mediaActive && !bob.mediaActive && !alice.session.maySend)
        try await waitUntil("both have verified confirmations and leases") {
            alice.mediaActive && bob.mediaActive && alice.session.maySend && bob.session.maySend
        }
        await alice.session.stop(); await bob.session.stop()
    } catch { gate.release(); await alice.session.stop(); await bob.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupIdentityExpiryRetiresMediaWhileServerSnapshotIsStalled() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let roomID = "identity-expiry"
    var setup = URLRequest(url: url.appendingPathComponent("test/v5-expiry")); setup.httpMethod = "POST"
    setup.httpBody = try JSONSerialization.data(withJSONObject: ["room_id": roomID, "seconds": 4])
    let (_, response) = try await URLSession.shared.data(for: setup)
    #expect((response as? HTTPURLResponse)?.statusCode == 204)
    let peer = try TestPeer(0, url: url, roomID: roomID, smoothRotation: true)
    do {
        try await peer.start()
        try await waitUntil("expiry fixture ready") { peer.session.maySend && peer.mediaActive }
        try await Task.sleep(for: .milliseconds(2_150))
        let policy = try peer.identityStore.roomPolicy(origin: ServerAddress.normalized(url), roomID: roomID)
        let remaining = Double(policy.notAfter) - Date().timeIntervalSince1970
        let queued = try #require(peer.session.sendingDeadline)
        #expect(ContinuousClock.now.duration(to: queued) <= .seconds(remaining + 0.01))
        let pauses = peer.pauses
        // A rotation hint at ~2.5s blocks drive in a snapshot. The last valid
        // lease extends past the known identity expiry, so neither an HTTP
        // response nor lease expiry can supply the stop callback being tested.
        for operation in ["snapshot", "lease", "heartbeat"] {
            try await setGroupDelay(operation, roomID: roomID, url: url, requestMS: 1_800, responseMS: 1_800)
        }
        try await Task.sleep(for: .seconds(max(0, remaining) + 0.25))
        #expect(!peer.session.maySend && !peer.mediaActive && peer.pauses > pauses)
        #expect(queued <= ContinuousClock.now)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupLocallyKnownRevocationCannotBeHiddenByOldServerSnapshots() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let roomID = "known-revocation"
    let alice = try TestPeer(0, url: url, roomID: roomID), bob = try TestPeer(1, url: url, roomID: roomID)
    do {
        try await alice.start(); try await bob.start()
        try await waitUntil("revocation fixture ready") { alice.session.maySend && bob.session.maySend }
        let owner = try V5TestIdentity("group-peer-00"), revoked = try V5TestIdentity("group-peer-01")
        var policy = try alice.identityStore.roomPolicy(origin: ServerAddress.normalized(url), roomID: roomID)
        policy.previousHash = policy.digest; policy.version += 1
        policy.members.removeAll { $0 == revoked.device.accountKey }
        policy.signature = try V5Crypto.sign(owner.key, policy.message)
        let pauses = alice.pauses
        // Only the local trust store receives this authentic revocation. The
        // adversarial coordinator continues serving its old policy and leases.
        try alice.identityStore.acceptRoomPolicy(policy, origin: policy.origin, roomID: policy.roomID)
        #expect(!alice.session.maySend && alice.session.sendingDeadline == nil)
        try await waitUntil("local revocation retires real media", timeout: 1) { !alice.mediaActive && alice.pauses > pauses }
        #expect(bob.session.maySend)
        await alice.session.stop(); await bob.session.stop()
    } catch { await alice.session.stop(); await bob.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupTerminalFailureCannotBeClearedByALateRestartConfiguration() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let roomID = "terminal-restart"
    let peer = try TestPeer(0, url: url, roomID: roomID)
    do {
        try await peer.start()
        try await waitUntil("restart fixture ready") { peer.session.maySend && peer.mediaActive }
        let readyCount = peer.readyCount
        // Longer than the watch worker's three attempts, but shorter than the
        // HTTP timeout: a successful late config must not clear the failure.
        try await setGroupDelay("config", roomID: roomID, url: url, requestMS: 1_700, responseMS: 0)
        var restart = URLRequest(url: url.appendingPathComponent("test/restart")); restart.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: restart)
        try await waitUntil("watch failure remains terminal", timeout: 8) { peer.failure != nil }
        try await Task.sleep(for: .milliseconds(300))
        #expect(!peer.session.maySend && !peer.mediaActive && peer.readyCount == readyCount)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

private func setGroupDelay(_ operation: String, roomID: String, url: URL, requestMS: Int, responseMS: Int) async throws {
    var request = URLRequest(url: url.appendingPathComponent("test/group-delay")); request.httpMethod = "POST"
    request.httpBody = try JSONSerialization.data(withJSONObject: [
        "room_id": roomID, "operation": operation, "request_ms": requestMS, "response_ms": responseMS,
    ])
    let (_, response) = try await URLSession.shared.data(for: request)
    #expect((response as? HTTPURLResponse)?.statusCode == 204)
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupSmoothRotationKeepsPermissionWhilePreparingAndAcrossRepeatedCutovers() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let gate = StartupGate()
    let alice = try TestPeer(0, url: url, smoothRotation: true)
    let bob = try TestPeer(1, url: url, smoothRotation: true, rotationGate: gate)
    let peers = [alice, bob]
    do {
        try await alice.start(); try await bob.start()
        try await waitUntil("smooth initial media barrier") { peers.allSatisfy { $0.session.maySend && $0.members.count == 2 && $0.readyCount > 0 } }
        #expect(peers.allSatisfy { $0.publicInformation?.information.memberCount == 2 && $0.publicInformation?.information.lastRotationAtMS == nil })
        let pauses = peers.map(\.pauses), groupID = alice.session.groupID, old = alice.keys
        try await waitUntil("candidate installation delayed") { gate.entered }
        #expect(peers.allSatisfy { $0.keys == old && $0.session.maySend })
        try await Task.sleep(for: .milliseconds(800))
        #expect(peers.allSatisfy { $0.keys == old && $0.session.maySend })
        gate.release()
        let started = ContinuousClock.now
        while peers.contains(where: { $0.rotations < 3 || $0.retiredIndices.count < 3 }) {
            #expect(peers.allSatisfy { $0.session.maySend && $0.failure == nil })
            #expect(peers.map(\.pauses) == pauses)
            #expect(peers.allSatisfy { $0.readyCount == 1 && $0.session.groupID == groupID })
            guard started.duration(to: .now) < .seconds(25) else { throw NSError(domain: "Smooth rotation stalled", code: 1) }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(alice.keys == bob.keys && alice.keys != old)
        #expect(alice.retiredIndices.prefix(3).elementsEqual([0, 1, 0]))
        try await waitUntil("shared rotation metadata reaches both verified clients") {
            peers.allSatisfy { ($0.publicInformation?.information.keyEpoch ?? 0) >= 3 && $0.publicInformation?.information.lastRotationAtMS != nil }
        }
        #expect(alice.publicInformation?.information.lastRotationAtMS == bob.publicInformation?.information.lastRotationAtMS)
        #expect(peers.allSatisfy { $0.publicInformation?.groupID == $0.session.groupID && $0.publicInformation?.isFresh() == true })
        print("SMOOTH_ROTATION cycles=3 permission_gaps=0 extra_pauses=0")
        for peer in peers { await peer.session.stop() }
    } catch { gate.release(); for peer in peers { await peer.session.stop() }; throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupSmoothRotationRenewsPermissionAfterDelayedActivation() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let roomID = "delayed-rotation"
    let alice = try TestPeer(0, url: url, roomID: roomID, smoothRotation: true)
    let bob = try TestPeer(1, url: url, roomID: roomID, smoothRotation: true)
    let peers = [alice, bob]
    do {
        try await setGroupDelay("lease", roomID: roomID, url: url, requestMS: 350, responseMS: 350)
        try await setGroupDelay("rotation_activate", roomID: roomID, url: url, requestMS: 900, responseMS: 200)
        try await alice.start(); try await bob.start()
        try await waitUntil("delayed rotation initial permission") { peers.allSatisfy { $0.session.maySend && $0.readyCount == 1 } }
        let pauses = peers.map(\.pauses), groupID = alice.session.groupID
        let started = ContinuousClock.now
        while peers.contains(where: { $0.retiredIndices.count < 4 }) {
            let permission = peers.map { $0.session.maySend }
            #expect(permission == [true, true])
            guard permission.allSatisfy({ $0 }), peers.allSatisfy({ $0.failure == nil }),
                  started.duration(to: .now) < .seconds(35) else {
                throw NSError(domain: "Delayed rotation lost permission", code: 1)
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        for peer in peers { #expect(peer.failure == nil, "\(peer.failure?.code ?? "no failure"), rotations=\(peer.rotations)") }
        #expect(peers.allSatisfy { $0.failure == nil && $0.session.maySend })
        #expect(peers.map(\.pauses) == pauses)
        #expect(peers.allSatisfy { $0.readyCount == 1 && $0.session.groupID == groupID })
        #expect(alice.keys == bob.keys)
        for peer in peers { await peer.session.stop() }
    } catch { for peer in peers { await peer.session.stop() }; throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupCompletedRotationSurvivesALateNextLease() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let roomID = "cutover-recovery"
    let alice = try TestPeer(0, url: url, roomID: roomID, smoothRotation: true)
    let bob = try TestPeer(1, url: url, roomID: roomID, smoothRotation: true)
    let peers = [alice, bob]
    do {
        try await setGroupDelay("lease", roomID: roomID, url: url, requestMS: 350, responseMS: 350)
        try await setGroupDelay("rotation_activate", roomID: roomID, url: url, requestMS: 1_500, responseMS: 300)
        try await alice.start(); try await bob.start()
        try await waitUntil("cutover recovery initial permission") { peers.allSatisfy { $0.session.maySend && $0.readyCount == 1 } }
        let keys = alice.keys
        // Activation can succeed on the server while the next epoch's first
        // lease still misses the old deadline. Preserve the sessions, allowing
        // either an uninterrupted cutover or a pause followed by fresh keys.
        try await waitUntil("completed cutover keeps both sessions", timeout: 16) {
            peers.contains { $0.failure != nil } || peers.allSatisfy {
                $0.session.maySend && $0.rotations > 0 && ($0.readyCount >= 2 || !$0.retiredIndices.isEmpty)
            }
        }
        for peer in peers { #expect(peer.failure == nil, "\(peer.failure?.code ?? "no failure")") }
        #expect(peers.allSatisfy { $0.session.maySend && !$0.reinstalledRetiredKey })
        #expect(alice.keys == bob.keys && alice.keys != keys)
        for peer in peers { await peer.session.stop() }
    } catch { for peer in peers { await peer.session.stop() }; throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupLeaseExpiryPausesAndRecoversWithFreshKeys() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let roomID = "lease-recovery", gate = StartupGate()
    let alice = try TestPeer(0, url: url, roomID: roomID, smoothRotation: true)
    let bob = try TestPeer(1, url: url, roomID: roomID, smoothRotation: true, rotationGate: gate)
    let peers = [alice, bob]
    do {
        try await setGroupDelay("lease", roomID: roomID, url: url, requestMS: 350, responseMS: 350)
        try await alice.start(); try await bob.start()
        try await waitUntil("lease recovery initial permission") { peers.allSatisfy { $0.session.maySend && $0.readyCount == 1 } }
        let pauses = peers.map(\.pauses), groupID = alice.session.groupID, keys = alice.keys
        try await waitUntil("candidate is deliberately stalled") { gate.entered }
        // Keep the candidate blocked past the finite rotation deadline. The
        // expired lease must pause sending and rebuild, preserving admission.
        try await waitUntil("expired lease pauses sending", timeout: 12) {
            peers.contains { $0.failure != nil } || zip(peers, pauses).contains { $0.0.pauses > $0.1 }
        }
        #expect(peers.allSatisfy { $0.failure == nil })
        #expect(peers.contains { !$0.session.maySend })
        gate.release()
        try await waitUntil("fresh round restores the same sessions") {
            peers.contains { $0.failure != nil } || peers.allSatisfy {
                $0.session.maySend && $0.readyCount >= 2 && $0.members.count == 2 && $0.session.groupID != groupID
            }
        }
        #expect(peers.allSatisfy { $0.failure == nil && $0.session.maySend && !$0.reinstalledRetiredKey })
        #expect(alice.keys == bob.keys && alice.keys != keys)
        for peer in peers { await peer.session.stop() }
    } catch { gate.release(); for peer in peers { await peer.session.stop() }; throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupSmoothRotationRevocationRejectsLatePreparedInstall() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let gate = StartupGate()
    let alice = try TestPeer(0, url: url, roomID: "room-2", smoothRotation: true, rotationGate: gate)
    let bob = try TestPeer(1, url: url, roomID: "room-2", smoothRotation: true)
    do {
        try await alice.start(); try await bob.start()
        try await waitUntil("revocation initial barrier") { alice.session.maySend && bob.session.maySend && alice.members.count == 2 }
        let old = alice.keys
        try await waitUntil("revocation while candidate installing") { gate.entered }
        var request = URLRequest(url: url.appendingPathComponent("test/revoke")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["member_id": bob.login.member.id])
        _ = try await URLSession.shared.data(for: request)
        try await waitUntil("revocation pauses both old senders", timeout: 3) { !alice.session.maySend && !bob.session.maySend }
        gate.release()
        try await waitUntil("survivor recovers with a fresh admission round") { alice.session.maySend && alice.members.count == 1 && alice.keys != old }
        #expect(alice.rotations == 0 && alice.failure == nil)
        await alice.session.stop(); await bob.session.stop()
    } catch { gate.release(); await alice.session.stop(); await bob.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupModernClientRejectsLegacyServer() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    func mode(_ legacy: Bool) async throws {
        var request = URLRequest(url: url.appendingPathComponent(legacy ? "test/legacy" : "test/modern")); request.httpMethod = "POST"
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
    }
    let peer = try TestPeer(2, url: url, roomID: "legacy-room", smoothRotation: true)
    try await mode(true)
    do {
        try await peer.start()
        try await waitUntil("legacy coordinator is rejected") { peer.failure != nil }
        #expect(!peer.session.maySend && peer.keys.isEmpty && peer.readyCount == 0)
        #expect(peer.failure?.code == ClientErrorCode.groupProtocolMismatch.rawValue)
        await peer.session.stop(); try await mode(false)
    } catch { await peer.session.stop(); try? await mode(false); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupSmoothRotationUnexpectedMediaRejectionFailsClosed() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let peer = try TestPeer(2, url: url, roomID: "rejected-media", smoothRotation: true, rejectRotation: true)
    do {
        try await peer.start()
        try await waitUntil("rejection initial barrier") { peer.session.maySend && peer.readyCount == 1 }
        try await waitUntil("unexpected native rejection is surfaced", timeout: 8) { peer.failure != nil && !peer.session.maySend }
        #expect(peer.failure?.code == ClientErrorCode.groupCryptoFailed.rawValue && peer.rotations == 0)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

@MainActor
private func waitUntil(_ description: String, timeout: TimeInterval = 20, _ predicate: () -> Bool) async throws {
    let started = ProcessInfo.processInfo.systemUptime
    while !predicate() {
        guard ProcessInfo.processInfo.systemUptime - started < timeout else { throw NSError(domain: "GroupSessionTests: \(description)", code: 2) }
        try await Task.sleep(for: .milliseconds(50))
    }
}

// Time the real group coordinator and first lease. Identity HTTP responses are
// local fixtures, with signed accounts and trust records established before timing.
@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_STARTUP_METRICS"] != nil))
@MainActor func groupStartupTimings() async throws {
    let env = ProcessInfo.processInfo.environment
    let url = try #require(env["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let output = try #require(env["CHIRP_GROUP_STARTUP_METRICS"])
    let rtt = try #require(Int(env["CHIRP_GROUP_STARTUP_RTT_MS"] ?? "0"))
    try #require((0...3_600).contains(rtt))
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [IdentityBusURLProtocol.self]
    var samples: [[String: Double]] = []
    func milliseconds(from start: ContinuousClock.Instant, to end: ContinuousClock.Instant) -> Double {
        let parts = start.duration(to: end).components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }
    for index in 0..<10 {
        let roomID = "mutual-startup-\(index)"
        if rtt > 0 {
            for operation in ["config", "join", "snapshot", "package", "publish", "ack", "lease", "heartbeat", "refresh"] {
                try await setGroupDelay(operation, roomID: roomID, url: url, requestMS: rtt / 2, responseMS: rtt - rtt / 2)
            }
        }
        let a = try V5TestIdentity("group-peer-00"), b = try V5TestIdentity("group-peer-01")
        let alice = try TestPeer(0, url: url, roomID: roomID, smoothRotation: true, fixture: a)
        let bob = try TestPeer(1, url: url, roomID: roomID, smoothRotation: true, fixture: b)
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        defer { for peer in [alice, bob] { peer.roomIdentity?.end(); peer.roomIdentity?.social.reset(for: nil) } }
        for (peer, fixture) in [(alice, a), (bob, b)] {
            try IdentityBusURLProtocol.register(fixture)
            IdentityBusURLProtocol.state.withLock { $0.accounts[peer.login.credential] = (peer.login.member.id, fixture.device) }
            let social = SocialIdentity(identity: peer.identityStore, persistence: MemoryIdentityPersistence(), configuration: config, authority: IdentityBusURLProtocol.authorityConfiguration)
            let room = RoomIdentity(identity: peer.identityStore, social: social, configuration: config)
            social.onChange = { [weak room] in room?.localTrustChanged() }
            peer.roomIdentity = room
            social.reset(for: peer.login)
        }
        do {
            for (peer, other, device) in [(alice, bob, b.device), (bob, alice, a.device)] {
                let social = try #require(peer.roomIdentity?.social)
                try await waitUntil("initial signed authorization") { social.voiceAllowed && !social.isRefreshing }
                await social.change(operation: "trust", friendID: other.login.member.id, device: device, name: other.login.member.displayName)
                try #require(social.friends.contains { $0.trustedDevices.contains(device.leafKey) })
            }
            alice.roomIdentity?.begin(login: alice.login, admission: alice.admission)
            try await alice.start()
            try await waitUntil("solo ready") { alice.session.maySend && alice.mediaActive }
            let solo = milliseconds(from: try #require(alice.startedAt), to: try #require(alice.readyAt))
            bob.roomIdentity?.begin(login: bob.login, admission: bob.admission)
            try await bob.start()
            try await waitUntil("both trusted devices ready") {
                [alice, bob].allSatisfy { $0.session.maySend && $0.mediaActive && $0.members.count == 2 }
            }
            try #require(alice.keys == bob.keys)
            let bothReady = max(try #require(alice.readyAt), try #require(bob.readyAt))
            samples.append(["solo_ms": solo, "trusted_pair_ms": milliseconds(from: try #require(bob.startedAt), to: bothReady)])
        } catch { await alice.session.stop(); await bob.session.stop(); throw error }
        await alice.session.stop(); await bob.session.stop()
    }
    try JSONEncoder().encode(samples).write(to: URL(fileURLWithPath: output))
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_MEASURE"] != nil))
@MainActor func groupSteadyStateTraffic() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let peer = try TestPeer(0, url: url)
    do {
        try await peer.start()
        try await waitUntil("traffic measurement ready") { peer.session.maySend && peer.readyCount > 0 }
        var reset = URLRequest(url: url.appendingPathComponent("test/metrics")); reset.httpMethod = "DELETE"
        _ = try await URLSession.shared.data(for: reset)
        let started = ContinuousClock.now
        try await Task.sleep(for: .seconds(4))
        let (data, _) = try await URLSession.shared.data(from: url.appendingPathComponent("test/metrics"))
        let metrics = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Int])
        #expect(peer.session.maySend && peer.failure == nil)
        print("GROUP_TRAFFIC seconds=\(started.duration(to: .now)) metrics=\(String(decoding: data, as: UTF8.self))")
        if let output = ProcessInfo.processInfo.environment["CHIRP_GROUP_MEASURE"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
        #expect((metrics["requests"] ?? 0) > 0)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupEventRecoveryIntegration() async throws {
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    let alice = try TestPeer(0, url: url), bob = try TestPeer(1, url: url), peers = [alice, bob]
    func control(_ path: String, body: [String: String]? = nil) async throws {
        var request = URLRequest(url: url.appendingPathComponent("test/" + path)); request.httpMethod = "POST"
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 204)
    }
    var timings: [String: Double] = [:]
    do {
        try await alice.start(); try await bob.start()
        try await waitUntil("event recovery initial barrier") { peers.allSatisfy { $0.session.maySend && $0.members.count == 2 } }
        let initial = alice.keys[alice.identity], started = ContinuousClock.now
        try await control("disconnect-events")
        try await waitUntil("event disconnection pauses sending", timeout: 3) { peers.allSatisfy { !$0.session.maySend } }
        try await waitUntil("event reconnection installs fresh keys") { peers.allSatisfy { $0.session.maySend && $0.keys == alice.keys } && alice.keys[alice.identity] != initial }
        timings["event_recovery_seconds"] = Double(started.duration(to: .now).components.attoseconds) / 1e18 + Double(started.duration(to: .now).components.seconds)
        let beforeRestart = alice.keys[alice.identity], beforeGroupID = alice.session.groupID, restarting = ContinuousClock.now
        let pausesBeforeRestart = peers.map(\.pauses)
        try await control("restart")
        // Check revocation at each participant's pause callback, even when a
        // complete restart and rekey fit between two observer samples.
        try await waitUntil("server restart invalidates sending", timeout: 3) {
            zip(peers, pausesBeforeRestart).allSatisfy { $0.pauses > $1 }
        }
        try await waitUntil("new server obtains new snapshot and keys") {
            peers.allSatisfy { $0.session.maySend && $0.keys == alice.keys } && alice.keys[alice.identity] != beforeRestart && alice.session.groupID != beforeGroupID
        }
        timings["server_restart_seconds"] = Double(restarting.duration(to: .now).components.attoseconds) / 1e18 + Double(restarting.duration(to: .now).components.seconds)
        let beforeRevoke = alice.keys[alice.identity], revoking = ContinuousClock.now
        try await control("revoke", body: ["member_id": bob.login.member.id])
        try await waitUntil("revoked member cannot send", timeout: 3) { !bob.session.maySend && bob.failure != nil }
        timings["revocation_stop_seconds"] = Double(revoking.duration(to: .now).components.attoseconds) / 1e18 + Double(revoking.duration(to: .now).components.seconds)
        try await waitUntil("remaining member creates a new round") { alice.session.maySend && alice.members.count == 1 && alice.keys[alice.identity] != beforeRevoke }
        #expect(alice.failure == nil && peers.allSatisfy { !$0.reinstalledRetiredKey })
        print("GROUP_RECOVERY", timings)
        if let output = ProcessInfo.processInfo.environment["CHIRP_GROUP_RECOVERY_METRICS"] {
            try JSONSerialization.data(withJSONObject: timings, options: [.sortedKeys]).write(to: URL(fileURLWithPath: output))
        }
        for peer in peers { await peer.session.stop() }
        // Deliberately finish an old native key install after a transport
        // suspension. It must be discarded and followed by a fresh MLS round.
        let gate = StartupGate()
        let slow = try TestPeer(2, url: url, roomID: "room-2", installGate: gate)
        do {
            try await slow.start()
            try await waitUntil("old key install entered") { gate.entered }
            try await slow.session.suspend(); try await slow.session.refresh()
            #expect(!slow.session.maySend)
            gate.release()
            try await waitUntil("late install replaced with a fresh round") { slow.session.maySend && slow.readyCount == 1 }
            #expect(slow.installedSenderKeys.count == 2 && !slow.reinstalledRetiredKey && slow.failure == nil)
            await slow.session.stop()
        } catch { gate.release(); await slow.session.stop(); throw error }
    } catch { for peer in peers { await peer.session.stop() }; throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupCoordinatorIntegration() async throws {
    // Ordinary model tests do not launch background services. The dedicated
    // script supplies a disposable loopback fixture for this integration test.
    guard let endpoint = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let url = URL(string: endpoint) else { return }
    var peers: [TestPeer] = []
    do {
        let alice = try TestPeer(0, url: url, startupDelay: .seconds(4)); peers.append(alice); try await alice.start()
        try await waitUntil("solo activation") { alice.session.maySend }
        try await waitUntil("slow audio startup does not block heartbeats", timeout: 5) { alice.readyCount == 1 }
        #expect(alice.session.maySend && alice.failure == nil)
        let soloKey = try #require(alice.keys[alice.identity])

        let bob = try TestPeer(1, url: url); peers.append(bob); try await bob.start()
        try await waitUntil("two-member barrier") { peers.allSatisfy { $0.session.maySend && $0.members.count == 2 } }
        let pairKey = try #require(alice.keys[alice.identity])
        #expect(pairKey != soloKey)
        #expect(alice.keys == bob.keys)
        #expect(alice.keys[alice.identity] != alice.keys[bob.identity])
        let packet = try AES.GCM.seal(Data("new round audio".utf8), using: SymmetricKey(data: pairKey))
        #expect(throws: (any Error).self) { try AES.GCM.open(packet, using: SymmetricKey(data: soloKey)) }

        let priorReady = alice.readyCount
        try await alice.session.refresh()
        #expect(!alice.session.maySend)
        try await waitUntil("reconnect forces new keys") { alice.readyCount > priorReady && peers.allSatisfy { $0.session.maySend } && alice.keys == bob.keys }
        #expect(alice.keys[alice.identity] != pairKey)

        let beforeAuthorityOutage = alice.keys[alice.identity]
        var authorityOutage = URLRequest(url: url.appendingPathComponent("test/authority-outage"))
        authorityOutage.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: authorityOutage)
        try await waitUntil("authority suspension pauses media", timeout: 3) { peers.allSatisfy { !$0.session.maySend } }
        try await Task.sleep(for: .milliseconds(1_200))
        #expect(peers.allSatisfy { !$0.reinstalledRetiredKey && !$0.session.maySend })
        var authorityRecover = URLRequest(url: url.appendingPathComponent("test/authority-recover"))
        authorityRecover.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: authorityRecover)
        try await waitUntil("authority recovery creates fresh keys") {
            peers.allSatisfy { $0.session.maySend && $0.keys == alice.keys } && alice.keys[alice.identity] != beforeAuthorityOutage
        }
        #expect(peers.allSatisfy { !$0.reinstalledRetiredKey && $0.failure == nil })

        for index in 2..<24 { let peer = try TestPeer(index, url: url); peers.append(peer); try await peer.start() }
        try await waitUntil("24-member agreement", timeout: 30) { peers.allSatisfy { $0.session.maySend && $0.members.count == 24 } }
        #expect(peers.allSatisfy { $0.keys == alice.keys && $0.failure == nil })
        let fullKey = try #require(alice.keys[alice.identity])
        let removed = peers.removeLast()
        await removed.session.stop()
        try await waitUntil("member removal") { peers.allSatisfy { $0.session.maySend && $0.members.count == 23 } }
        let afterRemoval = try #require(alice.keys[alice.identity])
        #expect(afterRemoval != fullKey)
        #expect(!removed.session.maySend)
        let nextPacket = try AES.GCM.seal(Data("after removal".utf8), using: SymmetricKey(data: afterRemoval))
        #expect(throws: (any Error).self) { try AES.GCM.open(nextPacket, using: SymmetricKey(data: fullKey)) }

        try await waitUntil("periodic rotation", timeout: 15) {
            peers.allSatisfy { $0.session.maySend && $0.keys == alice.keys } && alice.keys[alice.identity] != afterRemoval
        }
        #expect(peers.allSatisfy { $0.failure == nil })

        var outage = URLRequest(url: url.appendingPathComponent("test/outage")); outage.httpMethod = "POST"
        _ = try await URLSession.shared.data(for: outage)
        try await waitUntil("temporary outage pauses media", timeout: 3) { peers.allSatisfy { !$0.session.maySend } }
        var recover = URLRequest(url: url.appendingPathComponent("test/recover")); recover.httpMethod = "POST"
        let beforeRecovery = alice.keys[alice.identity]
        _ = try await URLSession.shared.data(for: recover)
        try await waitUntil("transport recovery replaces keys", timeout: 20) {
            peers.allSatisfy { $0.session.maySend && $0.keys == alice.keys } && alice.keys[alice.identity] != beforeRecovery
        }
        #expect(peers.allSatisfy { $0.failure == nil })
        _ = try await URLSession.shared.data(for: outage)
        try await waitUntil("all clients fail closed", timeout: 8) { peers.allSatisfy { !$0.session.maySend && $0.failure != nil } }
        #expect(peers.allSatisfy { $0.pauses > 1 })
        for peer in peers { await peer.session.stop() }
        _ = try await URLSession.shared.data(for: recover)
        let gate = StartupGate()
        let restarting = try TestPeer(19, url: url, gate: gate)
        peers.append(restarting)
        try await restarting.start()
        do {
            try await waitUntil("media startup entered cancellation gate") { gate.entered }
            restarting.session.cancel()
            var stopped = false
            let stopper = Task { await restarting.session.stop(); stopped = true }
            try await Task.sleep(for: .milliseconds(200))
            #expect(!stopped)
            gate.release()
            await stopper.value
            #expect(stopped && !restarting.session.maySend)
        } catch {
            gate.release()
            throw error
        }
        let roomA = try TestPeer(0, url: url, roomID: "room-2")
        let roomB = try TestPeer(1, url: url, roomID: "room-3")
        peers.append(contentsOf: [roomA, roomB])
        try await roomA.start(); try await roomB.start()
        try await waitUntil("independent rooms ready") { roomA.session.maySend && roomB.session.maySend }
        let unrelatedKey = roomB.keys[roomB.identity]
        let unrelatedPauses = roomB.pauses
        let friendA = try TestPeer(2, url: url, roomID: "room-2"); peers.append(friendA); try await friendA.start()
        try await waitUntil("room A member added") { roomA.session.maySend && friendA.session.maySend && roomA.members.count == 2 }
        #expect(roomB.keys[roomB.identity] == unrelatedKey && roomB.pauses == unrelatedPauses)
        let oldRoomKey = try #require(roomA.keys[roomA.identity])
        let switched = try TestPeer(0, url: url, roomID: "room-3"); peers.append(switched)
        try await switched.start()
        try await waitUntil("authoritative switch removes old room and admits new room") {
            !roomA.session.maySend && roomB.session.maySend && switched.session.maySend
                && roomB.members.count == 2 && friendA.session.maySend && friendA.members.count == 1
        }
        let newRoomKey = try #require(switched.keys[switched.identity])
        #expect(newRoomKey != oldRoomKey && switched.keys == roomB.keys)
        let roomPacket = try AES.GCM.seal(Data("only new room".utf8), using: SymmetricKey(data: newRoomKey))
        #expect(throws: (any Error).self) { try AES.GCM.open(roomPacket, using: SymmetricKey(data: oldRoomKey)) }
        for peer in peers { await peer.session.stop() }
    } catch {
        let failures = peers.compactMap(\.failure)
        for peer in peers { await peer.session.stop() }
        Issue.record("Group integration failed: \(error); client failures: \(failures)")
        throw error
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupMutualContextNeedsNoOwnerInvitationAndStillRekeys() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let a = try TestPeer(0, url: url, roomID: "mutual-friends"), b = try TestPeer(1, url: url, roomID: "mutual-friends")
    try await a.start(); try await b.start()
    try await waitUntil("mutual context ready") { a.session.maySend && b.session.maySend && a.members.count == 2 && b.members.count == 2 }
    #expect(a.keys[a.identity] == b.keys[a.identity])
    #expect(a.keys[b.identity] == b.keys[b.identity])
    let old = a.keys[a.identity]
    try await a.session.refresh()
    try await waitUntil("mutual context ready") { a.session.maySend && b.session.maySend && a.keys[a.identity] != old }
    #expect(a.keys[a.identity] == b.keys[a.identity])
    await a.session.stop(); await b.session.stop()
}


@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupWaitsForHumanVerificationThenEstablishesFreshMutualKeys() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let identityA = try V5TestIdentity("group-peer-00"), identityB = try V5TestIdentity("group-peer-01")
    let a = try TestPeer(0, url: url, roomID: "mutual-verification", fixture: identityA)
    let b = try TestPeer(1, url: url, roomID: "mutual-verification", fixture: identityB)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [IdentityBusURLProtocol.self]
    IdentityBusURLProtocol.state.withLock { $0 = .init() }
    for (peer, fixture) in [(a, identityA), (b, identityB)] {
        try IdentityBusURLProtocol.register(fixture)
        IdentityBusURLProtocol.state.withLock { $0.accounts[peer.login.credential] = (peer.login.member.id, fixture.device) }
        let social = SocialIdentity(identity: peer.identityStore, persistence: MemoryIdentityPersistence(), configuration: configuration, authority: IdentityBusURLProtocol.authorityConfiguration)
        let room = RoomIdentity(identity: peer.identityStore, social: social, configuration: configuration)
        social.onChange = { [weak room] in room?.localTrustChanged() }
        social.reset(for: peer.login); peer.roomIdentity = room
        room.begin(login: peer.login, admission: peer.admission)
    }
    defer {
        for peer in [a, b] { peer.roomIdentity?.end(); peer.roomIdentity?.social.reset(for: nil) }
    }
    do {
        let roomA = try #require(a.roomIdentity), roomB = try #require(b.roomIdentity)
        try await waitUntil("fresh identity authorization") { roomA.social.voiceAllowed && roomB.social.voiceAllowed }
        try await a.start()
        try await waitUntil("solo media ready") { a.mediaActive && a.session.maySend }
        let oldKey = try #require(a.keys[a.identity])
        try await b.start()
        try await waitUntil("both peers await verification") { roomA.trust == .pending && roomB.trust == .pending && !a.mediaActive }
        // Exceed the server's 12-second transition limit with real heartbeats.
        try await Task.sleep(for: .seconds(14))
        #expect(a.failure == nil && b.failure == nil)
        #expect(roomA.trust == .pending && roomB.trust == .pending)
        #expect(!a.session.maySend && !b.session.maySend && !a.mediaActive && !b.mediaActive && b.keys.isEmpty)
        let peerB = try #require(roomA.remotePeer(for: b.identity))
        await roomA.startVerification(peerB)
        try await waitUntil("verification request delivered") { roomB.verification != nil }
        await roomB.acceptVerification()
        try await waitUntil("both show full SAS") { roomA.verification?.decimals.count == 3 && roomB.verification?.decimals.count == 3 }
        #expect(roomA.verification?.decimals == roomB.verification?.decimals)
        await roomA.confirmVerification(matches: true); await roomB.confirmVerification(matches: true)
        try await waitUntil("new mutual keys ready", timeout: 15) {
            a.session.maySend && b.session.maySend && a.mediaActive && b.mediaActive && a.members.count == 2 && b.members.count == 2
        }
        #expect(roomA.trust == .trusted && roomB.trust == .trusted && a.failure == nil && b.failure == nil)
        #expect(a.keys[a.identity] != oldKey && a.keys == b.keys)
        await a.session.stop(); await b.session.stop()
    } catch { await a.session.stop(); await b.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func groupWithoutLocalIdentityApprovalNeverInstallsContentKeys() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let peer = try TestPeer(0, url: url, roomID: "v5-unverified", approve: false)
    try await peer.start()
    try await Task.sleep(for: .seconds(2))
    #expect(peer.keys.isEmpty && !peer.mediaActive && !peer.session.maySend && peer.readyCount == 0)
    await peer.session.stop()
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_FORCE_REKEY"] == "1"))
@MainActor func groupForcesFreshSecretsBeforeLongServerRotationInterval() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let peer = try TestPeer(0, url: url, roomID: "v5-forced-rekey", smoothRotation: true)
    do {
        try await peer.start()
        try await waitUntil("initial local key") { peer.session.maySend }
        let original = peer.keys, began = ContinuousClock.now
        try await waitUntil("client demanded fresh secrets", timeout: 105) { peer.session.maySend && peer.keys != original }
        #expect(began.duration(to: .now) >= .seconds(85))
        #expect(peer.failure == nil && !peer.reinstalledRetiredKey)
        await peer.session.stop()
    } catch { await peer.session.stop(); throw error }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_CANDIDATE"] == "1"))
@MainActor func groupCandidateTimeoutRetiresMediaBeforeBlockedPreparationReturns() async throws {
    let url = try #require(ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"].flatMap(URL.init(string:)))
    let gate = StartupGate()
    let peer = try TestPeer(0, url: url, roomID: "v5-candidate-timeout", smoothRotation: true, rotationGate: gate)
    do {
        try await peer.start()
        try await waitUntil("candidate preparation entered", timeout: 25) { gate.entered }
        try await waitUntil("candidate deadline closed media", timeout: 18) { !peer.session.maySend && !peer.mediaActive }
        gate.release()
        try await waitUntil("candidate failure surfaced") { peer.failure != nil }
        #expect(!peer.reinstalledRetiredKey)
        await peer.session.stop()
    } catch { gate.release(); await peer.session.stop(); throw error }
}
