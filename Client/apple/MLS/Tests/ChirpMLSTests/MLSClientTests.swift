import Foundation
import Testing
import ChirpMLS

@Test func nativeIdentityCannotBeTruncatedAtANulByte() throws {
    for identity in ["", "member.login\0different", String(repeating: "a", count: 193), "成员.login"] {
        #expect(throws: (any Error).self) { try MLSClient(identity: identity) }
    }
}

@Test func senderKeyLookupRequiresTheCompleteIdentity() async throws {
    let client = try MLSClient(identity: "member.login")
    let peer = try await V5TestIdentity.peers([client], groupID: "test/lookup")[0]
    _ = try await client.create(groupID: "test/lookup", members: [peer])
    #expect(try await client.senderKey(for: client.identity).count == 32)
    await #expect(throws: (any Error).self) { try await client.senderKey(for: client.identity + "\0different") }
    try await client.clear()
}

@Test func nativeBridgeKeepsKeysLocalAndRejectsInvalidAdmission() async throws {
    let a = try MLSClient(identity: "a.login_a")
    let b = try MLSClient(identity: "b.login_b")
    let peers = try await V5TestIdentity.peers([a, b], groupID: "test-session/1")
    let result = try await a.create(groupID: "test-session/1", members: peers)
    let confirmation = try await b.join(groupID: "test-session/1", members: peers, welcome: result.welcome)
    #expect(confirmation == result.confirmation)
    let aKey = try await a.senderKey(for: a.identity)
    let bReceivesA = try await b.senderKey(for: a.identity)
    #expect(aKey == bReceivesA)
    let bKey = try await b.senderKey(for: b.identity)
    #expect(aKey != bKey)
    try await a.clear()
    await #expect(throws: (any Error).self) { try await a.senderKey(for: a.identity) }
    _ = try await b.keyPackage()
    await #expect(throws: (any Error).self) { try await b.join(groupID: "wrong-session/2", members: peers, welcome: result.welcome) }
}
