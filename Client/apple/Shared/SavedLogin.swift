import ChirpMLS
import Foundation
import LocalAuthentication
import Security

/// This handle is accepted only by the resumption endpoints, with proof from the original device.
struct SavedLogin: Codable, Sendable {
    let token: String
    let connection: ServerConnection
    let accountID: String
    let participant: String
    let deviceDigest: String
    let expiresAt: Date

    init?(session: ClientSession, token: String?) {
        guard let token, token.range(of: #"^resume(-v1)?_[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let device = session.deviceIdentity else { return nil }
        self.token = token
        connection = session.connection
        accountID = session.member.id
        participant = session.participantIdentity
        deviceDigest = device.digest
        expiresAt = session.expiresAt
    }

    // A previous Keychain format saved the original business expiry in a separate field.
    private enum LegacyKeys: String, CodingKey { case sessionExpiresAt }

    init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        token = try fields.decode(String.self, forKey: .token)
        connection = try fields.decode(ServerConnection.self, forKey: .connection)
        accountID = try fields.decode(String.self, forKey: .accountID)
        participant = try fields.decode(String.self, forKey: .participant)
        deviceDigest = try fields.decode(String.self, forKey: .deviceDigest)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        expiresAt = try legacy.decodeIfPresent(Date.self, forKey: .sessionExpiresAt) ?? fields.decode(Date.self, forKey: .expiresAt)
    }

    @MainActor
    func restore(identity: DeviceIdentityStore, clock: NetworkClock, discovery: ServerConnectionAPI = ServerConnectionAPI(),
                 configuration: URLSessionConfiguration? = nil) async throws -> ClientSession {
        guard expiresAt > Date() else { throw ClientFailure(.loginExpired) }
        async let refreshed = discovery.refresh(connection)
        await clock.check(manual: true)
        try clock.requireReady()
        // Rediscovery checks the current client version and pins the original service origins.
        let current = try await refreshed
        let origin = ServerAddress.identityOrigin(current.passkeyOrigin)
        try Task.checkCancellation()
        try identity.select(origin: origin, accountID: accountID)
        let device = try identity.requireDevice()
        guard device.digest == deviceDigest, identity.isBound else { throw ClientFailure(.invalidLoginSession) }
        struct Challenge: Decodable { let challenge: String }
        let reply: Challenge = try await IdentitySetupAPI.post("api/client/resume/challenge", connection: current,
            body: JSONEncoder().encode(["resume_token": token]), configuration: configuration)
        try Task.checkCancellation()
        try clock.requireReady()
        guard expiresAt > Date(), identity.device == device,
              reply.challenge.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else {
            throw ClientFailure(.invalidLoginSession)
        }
        let domain = token.hasPrefix("resume-v1_") ? "Chirp login resumption v1" : "Chirp Apple login resumption v1"
        let proof = V5Crypto.message(domain, [origin, current.client.platform, participant,
            V5Crypto.hash(Data(token.utf8)), reply.challenge, deviceDigest])
        let response: ClientSession.Response = try await IdentitySetupAPI.post("api/client/resume/complete", connection: current,
            body: JSONEncoder().encode(["resume_token": token, "signature": try identity.signIdentityMessage(proof)]), configuration: configuration)
        try Task.checkCancellation()
        guard expiresAt > Date() else { throw ClientFailure(.loginExpired) }
        let session = try ClientSession(response: response, connection: current, expectedDevice: device, sessionDeadline: expiresAt)
        guard session.member.id == accountID, session.participantIdentity == participant else { throw ClientFailure(.invalidLoginSession) }
        return session
    }
}

@MainActor
protocol LoginVault {
    var hasSavedLogin: Bool { get }
    var expiration: Date? { get }
    func save(_ login: SavedLogin) throws
    /// Reads the saved grant after fresh OS authentication on cold launch.
    func open() async throws -> SavedLogin
    func cancel()
    func clear()
}

/// A system authentication panel may temporarily take focus away from the Mac app.
@MainActor
enum LocalAuthenticationPrompt {
    private static var presentations = 0
    static var isPresented: Bool { presentations > 0 }

    static func verify(_ policy: LAPolicy, using context: LAContext, reason: String) async throws {
        presentations += 1
        defer { presentations -= 1 }
        guard try await context.evaluatePolicy(policy, localizedReason: reason) else { throw LAError(.authenticationFailed) }
    }
}

// Publish only the item name and scheduling hint before reporting sign-in success.
// The grant and authoritative deadline remain in the access-controlled Keychain item.
struct LoginReferenceStore {
    struct Reference: Codable { let account: UUID; let expiresAt: Date; let usesSessionExpiry: Bool? }
    private let directory: URL
    private let defaults: UserDefaults
    private let legacyKey = "chirp.savedLogin.reference.v1"
    private var file: URL { directory.appending(path: "reference.json") }

    init(directory: URL = URL.applicationSupportDirectory.appending(path: "Chirp/Login"), defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
    }

    func load() -> Reference? {
        let data = (try? Data(contentsOf: file)) ?? defaults.data(forKey: legacyKey)
        return data.flatMap { try? JSONDecoder().decode(Reference.self, from: $0) }
    }

    func save(_ reference: Reference) throws {
        var directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var flags = URLResourceValues()
        flags.isExcludedFromBackup = true
        try directory.setResourceValues(flags)
        let data = try JSONEncoder().encode(reference)
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        defaults.removeObject(forKey: legacyKey)
    }

    func clear() {
        try? FileManager.default.removeItem(at: file)
        defaults.removeObject(forKey: legacyKey)
    }
}

@MainActor
final class KeychainLoginVault: LoginVault {
    private let references = LoginReferenceStore()
    var hasSavedLogin: Bool { references.load() != nil }
    // Earlier public markers scheduled a different cutoff. Read the protected item after authentication.
    var expiration: Date? {
        guard let ref = references.load(), ref.usesSessionExpiry == true else { return nil }
        return ref.expiresAt
    }
    private var context: LAContext?
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "cn.youzifeile.chirp.login.resume.v1",
         kSecUseDataProtectionKeychain as String: true, kSecAttrSynchronizable as String: false]
    }

    #if os(iOS)
    private let policy = LAPolicy.deviceOwnerAuthenticationWithBiometrics
    private let protection = SecAccessControlCreateFlags.biometryCurrentSet
    #else
    private let policy = LAPolicy.deviceOwnerAuthentication
    private let protection = SecAccessControlCreateFlags.userPresence
    #endif

    func save(_ login: SavedLogin) throws {
        guard let acl = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly, protection, nil) else {
            throw ClientFailure(.secureLoginFailed)
        }
        let ref = LoginReferenceStore.Reference(account: UUID(), expiresAt: login.expiresAt, usesSessionExpiry: true)
        var item = query
        item[kSecAttrAccount as String] = ref.account.uuidString
        item[kSecAttrAccessControl as String] = acl
        item[kSecValueData as String] = try JSONEncoder().encode(login)
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw ClientFailure(.secureLoginFailed) }
        do { try references.save(ref) }
        catch {
            clear()
            throw ClientFailure(.secureLoginFailed)
        }
    }

    func open() async throws -> SavedLogin {
        guard let ref = references.load() else { throw ClientFailure(.loginExpired) }
        if ref.usesSessionExpiry == true, ref.expiresAt <= Date() { throw ClientFailure(.loginExpired) }
        let auth = LAContext()
        auth.touchIDAuthenticationAllowableReuseDuration = 0
        #if os(iOS)
        auth.localizedFallbackTitle = ""
        #endif
        let reason: LocalizedMessage = "验证本机身份以解锁 Chirp。"
        auth.localizedReason = reason.localized(in: AppLanguage.load().locale)
        context = auth
        defer {
            auth.invalidate()
            if context === auth { context = nil }
        }
        try await LocalAuthenticationPrompt.verify(policy, using: auth, reason: auth.localizedReason)
        try Task.checkCancellation()
        var request = query
        request[kSecAttrAccount as String] = ref.account.uuidString
        request[kSecUseAuthenticationContext as String] = auth
        request[kSecReturnData as String] = true
        // The same evaluated context must satisfy the item's ACL without a second prompt.
        auth.interactionNotAllowed = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { throw ClientFailure(.loginExpired) }
        guard status == errSecSuccess, let data = result as? Data else { throw ClientFailure(.localUnlockFailed) }
        guard let login = try? JSONDecoder().decode(SavedLogin.self, from: data) else {
            throw ClientFailure(.invalidLoginSession)
        }
        guard login.expiresAt > Date() else { throw ClientFailure(.loginExpired) }
        if ref.usesSessionExpiry != true {
            try references.save(.init(account: ref.account, expiresAt: login.expiresAt, usesSessionExpiry: true))
        } else if login.expiresAt != ref.expiresAt {
            throw ClientFailure(.invalidLoginSession)
        }
        return login
    }

    func cancel() { context?.invalidate() }

    func clear() {
        references.clear()
        var removal = query
        let silent = LAContext()
        silent.interactionNotAllowed = true
        removal[kSecUseAuthenticationContext as String] = silent
        SecItemDelete(removal as CFDictionary)
    }
}
