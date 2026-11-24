import CryptoKit
import Foundation

public enum V5IdentityError: Error, LocalizedError {
    case invalid, untrusted, changed, expired, notEnrolled, wrongDevice
    public var errorDescription: String? {
        switch self {
        case .invalid: "身份签名或授权证明无效"
        case .untrusted: "请先通过可信渠道核验联系人和房间邀请"
        case .changed: "已验证的身份或房间授权发生冲突，通话已暂停"
        case .expired: "身份或房间授权已到期，请由授权者更新"
        case .notEnrolled: "请先创建首次身份或由可信旧设备授权本设备"
        case .wrongDevice: "此授权不属于当前设备"
        }
    }
}

public enum V5Crypto {
    public static let protocolName = "chirp-mls-authenticated-v5"
    public static let maxChain = 8
    public static let deviceLifetime: Int64 = 5 * 365 * 24 * 3600
    public static let policyLifetime: Int64 = 24 * 3600
    public static let entryLifetime: Int64 = 20 * 3600

    public static func record(_ domain: String, _ fields: [Data]) -> Data {
        var result = Data()
        for field in [Data(domain.utf8)] + fields {
            var size = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &size) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
    public static func message(_ domain: String, _ fields: [String]) -> Data { record(domain, fields.map { Data($0.utf8) }) }
    public static func hash(_ data: Data) -> String { Data(SHA256.hash(data: data)).base64EncodedString() }
    public static func bytes(_ value: String, count: Int) throws -> Data {
        guard let result = Data(base64Encoded: value), result.count == count, result.base64EncodedString() == value else { throw V5IdentityError.invalid }
        return result
    }
    public static func verify(key: String, signature: String, message: Data) throws {
        let key = try Curve25519.Signing.PublicKey(rawRepresentation: bytes(key, count: 32))
        guard try key.isValidSignature(bytes(signature, count: 64), for: message) else { throw V5IdentityError.invalid }
    }
    public static func sign(_ key: Data, _ message: Data) throws -> String {
        try Curve25519.Signing.PrivateKey(rawRepresentation: key).signature(for: message).base64EncodedString()
    }
    public static func random(_ count: Int = 32) -> Data {
        // SystemRandomNumberGenerator uses the operating system CSPRNG.
        var generator = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
    public static func checkTime(_ start: Int64, _ end: Int64, limit: Int64, now: Int64) throws {
        guard start > 0, end > start, end - start <= limit, start <= now + 60 else { throw V5IdentityError.invalid }
        guard end > now else { throw V5IdentityError.expired }
    }
    public static func rosterHash(_ bindings: [V5EntryBinding]) -> String {
        hash(message("Chirp roster digest v5", [String(bindings.count)] + bindings.map(\.digest).sorted()))
    }
    public static func fingerprint(_ key: String) throws -> String {
        SHA256.hash(data: try bytes(key, count: 32)).map { String(format: "%02x", $0) }.joined()
    }
    public static func validateRoster(_ peers: [MLSPeer], policy: V5RoomPolicy, groupID: String, epoch: UInt64, confirmation: String? = nil) throws -> Int64 {
        try policy.validate()
        let bindings = try peers.map { peer -> V5EntryBinding in
            guard let binding = peer.binding, binding.identity == peer.identity, binding.mlsKey == peer.publicKey else { throw V5IdentityError.invalid }
            try binding.validate(policy: policy)
            return binding
        }
        guard !peers.isEmpty, Set(peers.map(\.identity)).count == peers.count, Set(bindings.map { $0.device.leafKey }).count == peers.count else { throw V5IdentityError.invalid }
        let roster = rosterHash(bindings)
        for peer in peers {
            if !peer.keyPackage.isEmpty {
                guard let offer = peer.offer, let package = Data(base64Encoded: peer.keyPackage),
                      offer.groupID == groupID, offer.keyEpoch == epoch, offer.policyHash == policy.digest,
                      offer.rosterHash == roster, offer.keyPackageHash == hash(package) else { throw V5IdentityError.invalid }
                try verify(key: peer.publicKey, signature: offer.signature, message: offer.message)
            }
            if let confirmation {
                guard let ready = peer.ready, ready.groupID == groupID, ready.keyEpoch == epoch,
                      ready.policyHash == policy.digest, ready.rosterHash == roster, ready.confirmation == confirmation else { throw V5IdentityError.invalid }
                try verify(key: peer.publicKey, signature: ready.signature, message: ready.message)
            }
        }
        return min(policy.notAfter, policy.isMutual ? Int64.max : policy.signer.notAfter, bindings.map { min($0.notAfter, $0.device.notAfter) }.min() ?? 0)
    }
}

public struct V5Certificate: Codable, Equatable, Sendable {
    public var accountKey: String
    public var deviceKey: String
    public var issuerKey: String
    public var parentHash: String
    public var serial: String
    public var canEnroll: Bool
    public var notBefore: Int64
    public var notAfter: Int64
    public var signature: String
    public init(accountKey: String, deviceKey: String, issuerKey: String, parentHash: String, serial: String, canEnroll: Bool, notBefore: Int64, notAfter: Int64, signature: String = "") {
        self.accountKey = accountKey; self.deviceKey = deviceKey; self.issuerKey = issuerKey; self.parentHash = parentHash
        self.serial = serial; self.canEnroll = canEnroll; self.notBefore = notBefore; self.notAfter = notAfter; self.signature = signature
    }
    public var message: Data { V5Crypto.message("Chirp device certificate v5", [accountKey, deviceKey, issuerKey, parentHash, serial, canEnroll ? "1" : "0", String(notBefore), String(notAfter)]) }
    public var digest: String { V5Crypto.hash(V5Crypto.record("Chirp device certificate digest v5", [message, Data(signature.utf8)])) }
    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key", deviceKey = "device_key", issuerKey = "issuer_key", parentHash = "parent_hash", serial, canEnroll = "can_enroll", notBefore = "not_before", notAfter = "not_after", signature
    }
}

public struct V5Device: Codable, Equatable, Sendable {
    public var accountKey: String
    public var certificates: [V5Certificate]
    public init(accountKey: String, certificates: [V5Certificate]) { self.accountKey = accountKey; self.certificates = certificates }
    public var leafKey: String { certificates.last?.deviceKey ?? "" }
    public var digest: String { V5Crypto.hash(V5Crypto.message("Chirp device identity digest v5", [accountKey, String(certificates.count)] + certificates.map(\.digest))) }
    public var notAfter: Int64 { certificates.map(\.notAfter).min() ?? 0 }
    public func validate(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        _ = try V5Crypto.bytes(accountKey, count: 32)
        guard !certificates.isEmpty, certificates.count <= V5Crypto.maxChain else { throw V5IdentityError.invalid }
        var issuer = accountKey, parent = "", deadline = Int64.max, seen: Set<String> = [accountKey]
        for (index, certificate) in certificates.enumerated() {
            _ = try V5Crypto.bytes(certificate.deviceKey, count: 32); _ = try V5Crypto.bytes(certificate.serial, count: 16)
            guard certificate.accountKey == accountKey, certificate.issuerKey == issuer, certificate.parentHash == parent,
                  !seen.contains(certificate.deviceKey), certificate.notAfter <= deadline,
                  index == certificates.count - 1 || certificate.canEnroll else { throw V5IdentityError.invalid }
            try V5Crypto.checkTime(certificate.notBefore, certificate.notAfter, limit: V5Crypto.deviceLifetime, now: now)
            try V5Crypto.verify(key: issuer, signature: certificate.signature, message: certificate.message)
            seen.insert(certificate.deviceKey); issuer = certificate.deviceKey; parent = certificate.digest; deadline = certificate.notAfter
        }
    }
    enum CodingKeys: String, CodingKey { case accountKey = "account_key", certificates }
}

public struct V5LoginProof: Codable, Sendable {
    public let device: V5Device
    public let nonce: String
    public var signature: String
    public init(device: V5Device, nonce: String, signature: String = "") { self.device = device; self.nonce = nonce; self.signature = signature }
    public func message(client: String, authorization: String, verifier: String) -> Data {
        V5Crypto.message("Chirp login activation v5", [client, V5Crypto.hash(Data(authorization.utf8)), V5Crypto.hash(Data(verifier.utf8)), device.digest, nonce])
    }
}

public struct V5RoomPolicy: Codable, Equatable, Sendable {
    public var origin: String
    public var roomID: String
    public var trustID: String
    public var ownerKey: String
    public var version: Int64
    public var previousHash: String
    public var members: [String]
    public var revokedDevices: [String]
    public var notBefore: Int64
    public var notAfter: Int64
    public var signer: V5Device
    public var signature: String
    public init(origin: String, roomID: String, trustID: String, ownerKey: String, version: Int64, previousHash: String, members: [String], revokedDevices: [String], notBefore: Int64, notAfter: Int64, signer: V5Device, signature: String = "") {
        self.origin = origin; self.roomID = roomID; self.trustID = trustID; self.ownerKey = ownerKey; self.version = version; self.previousHash = previousHash
        self.members = members; self.revokedDevices = revokedDevices; self.notBefore = notBefore; self.notAfter = notAfter; self.signer = signer; self.signature = signature
    }
    public var isMutual: Bool { ownerKey.isEmpty }
    public static func mutual(origin: String, roomID: String) -> Self {
        Self(origin: origin, roomID: roomID, trustID: V5Crypto.hash(V5Crypto.message("Chirp mutual room v5", [origin, roomID])), ownerKey: "", version: 1, previousHash: "", members: [], revokedDevices: [], notBefore: 1, notAfter: 253402300799, signer: V5Device(accountKey: "", certificates: []))
    }
    public var message: Data {
        V5Crypto.message("Chirp room policy v5", [origin, roomID, trustID, ownerKey, String(version), previousHash, String(members.count)] + members + [String(revokedDevices.count)] + revokedDevices + [String(notBefore), String(notAfter), signer.digest])
    }
    public var digest: String { V5Crypto.hash(V5Crypto.record("Chirp room policy digest v5", [message, Data(signature.utf8)])) }
    public func allows(_ device: V5Device, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        try device.validate(now: now)
        if isMutual { try validate(now: now); return }
        guard members.contains(device.accountKey) else { throw V5IdentityError.untrusted }
        guard try !revokedDevices.contains(V5Crypto.hash(V5Crypto.bytes(device.leafKey, count: 32))) else { throw V5IdentityError.untrusted }
    }
    public func validate(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        if isMutual {
            guard !origin.isEmpty, !roomID.isEmpty, self == Self.mutual(origin: origin, roomID: roomID) else { throw V5IdentityError.invalid }; return
        }
        guard !origin.isEmpty, origin.utf8.count <= 2048, !roomID.isEmpty, roomID.utf8.count <= 64, version > 0,
              !members.isEmpty, members.count <= 1024, revokedDevices.count <= 1024,
              members == members.sorted(), Set(members).count == members.count,
              revokedDevices == revokedDevices.sorted(), Set(revokedDevices).count == revokedDevices.count,
              members.contains(ownerKey), signer.accountKey == ownerKey else { throw V5IdentityError.invalid }
        _ = try V5Crypto.bytes(trustID, count: 32)
        if version == 1 { guard previousHash.isEmpty else { throw V5IdentityError.invalid } }
        else { _ = try V5Crypto.bytes(previousHash, count: 32) }
        for root in members { _ = try V5Crypto.bytes(root, count: 32) }
        for id in revokedDevices { _ = try V5Crypto.bytes(id, count: 32) }
        try V5Crypto.checkTime(notBefore, notAfter, limit: V5Crypto.policyLifetime, now: now)
        try allows(signer, now: now)
        try V5Crypto.verify(key: signer.leafKey, signature: signature, message: message)
    }
    enum CodingKeys: String, CodingKey {
        case origin, roomID = "room_id", trustID = "trust_id", ownerKey = "owner_key", version, previousHash = "previous_hash", members,
             revokedDevices = "revoked_devices", notBefore = "not_before", notAfter = "not_after", signer, signature
    }
}

public struct V5EntryBinding: Codable, Equatable, Sendable {
    public var device: V5Device
    public var origin: String
    public var roomID: String
    public var trustID: String
    public var policyHash: String
    public var identity: String
    public var mlsKey: String
    public var nonce: String
    public var notBefore: Int64
    public var notAfter: Int64
    public var signature: String
    public init(device: V5Device, origin: String, roomID: String, trustID: String, policyHash: String, identity: String, mlsKey: String, nonce: String, notBefore: Int64, notAfter: Int64, signature: String = "") {
        self.device = device; self.origin = origin; self.roomID = roomID; self.trustID = trustID; self.policyHash = policyHash
        self.identity = identity; self.mlsKey = mlsKey; self.nonce = nonce; self.notBefore = notBefore; self.notAfter = notAfter; self.signature = signature
    }
    public var message: Data { V5Crypto.message("Chirp admission binding v5", [device.digest, origin, roomID, trustID, policyHash, identity, mlsKey, nonce, String(notBefore), String(notAfter)]) }
    public var digest: String { V5Crypto.hash(V5Crypto.record("Chirp admission binding digest v5", [message, Data(signature.utf8)])) }
    public func validate(policy: V5RoomPolicy, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        _ = try V5Crypto.bytes(mlsKey, count: 32); _ = try V5Crypto.bytes(nonce, count: 32)
        guard origin == policy.origin, roomID == policy.roomID, trustID == policy.trustID, policyHash == policy.digest,
              !identity.isEmpty, identity.utf8.count <= 192, !identity.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" }) else { throw V5IdentityError.invalid }
        try policy.allows(device, now: now)
        try V5Crypto.checkTime(notBefore, notAfter, limit: V5Crypto.entryLifetime, now: now)
        try V5Crypto.verify(key: device.leafKey, signature: signature, message: message)
    }
    enum CodingKeys: String, CodingKey {
        case device, origin, roomID = "room_id", trustID = "trust_id", policyHash = "policy_hash", identity,
             mlsKey = "mls_key", nonce, notBefore = "not_before", notAfter = "not_after", signature
    }
}

public struct V5RoundProof: Codable, Equatable, Sendable {
    public var groupID: String
    public var keyEpoch: UInt64
    public var policyHash: String
    public var rosterHash: String
    public var keyPackageHash: String
    public var signature: String
    public init(groupID: String, keyEpoch: UInt64, policyHash: String, rosterHash: String, keyPackageHash: String, signature: String = "") {
        self.groupID = groupID; self.keyEpoch = keyEpoch; self.policyHash = policyHash; self.rosterHash = rosterHash; self.keyPackageHash = keyPackageHash; self.signature = signature
    }
    public var message: Data { V5Crypto.message("Chirp round offer v5", [groupID, String(keyEpoch), policyHash, rosterHash, keyPackageHash]) }
    enum CodingKeys: String, CodingKey { case groupID = "group_id", keyEpoch = "key_epoch", policyHash = "policy_hash", rosterHash = "roster_hash", keyPackageHash = "key_package_hash", signature }
}

public struct V5ReadyProof: Codable, Equatable, Sendable {
    public var groupID: String
    public var keyEpoch: UInt64
    public var policyHash: String
    public var rosterHash: String
    public var confirmation: String
    public var signature: String
    public init(groupID: String, keyEpoch: UInt64, policyHash: String, rosterHash: String, confirmation: String, signature: String = "") {
        self.groupID = groupID; self.keyEpoch = keyEpoch; self.policyHash = policyHash; self.rosterHash = rosterHash; self.confirmation = confirmation; self.signature = signature
    }
    public var message: Data { V5Crypto.message("Chirp epoch ready v5", [groupID, String(keyEpoch), policyHash, rosterHash, confirmation]) }
    enum CodingKeys: String, CodingKey { case groupID = "group_id", keyEpoch = "key_epoch", policyHash = "policy_hash", rosterHash = "roster_hash", confirmation, signature }
}
