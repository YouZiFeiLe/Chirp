import ChirpMLS
import CryptoKit
import Foundation

// Public deterministic test keys. This file is shared by the three test targets,
// never by either application target.
struct V5TestIdentity: Sendable {
    let key: Data
    let device: V5Device
    init(_ label: String) throws {
        let seed = { (suffix: String) in Data(SHA256.hash(data: Data("chirp-v5-test-only:\(label):\(suffix)".utf8))) }
        let root = try Curve25519.Signing.PrivateKey(rawRepresentation: seed("root"))
        let privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: seed("device"))
        key = privateKey.rawRepresentation
        let account = root.publicKey.rawRepresentation.base64EncodedString()
        let now = Int64(Date().timeIntervalSince1970)
        var certificate = V5Certificate(accountKey: account, deviceKey: privateKey.publicKey.rawRepresentation.base64EncodedString(), issuerKey: account, parentHash: "", serial: Data(repeating: 0, count: 16).base64EncodedString(), canEnroll: true, notBefore: now - 1, notAfter: now + V5Crypto.deviceLifetime - 1)
        certificate.signature = try V5Crypto.sign(root.rawRepresentation, certificate.message)
        device = V5Device(accountKey: account, certificates: [certificate])
    }
    func policy(origin: String, roomID: String, others: [V5TestIdentity] = []) throws -> V5RoomPolicy {
        let now = Int64(Date().timeIntervalSince1970)
        var policy = V5RoomPolicy(origin: origin, roomID: roomID, trustID: V5Crypto.hash(Data("\(origin)/\(roomID)".utf8)), ownerKey: device.accountKey, version: 1, previousHash: "", members: Array(Set([device.accountKey] + others.map { $0.device.accountKey })).sorted(), revokedDevices: [], notBefore: now - 1, notAfter: now + V5Crypto.policyLifetime - 1, signer: device)
        policy.signature = try V5Crypto.sign(key, policy.message)
        return policy
    }
    func binding(policy: V5RoomPolicy, identity: String, mlsKey: String) throws -> V5EntryBinding {
        let now = Int64(Date().timeIntervalSince1970)
        var binding = V5EntryBinding(device: device, origin: policy.origin, roomID: policy.roomID, trustID: policy.trustID, policyHash: policy.digest, identity: identity, mlsKey: mlsKey, nonce: V5Crypto.hash(Data("nonce:\(identity)".utf8)), notBefore: now - 1, notAfter: now + V5Crypto.entryLifetime - 1)
        binding.signature = try V5Crypto.sign(key, binding.message)
        return binding
    }
    static func peers(_ clients: [MLSClient], groupID: String, staged: Bool = false, policy existing: V5RoomPolicy? = nil) async throws -> [MLSPeer] {
        let identities = try clients.map { try V5TestIdentity($0.identity) }
        let policy = try existing ?? identities[0].policy(origin: "https://fixture.test", roomID: "friends", others: identities)
        var result: [MLSPeer] = []
        for (client, identity) in zip(clients, identities) {
            if !staged { try await client.authorize(policy: policy, trustedOwner: policy.ownerKey, origin: policy.origin, roomID: policy.roomID) }
            let key = try await client.publicKey()
            let package = try await (staged ? client.stagedKeyPackage() : client.keyPackage())
            result.append(MLSPeer(identity: client.identity, name: client.identity, publicKey: key, keyPackage: package,
                                  binding: try identity.binding(policy: policy, identity: client.identity, mlsKey: key)))
        }
        let roster = V5Crypto.rosterHash(result.compactMap(\.binding))
        for index in result.indices {
            var offer = V5RoundProof(groupID: groupID, keyEpoch: staged ? 1 : 0, policyHash: policy.digest, rosterHash: roster, keyPackageHash: V5Crypto.hash(Data(base64Encoded: result[index].keyPackage)!))
            offer.signature = try await clients[index].sign(offer.message)
            result[index].offer = offer
        }
        for client in clients { try await client.approve(groupID: groupID, members: result, authorizationHash: V5Crypto.hash(Data("verified test roster".utf8))) }
        return result
    }
}
