import ChirpMLS
import Foundation
import Testing

@Test func v5CanonicalMessagesAndSignaturesMatchGoAndRust() throws {
    struct Vector: Decodable {
        let now: Int64
        let device: V5Device
        let policy: V5RoomPolicy
        let binding: V5EntryBinding
        let offer: V5RoundProof
        let ready: V5ReadyProof
        let login: V5LoginProof
        let messages: [String: String]
        let hashes: [String: String]
    }
    let url = try #require(Bundle.module.url(forResource: "v5", withExtension: "json", subdirectory: "Fixtures"))
    let v = try JSONDecoder().decode(Vector.self, from: Data(contentsOf: url))
    try v.device.validate(now: v.now); try v.policy.validate(now: v.now); try v.binding.validate(policy: v.policy, now: v.now)
    let messages = ["certificate": v.device.certificates[0].message, "policy": v.policy.message, "binding": v.binding.message,
                    "offer": v.offer.message, "ready": v.ready.message, "login": v.login.message(client: "chirp-apple", authorization: "authorization-vector", verifier: "pkce-verifier-vector")]
    for (name, data) in messages { #expect(data.base64EncodedString() == v.messages[name]) }
    let hashes = ["certificate": v.device.certificates[0].digest, "device": v.device.digest, "policy": v.policy.digest,
                  "binding": v.binding.digest, "roster": V5Crypto.rosterHash([v.binding])]
    #expect(hashes == v.hashes)
    try V5Crypto.verify(key: v.device.leafKey, signature: v.login.signature, message: messages["login"]!)
    try V5Crypto.verify(key: v.binding.mlsKey, signature: v.offer.signature, message: v.offer.message)
    try V5Crypto.verify(key: v.binding.mlsKey, signature: v.ready.signature, message: v.ready.message)
}

@Test func forgedAllReadyAndSplitRosterCannotAuthorizeSending() async throws {
    let a = try MLSClient(identity: "a.login.entry"), b = try MLSClient(identity: "b.login.entry")
    let owner = try V5TestIdentity(a.identity), other = try V5TestIdentity(b.identity)
    let policy = try owner.policy(origin: "https://fixture.test", roomID: "friends", others: [other])
    var peers = try await V5TestIdentity.peers([a, b], groupID: "ready/1", policy: policy)
    let confirmation = V5Crypto.hash(Data("epoch authenticator".utf8))
    let roster = V5Crypto.rosterHash(peers.compactMap(\.binding))
    for (index, client) in [a, b].enumerated() {
        var ready = V5ReadyProof(groupID: "ready/1", keyEpoch: 0, policyHash: policy.digest, rosterHash: roster, confirmation: confirmation)
        ready.signature = try await client.sign(ready.message); peers[index].ready = ready
    }
    _ = try V5Crypto.validateRoster(peers, policy: policy, groupID: "ready/1", epoch: 0, confirmation: confirmation)
    var forged = peers; forged[1].ready = nil
    #expect(throws: (any Error).self) { try V5Crypto.validateRoster(forged, policy: policy, groupID: "ready/1", epoch: 0, confirmation: confirmation) }
    #expect(throws: (any Error).self) { try V5Crypto.validateRoster([peers[0]], policy: policy, groupID: "ready/1", epoch: 0, confirmation: confirmation) }
    forged = peers; forged[1].ready = peers[0].ready
    #expect(throws: (any Error).self) { try V5Crypto.validateRoster(forged, policy: policy, groupID: "ready/1", epoch: 0, confirmation: confirmation) }
    #expect(throws: (any Error).self) { try V5Crypto.validateRoster(peers, policy: policy, groupID: "ready/1", epoch: 1, confirmation: confirmation) }
}
