import ChirpMLS
import CryptoKit
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@MainActor func testIdentityStore(_ label: String, fixture: V5TestIdentity? = nil) throws -> DeviceIdentityStore {
    let fixture = try fixture ?? V5TestIdentity(label)
    let persistence = MemoryIdentityPersistence()
    let value: [String: Any] = ["version": 5, "privateKey": fixture.key.base64EncodedString(),
        "device": try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.device)),
        "trust": ["contacts": [["accountKey": fixture.device.accountKey, "name": label]], "rooms": []]]
    persistence.data = try JSONSerialization.data(withJSONObject: ["activeScope": "", "identities": ["": value]])
    return DeviceIdentityStore(persistence: persistence)
}

@MainActor func trustFixtureRoom(_ store: DeviceIdentityStore, url: URL, roomID: String) async throws {
    let (data, response) = try await URLSession.shared.data(from: url.appendingPathComponent("test/v5-policy/\(roomID)"))
    guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw V5IdentityError.invalid }
    let policy = try JSONDecoder().decode(V5RoomPolicy.self, from: data)
    // The expected owner is compiled into the loopback fixture, not learned
    // from the untrusted HTTP policy being verified.
    let owner = try V5TestIdentity("group-peer-00")
    _ = try store.trustRoom(store.roomCode(policy), expectedFingerprint: V5Crypto.fingerprint(owner.device.accountKey))
}

@MainActor private final class FailingIdentityPersistence: IdentityPersistence {
    var data: Data?
    var rejectSave = false
    func load() throws -> Data? { data }
    func save(_ data: Data) throws {
        if rejectSave { throw CocoaError(.fileWriteUnknown) }
        self.data = data
    }
}

@Test @MainActor func enrollmentCandidatesStayScopedAndCommitAtomically() throws {
    let disk = FailingIdentityPersistence(), identity = DeviceIdentityStore(persistence: disk)
    let origin = "https://candidate.test:443", account = "member_candidate"
    try identity.select(origin: origin, accountID: account)
    let seed = Curve25519.Signing.PrivateKey().rawRepresentation
    let original = try identity.makeCandidate(rootSeed: seed); try identity.markBound()
    let candidate = try identity.enrollmentCandidate()
    let replacement = try candidate.makeCandidate(rootSeed: seed)
    disk.rejectSave = true
    #expect(throws: (any Error).self) { try identity.saveEnrollmentCandidate(candidate) }
    #expect(identity.device == original && identity.isBound)
    disk.rejectSave = false; try identity.saveEnrollmentCandidate(candidate)
    disk.rejectSave = true
    #expect(throws: (any Error).self) { try identity.activateEnrollmentCandidate(candidate) }
    #expect(identity.device == original && identity.isBound)
    let restored = DeviceIdentityStore(persistence: disk)
    try restored.select(origin: origin, accountID: account)
    #expect(restored.device == original && restored.isBound)
    #expect(try restored.enrollmentCandidate().device == replacement)
    disk.rejectSave = false
    try restored.select(origin: origin, accountID: "member_other")
    #expect(try restored.enrollmentCandidate().device == nil)
    #expect(throws: (any Error).self) { try restored.activateEnrollmentCandidate(candidate) }
    try restored.select(origin: origin, accountID: account)
    try restored.activateEnrollmentCandidate(candidate)
    #expect(restored.device == replacement && restored.isBound)
    #expect(try restored.enrollmentCandidate().device == nil)
    #expect(DeviceIdentityStore(persistence: disk).device == replacement)
}

@Test @MainActor func offlineEnrollmentSurvivesSessionTeardownAndNeverPersistsRecoverySecret() throws {
    let disk = MemoryIdentityPersistence(), newDisk = MemoryIdentityPersistence()
    let old = DeviceIdentityStore(persistence: disk)
    let rootSeed = Curve25519.Signing.PrivateKey().rawRepresentation
    _ = try old.makeCandidate(rootSeed: rootSeed)
    let rootSecret = rootSeed.base64EncodedString()
    #expect(!String(decoding: try #require(disk.data), as: UTF8.self).contains(rootSecret))
    // Reconstructing from Keychain-equivalent storage has no business session.
    let offlineOld = DeviceIdentityStore(persistence: disk)
    #expect(!String(decoding: try #require(disk.data), as: UTF8.self).contains(rootSecret))
    let new = DeviceIdentityStore(persistence: newDisk)
    let request = try new.enrollmentRequest()
    let approval = try offlineOld.approveDevice(request, expectedDeviceFingerprint: new.deviceFingerprint, canEnroll: true)
    #expect(throws: (any Error).self) { try new.acceptDeviceApproval(approval, expectedFingerprint: String(repeating: "0", count: 64)) }
    try new.acceptDeviceApproval(approval, expectedFingerprint: offlineOld.fingerprint)
    #expect(new.device?.accountKey == old.device?.accountKey && new.device?.leafKey != old.device?.leafKey)
    #expect(new.canEnroll && new.contacts.count == old.contacts.count)
    #expect(throws: (any Error).self) { try new.acceptDeviceApproval(approval, expectedFingerprint: old.fingerprint) }
    let third = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    let thirdRequest = try third.enrollmentRequest()
    let thirdApproval = try new.approveDevice(thirdRequest, expectedDeviceFingerprint: third.deviceFingerprint, canEnroll: false)
    try third.acceptDeviceApproval(thirdApproval, expectedFingerprint: old.fingerprint)
    #expect(!third.canEnroll)
    let fourth = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    #expect(throws: (any Error).self) { try third.approveDevice(fourth.enrollmentRequest(), expectedDeviceFingerprint: fourth.deviceFingerprint, canEnroll: true) }
    let recovered = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    _ = try recovered.makeCandidate(rootSeed: rootSeed)
    #expect(recovered.device?.accountKey == old.device?.accountKey)
    #expect(recovered.device?.leafKey != old.device?.leafKey)
}

@Test @MainActor func enrollmentIsBoundToTheRequestedDeviceAndLatestNonce() throws {
    let old = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    _ = try old.makeCandidate(rootSeed: Curve25519.Signing.PrivateKey().rawRepresentation)
    let new = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    let wrong = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
    let first = try new.enrollmentRequest()
    #expect(throws: (any Error).self) { try old.approveDevice(first, expectedDeviceFingerprint: old.deviceFingerprint, canEnroll: false) }
    let approval = try old.approveDevice(first, expectedDeviceFingerprint: new.deviceFingerprint, canEnroll: false)
    _ = try wrong.enrollmentRequest()
    #expect(throws: (any Error).self) { try wrong.acceptDeviceApproval(approval, expectedFingerprint: old.fingerprint) }
    _ = try new.enrollmentRequest()
    #expect(throws: (any Error).self) { try new.acceptDeviceApproval(approval, expectedFingerprint: old.fingerprint) }
    #expect(!new.isEnrolled && !wrong.isEnrolled)
}

@Test @MainActor func corruptedIdentityStorageDoesNotSilentlyGenerateANewIdentity() throws {
    let disk = MemoryIdentityPersistence(); disk.data = Data("corrupt identity storage".utf8)
    let identity = DeviceIdentityStore(persistence: disk)
    #expect(!identity.isEnrolled && identity.failure != nil)
    #expect(throws: (any Error).self) { try identity.select(origin: "https://fixture.test:443", accountID: "member_fixture") }
    #expect(disk.data == Data("corrupt identity storage".utf8))
}

@Test @MainActor func verifiedRoomTrustRejectsServerReplacementRollbackAndSkippedRevocation() throws {
    let owner = try testIdentityStore("owner")
    let recipient = try testIdentityStore("recipient")
    let first = try owner.createRoom(origin: "https://fixture.test", roomID: "friends")
    _ = try recipient.trustRoom(owner.roomCode(first), expectedFingerprint: owner.fingerprint)
    var replaced = try V5TestIdentity("server-impostor").policy(origin: first.origin, roomID: first.roomID)
    #expect(throws: (any Error).self) { try recipient.acceptRoomPolicy(replaced, origin: first.origin, roomID: first.roomID) }
    let second = try owner.updateRoom(first, members: first.members, revokedDevices: [])
    let third = try owner.updateRoom(second, members: first.members, revokedDevices: [])
    #expect(throws: (any Error).self) { try recipient.acceptRoomPolicy(third, origin: first.origin, roomID: first.roomID) }
    try recipient.acceptRoomPolicy(second, origin: first.origin, roomID: first.roomID)
    #expect(throws: (any Error).self) { try recipient.acceptRoomPolicy(first, origin: first.origin, roomID: first.roomID) }
    replaced = second; replaced.signature = first.signature
    #expect(throws: (any Error).self) { try recipient.acceptRoomPolicy(replaced, origin: first.origin, roomID: first.roomID) }
    try recipient.acceptRoomPolicy(third, origin: first.origin, roomID: first.roomID)
}
