import ChirpMLS
import CryptoKit
import Foundation
import Observation
import Security

@MainActor
protocol IdentityPersistence {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func clear() throws
}

extension IdentityPersistence { func clear() throws { try save(Data()) } }

@MainActor
final class MemoryIdentityPersistence: IdentityPersistence {
    var data: Data?
    func load() throws -> Data? { data }
    func save(_ data: Data) throws { self.data = data }
    func clear() throws { data = nil }
}

@MainActor
final class KeychainIdentityPersistence: IdentityPersistence {
    private let service: String
    init(service: String = "cn.youzifeile.chirp.identity.v5") { self.service = service }
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "device-and-trust", kSecAttrSynchronizable as String: false,
         kSecUseDataProtectionKeychain as String: true]
    }
    func load() throws -> Data? {
        var request = query; request[kSecReturnData as String] = true; request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw V5IdentityError.invalid }
        return data
    }
    func clear() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw V5IdentityError.invalid }
    }
    func save(_ data: Data) throws {
        let updates: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, updates as CFDictionary)
        if status == errSecItemNotFound {
            var request = query; updates.forEach { request[$0.key] = $0.value }
            guard SecItemAdd(request as CFDictionary, nil) == errSecSuccess else { throw V5IdentityError.invalid }
        } else if status != errSecSuccess { throw V5IdentityError.invalid }
    }
}

struct DeviceEnrollmentRequest: Codable, Sendable {
    let version: Int
    let deviceKey: String
    let nonce: String
    let expiresAt: Int64
    var signature: String
    var message: Data { V5Crypto.message("Chirp device enrollment request v5", [String(version), deviceKey, nonce, String(expiresAt)]) }
    func validate() throws {
        guard version == 5, expiresAt > Int64(Date().timeIntervalSince1970), expiresAt <= Int64(Date().timeIntervalSince1970) + 660 else { throw V5IdentityError.expired }
        _ = try V5Crypto.bytes(nonce, count: 32)
        try V5Crypto.verify(key: deviceKey, signature: signature, message: message)
    }
}

private struct DeviceEnrollmentResponse: Codable {
    let version: Int
    let requestNonce: String
    let device: V5Device
    let issuer: V5Device
    let trustData: Data
    var signature: String
    var message: Data { V5Crypto.message("Chirp device enrollment response v5", [String(version), requestNonce, device.digest, issuer.digest, V5Crypto.hash(trustData)]) }
}

struct TrustedContact: Codable, Sendable {
    let accountKey: String
    var name: String
}

struct TrustedRoom: Codable, Sendable {
    var policy: V5RoomPolicy
}

private struct DeviceTrustData: Codable {
    var contacts: [TrustedContact] = []
    var rooms: [TrustedRoom] = []
}

private struct StoredIdentity: Codable {
    var version = 5
    var privateKey: Data
    var bound: Bool?
    var device: V5Device?
    var enrollmentNonce: String?
    var enrollmentExpiresAt: Int64?
    var trust = DeviceTrustData()
}

private struct IdentityVault: Codable {
    var activeScope = ""
    var identities: [String: StoredIdentity] = [:]
    var enrollmentCandidates: [String: StoredIdentity]?
}

// This application-lifetime owner intentionally survives logout and SSO kicks.
// Only temporary MLS material belongs to LoginSession/GroupSession teardown.
@MainActor @Observable
final class DeviceIdentityStore {
    private let persistence: any IdentityPersistence
    private var state: StoredIdentity?
    private var vault = IdentityVault()
    private(set) var currentScope = ""
    private(set) var failure: ClientFailure?
    private(set) var revision: UInt64 = 0

    init(persistence: any IdentityPersistence) {
        self.persistence = persistence
        do {
            if let data = try persistence.load() {
                let loaded = try JSONDecoder().decode(IdentityVault.self, from: data)
                for value in Array(loaded.identities.values) + Array((loaded.enrollmentCandidates ?? [:]).values) {
                    guard value.version == 5, value.privateKey.count == 32 else { throw V5IdentityError.invalid }
                    if let device = value.device {
                        guard try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString() == device.leafKey else { throw V5IdentityError.wrongDevice }
                    }
                }
                vault = loaded; currentScope = loaded.activeScope; state = loaded.identities[currentScope]
            }
        } catch { failure = ClientFailure(.v5IdentityInvalid) }
    }

    var isEnrolled: Bool { state?.device != nil && failure == nil }
    var device: V5Device? { state?.device }
    var contacts: [TrustedContact] { state?.trust.contacts ?? [] }
    var rooms: [TrustedRoom] { state?.trust.rooms ?? [] }
    var fingerprint: String { guard let key = state?.device?.accountKey else { return "" }; return (try? V5Crypto.fingerprint(key)) ?? "" }
    var deviceFingerprint: String {
        guard let value = state, let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString() else { return "" }
        return (try? V5Crypto.fingerprint(key)) ?? ""
    }
    var canEnroll: Bool { state?.device?.certificates.last?.canEnroll == true }

    private func persist(_ next: StoredIdentity) throws {
        var updated = vault; updated.activeScope = currentScope; updated.identities[currentScope] = next
        try persistence.save(JSONEncoder().encode(updated))
        vault = updated; state = next; revision &+= 1
    }
    private func requireState() throws -> StoredIdentity {
        guard failure == nil else { throw V5IdentityError.invalid }
        return state ?? StoredIdentity(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation)
    }
    func requireDevice() throws -> V5Device {
        guard failure == nil, let value = state?.device else { throw V5IdentityError.notEnrolled }
        try value.validate()
        return value
    }

    var savedScopes: [String] { vault.identities.keys.filter { !$0.isEmpty }.sorted() }
    var isBound: Bool { state?.bound != false && isEnrolled }
    func select(origin: String, accountID: String) throws {
        guard failure == nil else { throw IdentitySetupError.invalid("本机身份存储损坏，请恢复或清空本机数据，不能自动重建账号根。") }
        currentScope = origin + "|" + accountID; state = vault.identities[currentScope]; revision &+= 1
    }
    func selectSavedScope(_ scope: String) throws {
        guard vault.identities[scope] != nil, failure == nil else { throw V5IdentityError.invalid }
        currentScope = scope; state = vault.identities[scope]; revision &+= 1
    }
    func clearAll() throws {
        try persistence.clear(); state = nil; vault = IdentityVault(); currentScope = ""; failure = nil; revision &+= 1
    }
    func makeCandidate(rootSeed: Data) throws -> V5Device {
        let root = try Curve25519.Signing.PrivateKey(rawRepresentation: rootSeed)
        let key = Curve25519.Signing.PrivateKey()
        let accountKey = root.publicKey.rawRepresentation.base64EncodedString()
        let now = Int64(Date().timeIntervalSince1970)
        var certificate = V5Certificate(accountKey: accountKey, deviceKey: key.publicKey.rawRepresentation.base64EncodedString(), issuerKey: accountKey, parentHash: "", serial: V5Crypto.random(16).base64EncodedString(), canEnroll: true, notBefore: now, notAfter: now + V5Crypto.deviceLifetime)
        certificate.signature = try V5Crypto.sign(rootSeed, certificate.message)
        let device = V5Device(accountKey: accountKey, certificates: [certificate])
        try persist(StoredIdentity(privateKey: key.rawRepresentation, bound: false, device: device))
        return device
    }
    func markBound() throws { guard var value = state else { throw V5IdentityError.notEnrolled }; value.bound = true; try persist(value) }
    // Recovery/enrollment cannot overwrite the active key until the server has
    // accepted its replacement. Persist candidates separately for lost replies.
    func enrollmentCandidate() throws -> DeviceIdentityStore {
        guard failure == nil else { throw V5IdentityError.invalid }
        let candidate = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        candidate.currentScope = currentScope
        candidate.state = vault.enrollmentCandidates?[currentScope]
        candidate.vault.identities[currentScope] = candidate.state
        return candidate
    }
    func saveEnrollmentCandidate(_ candidate: DeviceIdentityStore) throws {
        guard failure == nil, candidate.failure == nil, candidate.currentScope == currentScope,
              var value = candidate.state else { throw V5IdentityError.invalid }
        value.bound = false
        var updated = vault
        if updated.enrollmentCandidates == nil { updated.enrollmentCandidates = [:] }
        updated.enrollmentCandidates?[currentScope] = value
        try persistence.save(JSONEncoder().encode(updated)); vault = updated
    }
    func activateEnrollmentCandidate(_ candidate: DeviceIdentityStore) throws {
        guard failure == nil, candidate.currentScope == currentScope,
              var value = candidate.state, try candidate.requireDevice() == vault.enrollmentCandidates?[currentScope]?.device else { throw V5IdentityError.invalid }
        value.bound = true
        var updated = vault; updated.activeScope = currentScope; updated.identities[currentScope] = value
        updated.enrollmentCandidates?.removeValue(forKey: currentScope)
        try persistence.save(JSONEncoder().encode(updated))
        vault = updated; state = value; revision &+= 1
    }
    func signIdentityMessage(_ message: Data) throws -> String {
        guard let value = state, failure == nil else { throw V5IdentityError.notEnrolled }
        return try V5Crypto.sign(value.privateKey, message)
    }

    func preparePairingKey(replacing: Bool = false) throws -> String {
        let value = try replacing ? StoredIdentity(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, bound: false) : requireState()
        guard value.device == nil else { throw V5IdentityError.changed }
        try persist(value)
        return try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString()
    }

    // Called only after the pairing session has verified both SAS MACs and the
    // user has confirmed the exact candidate. Never import private root keys.
    func issuePairedDevice(_ request: DevicePairingRequest, issuer: V5Device, canEnroll: Bool) throws -> V5Device {
        try request.validate()
        guard currentScope == request.origin + "|" + request.accountID, try requireDevice() == issuer,
              issuer.accountKey == request.accountKey, issuer.certificates.last?.canEnroll == true,
              issuer.certificates.count < V5Crypto.maxChain, issuer.leafKey != request.deviceKey else { throw V5IdentityError.untrusted }
        let now = Int64(Date().timeIntervalSince1970)
        var certificate = V5Certificate(accountKey: issuer.accountKey, deviceKey: request.deviceKey, issuerKey: issuer.leafKey,
            parentHash: issuer.certificates.last!.digest, serial: V5Crypto.random(16).base64EncodedString(), canEnroll: canEnroll,
            notBefore: now, notAfter: min(now + V5Crypto.deviceLifetime, issuer.notAfter))
        certificate.signature = try signIdentityMessage(certificate.message)
        let device = V5Device(accountKey: issuer.accountKey, certificates: issuer.certificates + [certificate])
        try device.validate()
        return device
    }

    func acceptPairedDevice(_ approval: DevicePairingApproval, request: DevicePairingRequest, issuer: V5Device) throws {
        try request.validate(); try approval.validate(request: request, issuer: issuer)
        var value = try requireState()
        guard currentScope == request.origin + "|" + request.accountID, value.device == nil,
              try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString() == request.deviceKey else { throw V5IdentityError.wrongDevice }
        value.device = approval.device; value.enrollmentNonce = nil; value.enrollmentExpiresAt = nil
        try persist(value)
    }

    func prepareNewDeviceEnrollment() throws -> String {
        guard failure == nil else { throw V5IdentityError.invalid }
        try persist(StoredIdentity(privateKey: Curve25519.Signing.PrivateKey().rawRepresentation, bound: false))
        return try enrollmentRequest()
    }
    func enrollmentRequest() throws -> String {
        var value = try requireState()
        guard value.device == nil else { throw V5IdentityError.changed }
        let nonce = V5Crypto.random().base64EncodedString(), expires = Int64(Date().timeIntervalSince1970) + 600
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString()
        var request = DeviceEnrollmentRequest(version: 5, deviceKey: key, nonce: nonce, expiresAt: expires, signature: "")
        request.signature = try V5Crypto.sign(value.privateKey, request.message)
        value.enrollmentNonce = nonce; value.enrollmentExpiresAt = expires
        try persist(value)
        return try Self.exportCode(request, prefix: "chirp-device-request-v5:")
    }

    func enrollmentDeviceFingerprint(_ code: String) throws -> String {
        let request: DeviceEnrollmentRequest = try Self.importCode(code, prefix: "chirp-device-request-v5:")
        try request.validate()
        return try V5Crypto.fingerprint(request.deviceKey)
    }

    func approveDevice(_ code: String, expectedDeviceFingerprint: String, canEnroll: Bool) throws -> String {
        let request: DeviceEnrollmentRequest = try Self.importCode(code, prefix: "chirp-device-request-v5:")
        try request.validate()
        guard try Self.normalizedFingerprint(expectedDeviceFingerprint) == V5Crypto.fingerprint(request.deviceKey) else { throw V5IdentityError.wrongDevice }
        let issuer = try requireDevice()
        guard let value = state, issuer.certificates.last?.canEnroll == true,
              issuer.certificates.count < V5Crypto.maxChain, request.deviceKey != issuer.leafKey else { throw V5IdentityError.untrusted }
        let now = Int64(Date().timeIntervalSince1970)
        var certificate = V5Certificate(accountKey: issuer.accountKey, deviceKey: request.deviceKey, issuerKey: issuer.leafKey,
            parentHash: issuer.certificates.last!.digest, serial: V5Crypto.random(16).base64EncodedString(), canEnroll: canEnroll,
            notBefore: now, notAfter: min(now + V5Crypto.deviceLifetime, issuer.notAfter))
        certificate.signature = try V5Crypto.sign(value.privateKey, certificate.message)
        let device = V5Device(accountKey: issuer.accountKey, certificates: issuer.certificates + [certificate])
        try device.validate()
        var response = DeviceEnrollmentResponse(version: 5, requestNonce: request.nonce, device: device, issuer: issuer,
            trustData: try JSONEncoder().encode(value.trust), signature: "")
        response.signature = try V5Crypto.sign(value.privateKey, response.message)
        return try Self.exportCode(response, prefix: "chirp-device-approval-v5:")
    }

    func acceptDeviceApproval(_ code: String, expectedFingerprint: String, expectedAccountKey: String? = nil) throws {
        let response: DeviceEnrollmentResponse = try Self.importCode(code, prefix: "chirp-device-approval-v5:")
        var value = try requireState()
        try response.issuer.validate(); try response.device.validate()
        guard let certificate = response.device.certificates.last else { throw V5IdentityError.invalid }
        guard expectedAccountKey == nil || response.device.accountKey == expectedAccountKey else { throw V5IdentityError.wrongDevice }
        guard value.device == nil, response.version == 5, response.requestNonce == value.enrollmentNonce,
              (value.enrollmentExpiresAt ?? 0) > Int64(Date().timeIntervalSince1970),
              response.device.accountKey == response.issuer.accountKey, response.issuer.certificates.last?.canEnroll == true,
              try Self.normalizedFingerprint(expectedFingerprint) == V5Crypto.fingerprint(response.issuer.accountKey),
              response.device.certificates == response.issuer.certificates + [certificate],
              try Curve25519.Signing.PrivateKey(rawRepresentation: value.privateKey).publicKey.rawRepresentation.base64EncodedString() == response.device.leafKey else { throw V5IdentityError.wrongDevice }
        try V5Crypto.verify(key: response.issuer.leafKey, signature: response.signature, message: response.message)
        let trust = try JSONDecoder().decode(DeviceTrustData.self, from: response.trustData)
        guard trust.contacts.count <= 1024, trust.rooms.count <= 1024 else { throw V5IdentityError.invalid }
        for contact in trust.contacts { _ = try V5Crypto.bytes(contact.accountKey, count: 32) }
        value.device = response.device; value.trust = trust; value.enrollmentNonce = nil; value.enrollmentExpiresAt = nil
        try persist(value)
    }

    func loginProof(client: String, authorization: String, verifier: String) throws -> V5LoginProof {
        let device = try requireDevice()
        guard let value = state else { throw V5IdentityError.notEnrolled }
        var proof = V5LoginProof(device: device, nonce: V5Crypto.random().base64EncodedString())
        proof.signature = try V5Crypto.sign(value.privateKey, proof.message(client: client, authorization: authorization, verifier: verifier))
        return proof
    }

    func contactCode() throws -> String { try Self.exportCode(requireDevice(), prefix: "chirp-contact-v5:") }

    func trustContact(_ code: String, name: String, expectedFingerprint: String) throws {
        let device: V5Device = try Self.importCode(code, prefix: "chirp-contact-v5:")
        try device.validate()
        guard try Self.normalizedFingerprint(expectedFingerprint) == V5Crypto.fingerprint(device.accountKey), !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 128 else { throw V5IdentityError.untrusted }
        var value = try requireState()
        value.trust.contacts.removeAll { $0.accountKey == device.accountKey }
        value.trust.contacts.append(TrustedContact(accountKey: device.accountKey, name: name))
        try persist(value)
    }

    func displayName(for root: String) -> String? { contacts.first { $0.accountKey == root }?.name }

    func createRoom(origin: String, roomID: String) throws -> V5RoomPolicy {
        var value = try requireState()
        let device = try requireDevice()
        guard !value.trust.rooms.contains(where: { $0.policy.origin == origin && $0.policy.roomID == roomID }) else { throw V5IdentityError.changed }
        let now = Int64(Date().timeIntervalSince1970)
        var policy = V5RoomPolicy(origin: origin, roomID: roomID, trustID: V5Crypto.random().base64EncodedString(), ownerKey: device.accountKey,
            version: 1, previousHash: "", members: [device.accountKey], revokedDevices: [], notBefore: now, notAfter: min(now + V5Crypto.policyLifetime, device.notAfter), signer: device)
        policy.signature = try V5Crypto.sign(value.privateKey, policy.message)
        try policy.validate()
        value.trust.rooms.append(TrustedRoom(policy: policy)); try persist(value)
        return policy
    }

    func updateRoom(_ previous: V5RoomPolicy, members: [String], revokedDevices: [String]) throws -> V5RoomPolicy {
        let device = try requireDevice()
        guard let value = state, previous.ownerKey == device.accountKey, previous.version < Int64.max else { throw V5IdentityError.untrusted }
        for root in members { guard contacts.contains(where: { $0.accountKey == root }) else { throw V5IdentityError.untrusted } }
        let now = Int64(Date().timeIntervalSince1970)
        var policy = V5RoomPolicy(origin: previous.origin, roomID: previous.roomID, trustID: previous.trustID, ownerKey: previous.ownerKey,
            version: previous.version + 1, previousHash: previous.digest, members: Array(Set(members)).sorted(), revokedDevices: Array(Set(revokedDevices)).sorted(),
            notBefore: now, notAfter: min(now + V5Crypto.policyLifetime, device.notAfter), signer: device)
        policy.signature = try V5Crypto.sign(value.privateKey, policy.message)
        try policy.validate()
        return policy
    }

    func roomCode(_ policy: V5RoomPolicy) throws -> String { try Self.exportCode(policy, prefix: "chirp-room-v5:") }

    func trustRoom(_ code: String, expectedFingerprint: String) throws -> V5RoomPolicy {
        let policy: V5RoomPolicy = try Self.importCode(code, prefix: "chirp-room-v5:")
        try policy.validate()
        guard try Self.normalizedFingerprint(expectedFingerprint) == V5Crypto.fingerprint(policy.ownerKey) else { throw V5IdentityError.untrusted }
        var value = try requireState()
        if value.trust.rooms.contains(where: { $0.policy.origin == policy.origin && $0.policy.roomID == policy.roomID }) {
            return try acceptRoomPolicy(policy, origin: policy.origin, roomID: policy.roomID)
        }
        value.trust.rooms.append(TrustedRoom(policy: policy)); try persist(value)
        return policy
    }

    @discardableResult
    func acceptRoomPolicy(_ policy: V5RoomPolicy, origin: String, roomID: String, historical: Bool = false) throws -> V5RoomPolicy {
        if policy.isMutual {
            guard policy == V5RoomPolicy.mutual(origin: origin, roomID: roomID) else { throw V5IdentityError.changed }
            return policy
        }
        let now = Int64(Date().timeIntervalSince1970)
        let verificationTime = historical ? min(now, max(1, policy.notBefore)) : now
        try policy.validate(now: verificationTime)
        var value = try requireState()
        guard let index = value.trust.rooms.firstIndex(where: { $0.policy.origin == origin && $0.policy.roomID == roomID }) else { throw V5IdentityError.untrusted }
        let previous = value.trust.rooms[index].policy
        try previous.allows(policy.signer, now: verificationTime)
        guard policy.origin == origin, policy.roomID == roomID, policy.ownerKey == previous.ownerKey, policy.trustID == previous.trustID,
              (policy.version == previous.version || (previous.version < Int64.max && policy.version == previous.version + 1)), policy.version != previous.version || policy.digest == previous.digest,
              policy.version - previous.version != 1 || policy.previousHash == previous.digest else { throw V5IdentityError.changed }
        if policy.version > previous.version { value.trust.rooms[index].policy = policy; try persist(value) }
        return policy
    }

    func roomPolicy(origin: String, roomID: String) throws -> V5RoomPolicy {
        guard let value = rooms.first(where: { $0.policy.origin == origin && $0.policy.roomID == roomID })?.policy else { throw V5IdentityError.untrusted }
        return value
    }

    func entryBinding(login: ClientSession, admission: RoomAdmission, mlsKey: String, policy: V5RoomPolicy) throws -> V5EntryBinding {
        let device = try requireDevice()
        guard let value = state, login.deviceIdentity == device else { throw V5IdentityError.wrongDevice }
        try policy.allows(device)
        let now = Int64(Date().timeIntervalSince1970)
        var binding = V5EntryBinding(device: device, origin: policy.origin, roomID: admission.roomID, trustID: policy.trustID, policyHash: policy.digest,
            identity: admission.identity, mlsKey: mlsKey, nonce: V5Crypto.random().base64EncodedString(), notBefore: now,
            notAfter: min(now + V5Crypto.entryLifetime, Int64(login.expiresAt.timeIntervalSince1970), device.notAfter))
        binding.signature = try V5Crypto.sign(value.privateKey, binding.message)
        try binding.validate(policy: policy)
        return binding
    }

    static func normalizedFingerprint(_ value: String) throws -> String {
        let result = value.lowercased().filter { !$0.isWhitespace && $0 != ":" && $0 != "-" }
        guard result.count == 64, result.allSatisfy({ $0.isHexDigit && $0.isASCII }) else { throw V5IdentityError.untrusted }
        return result
    }
    private static func exportCode<T: Encodable>(_ value: T, prefix: String) throws -> String {
        let code = prefix + (try JSONEncoder().encode(value)).base64EncodedString()
        guard code.utf8.count <= 256 * 1024 else { throw V5IdentityError.invalid }
        return code
    }
    private static func importCode<T: Decodable>(_ value: String, prefix: String) throws -> T {
        let code = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard code.hasPrefix(prefix), code.utf8.count <= 256 * 1024,
              let data = Data(base64Encoded: String(code.dropFirst(prefix.count))) else { throw V5IdentityError.invalid }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
