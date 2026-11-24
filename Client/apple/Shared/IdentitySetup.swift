import ChirpMLS
import CryptoKit
import Foundation
import Observation

struct AuthenticatedIdentitySetup: Decodable, Sendable {
    let token: String
    let accountID: String
    let username: String
    let origin: String
    let accountKey: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case token = "setup_token", accountID = "account_id", username, origin = "service_origin", accountKey = "account_key", expiresAt = "expires_at"
    }
}

enum IdentitySetupAPI {
    static func post<T: Decodable>(_ path: String, connection: ServerConnection, body: Data, configuration: URLSessionConfiguration? = nil, endpoint: URL? = nil, operation: StaticString = #function) async throws -> T {
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 15
        let session = HTTPDataSession(configuration: configuration); defer { session.close() }
        let url = endpoint ?? connection.passkeyOrigin.appendingPathComponent(path)
        guard ServerAddress.sameOrigin(url, connection.passkeyOrigin) else { throw ClientFailure(.invalidServerConfiguration) }
        var request = URLRequest(url: url); connection.client.apply(to: &request)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = body
        let (data, response) = try await session.data(for: request, maxBytes: 65536, operation: operation)
        guard let response = response as? HTTPURLResponse else { throw ClientFailure(.invalidResponse) }
        guard response.statusCode == 200 else { throw ClientFailure.response(data: data, status: response.statusCode) }
        if T.self == Data.self { return data as! T }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

@MainActor @Observable
final class IdentitySetupController {
    enum Step: String, Hashable { case idle, password, resume, confirmation, authorize, submitting }
    private(set) var step: Step = .idle
    private(set) var authentication: AuthenticatedIdentitySetup?
    private(set) var pending: PendingIdentitySetup?
    private(set) var failure: String?
    private(set) var busy = false
    private(set) var pairing: DevicePairingSession?
    private var pairingActivationAttempted = false
    #if DEBUG
    private var designPreview = false
    #endif
    var password = ""
    var confirmation = ""
    var enrollmentRequest = ""
    var approvalCode = ""
    var approvalFingerprint = ""
    var clock = BackupConfirmationClock()
    private let identity: DeviceIdentityStore
    private let storage: PendingIdentityStorage
    private let configuration: URLSessionConfiguration?
    private let requireClock: @MainActor () throws -> Void
    private var rootSeed: Data?
    private var connection: ServerConnection?
    private var verifier = ""
    private var challenge = ""
    private var verifiedFileDigest: String?
    private var enrollment: DeviceIdentityStore?
    private var existingDeviceRejected = false
    var onComplete: (@MainActor (ClientSession) -> Void)?
    var scope: String { authentication.map { $0.origin + "|" + $0.accountID } ?? "" }
    var isPresented: Bool { step != .idle }
    var filename: String { RecoveryFile.filename(username: authentication?.username ?? "identity") }
    var backupVerified: Bool { verifiedFileDigest != nil && verifiedFileDigest == pending?.digest }
    var enrollmentDeviceFingerprint: String { (enrollment ?? identity).deviceFingerprint }

    init(identity: DeviceIdentityStore, storage: PendingIdentityStorage = PendingIdentityStorage(), configuration: URLSessionConfiguration? = nil,
         requireClock: @escaping @MainActor () throws -> Void) {
        self.identity = identity; self.storage = storage; self.configuration = configuration
        self.requireClock = requireClock
    }
    func begin(_ authentication: AuthenticatedIdentitySetup, connection: ServerConnection, verifier: String) async throws {
        try requireClock()
        guard authentication.origin == ServerAddress.identityOrigin(connection.passkeyOrigin), !authentication.accountID.isEmpty,
              authentication.expiresAt > Int64(Date().timeIntervalSince1970), authentication.expiresAt <= Int64(Date().timeIntervalSince1970) + 301 else { throw V5IdentityError.invalid }
        pairing?.stop(); pairing = nil; pairingActivationAttempted = false
        self.authentication = authentication; self.connection = connection; self.verifier = verifier; failure = nil
        enrollment = nil; existingDeviceRejected = false; enrollmentRequest = ""; approvalCode = ""; approvalFingerprint = ""
        try identity.select(origin: authentication.origin, accountID: authentication.accountID)
        pending = try storage.load(scope)
        if let pending {
            guard pending.origin == authentication.origin, pending.accountID == authentication.accountID else { throw V5IdentityError.changed }
            if !authentication.accountKey.isEmpty && authentication.accountKey != pending.rootKey {
                self.pending = nil; step = .authorize
                failure = IdentitySetupError.invalid("另一台设备已建立不同的账号根。保留了本机候选文件，请授权或恢复获胜的身份。").localizedDescription
                return
            }
            step = .resume; return
        }
        if !authentication.accountKey.isEmpty {
            let candidate = try identity.enrollmentCandidate()
            if candidate.device?.accountKey == authentication.accountKey, (try? candidate.requireDevice()) != nil { enrollment = candidate }
            if enrollment != nil || (identity.device?.accountKey == authentication.accountKey && (try? identity.requireDevice()) != nil) {
                do { try await finish(); return }
                catch {
                    guard self.authentication?.token == authentication.token else { return }
                    let code = ClientFailure.capture(error).code
                    existingDeviceRejected = [ClientErrorCode.identityBlacklisted.rawValue, ClientErrorCode.deviceIdentityRequired.rawValue].contains(code)
                    step = .authorize; failure = error.localizedDescription; return
                }
            }
            step = .authorize
            enrollment = candidate
            if candidate.device == nil {
                enrollmentRequest = try candidate.enrollmentRequest()
                try identity.saveEnrollmentCandidate(candidate)
            }
            return
        }
        // Only an authenticated, still-unbound account can create a new root.
        rootSeed = Curve25519.Signing.PrivateKey().rawRepresentation
        _ = try identity.makeCandidate(rootSeed: rootSeed!)
        try await bindChallenge()
        guard self.authentication?.token == authentication.token else { throw CancellationError() }
        step = .password
    }
    private func bindChallenge(using candidate: DeviceIdentityStore? = nil) async throws {
        try requireClock()
        guard let connection, let authentication else { throw V5IdentityError.invalid }
        struct Request: Encodable { let setup_token: String; let code_verifier: String; let device: V5Device }
        struct Response: Decodable { let challenge: String }
        let result: Response = try await IdentitySetupAPI.post("api/client/identity/challenge", connection: connection,
            body: JSONEncoder().encode(Request(setup_token: authentication.token, code_verifier: verifier, device: (candidate ?? identity).requireDevice())), configuration: configuration)
        guard self.authentication?.token == authentication.token else { throw CancellationError() }
        try requireClock()
        challenge = result.challenge
    }
    func saveEncryptedFile() async {
        await perform {
            guard let authentication, let rootSeed, let device = identity.device else { throw V5IdentityError.invalid }
            let payload = RecoveryPayload(rootSeed: rootSeed.base64EncodedString(), rootPublicKey: device.accountKey,
                serviceOrigin: authentication.origin, accountID: authentication.accountID, username: authentication.username,
                createdAt: ISO8601DateFormatter().string(from: Date()), sourcePlatform: RecoveryFile.platform)
            let file = try await RecoveryFile.encrypt(payload, password: password, confirmation: confirmation)
            guard self.authentication?.token == authentication.token else { throw CancellationError() }
            let record = PendingIdentitySetup(origin: authentication.origin, accountID: authentication.accountID, rootKey: device.accountKey, device: device, file: file)
            try storage.save(record, scope: scope)
            guard let loaded = try storage.load(scope), loaded.file == file, try identity.requireDevice() == device else { throw V5IdentityError.invalid }
            pending = loaded; if var secret = self.rootSeed { secret.resetBytes(in: 0..<secret.count) }; self.rootSeed = nil
            password = ""; confirmation = ""; verifiedFileDigest = nil
        }
    }
    func resume() async {
        await perform {
            guard var record = pending, let authentication else { throw V5IdentityError.invalid }
            let payload = try await RecoveryFile.decrypt(record.file, password: password)
            guard self.authentication?.token == authentication.token else { throw CancellationError() }
            try payload.validate(origin: authentication.origin, accountID: authentication.accountID, root: record.rootKey)
            if identity.device != record.device || (try? identity.requireDevice()) == nil {
                record.device = try identity.makeCandidate(rootSeed: V5Crypto.bytes(payload.rootSeed, count: 32))
                try storage.save(record, scope: scope); pending = record
            }
            password = ""; try await bindChallenge()
            if record.confirmedDigest == record.digest { try await finish() } else { step = .password }
        }
    }
    func exported(success: Bool, expectedScope: String? = nil, expectedDigest: String? = nil) {
        do {
            guard var value = pending,
                  expectedScope == nil || expectedScope == scope,
                  expectedDigest == nil || expectedDigest == value.digest else { return }
            value.exported = success; value.confirmedDigest = nil
            try storage.save(value, scope: scope); pending = value
        } catch { failure = error.localizedDescription }
    }
    func showConfirmation() {
        guard pending?.exported == true else { return }; clock = BackupConfirmationClock(); step = .confirmation; clock.setVisible(true)
    }
    func backToSave() { clock.setVisible(false); step = .password }
    func confirmBackup() async {
        guard step == .confirmation, clock.remaining() == 0, var value = pending, value.exported else { return }
        await perform {
            value.confirmedDigest = value.digest; try storage.save(value, scope: scope); pending = value
            try await finish()
        }
    }
    func importRecovery(_ file: Data) async {
        await perform {
            guard let authentication, !authentication.accountKey.isEmpty else { throw V5IdentityError.invalid }
            pairing?.stop(); pairing = nil
            let payload = try await RecoveryFile.decrypt(file, password: password)
            guard self.authentication?.token == authentication.token else { throw CancellationError() }
            try payload.validate(origin: authentication.origin, accountID: authentication.accountID, root: authentication.accountKey)
            if enrollment == nil, !existingDeviceRejected, identity.device?.accountKey == authentication.accountKey,
               (try? identity.requireDevice()) != nil {
                password = ""; try await finish(); return
            }
            let candidate = try enrollment ?? identity.enrollmentCandidate()
            if candidate.device?.accountKey != authentication.accountKey || (try? candidate.requireDevice()) == nil || existingDeviceRejected {
                _ = try candidate.makeCandidate(rootSeed: V5Crypto.bytes(payload.rootSeed, count: 32))
            }
            try identity.saveEnrollmentCandidate(candidate); enrollment = candidate; existingDeviceRejected = false; password = ""
            try await finish()
        }
    }
    func verifyBackup(_ file: Data) async {
        await perform {
            verifiedFileDigest = nil
            guard let authentication, let pending else { throw V5IdentityError.invalid }
            let payload = try await RecoveryFile.decrypt(file, password: password)
            guard self.authentication?.token == authentication.token else { throw CancellationError() }
            try payload.validate(origin: authentication.origin, accountID: authentication.accountID, root: pending.rootKey)
            verifiedFileDigest = pending.digest; password = ""
        }
    }
    func prepareEnrollment() {
        do {
            try requireClock()
            guard !busy, step == .authorize, authentication?.accountKey.isEmpty == false else { return }
            let candidate = try identity.enrollmentCandidate()
            enrollmentRequest = try candidate.prepareNewDeviceEnrollment()
            try identity.saveEnrollmentCandidate(candidate); enrollment = candidate
            approvalCode = ""; approvalFingerprint = ""; existingDeviceRejected = false
        } catch { failure = error.localizedDescription }
    }
    func startPairing() async {
        await perform {
            guard step == .authorize, let authentication, !authentication.accountKey.isEmpty else { throw V5IdentityError.invalid }
            pairing?.stop(); pairing = nil; pairingActivationAttempted = false
            let candidate = try enrollment ?? identity.enrollmentCandidate()
            _ = try candidate.preparePairingKey(replacing: existingDeviceRejected || candidate.device != nil)
            try identity.saveEnrollmentCandidate(candidate); enrollment = candidate
            #if DEBUG
            if designPreview {
                pairing = try await .designPreview(identity: candidate, authentication: authentication)
                return
            }
            #endif
            guard let connection else { throw V5IdentityError.invalid }
            let value = try await DevicePairingSession.newDevice(identity: candidate, authentication: authentication,
                verifier: verifier, connection: connection, requireClock: requireClock, configuration: configuration)
            guard self.authentication?.token == authentication.token, step == .authorize else { value.stop(); throw CancellationError() }
            pairing = value; existingDeviceRejected = false
        }
    }
    func pollPairing() async {
        guard let pairing, step == .authorize, !busy else { return }
        await pairing.poll()
        if self.pairing === pairing, pairing.completed, pairing.approval != nil, !pairingActivationAttempted {
            await completePairingLogin()
        }
    }
    func completePairingLogin() async {
        guard !busy, let pairing, pairing.completed, let approval = pairing.approval, let enrollment else { return }
        pairingActivationAttempted = true
        await perform {
            guard step == .authorize, pairing.request.accountKey == authentication?.accountKey else { throw V5IdentityError.changed }
            if enrollment.device == nil { try enrollment.acceptPairedDevice(approval, request: pairing.request, issuer: pairing.issuer) }
            guard enrollment.device == approval.device else { throw V5IdentityError.changed }
            try identity.saveEnrollmentCandidate(enrollment)
            try await finish()
        }
    }
    func stopPairing() { pairing?.stop(); pairing = nil; pairingActivationAttempted = false }
    func acceptApproval() async {
        await perform {
            guard step == .authorize, let authentication, !authentication.accountKey.isEmpty, let enrollment else { throw V5IdentityError.invalid }
            try enrollment.acceptDeviceApproval(approvalCode, expectedFingerprint: approvalFingerprint, expectedAccountKey: authentication.accountKey)
            try identity.saveEnrollmentCandidate(enrollment)
            try await finish()
        }
    }
    private func finish() async throws {
        try requireClock()
        guard let authentication, let connection else { throw V5IdentityError.invalid }
        let signingIdentity = enrollment ?? identity
        let expectedScope = scope
        if authentication.accountKey.isEmpty || pending != nil {
            guard var value = pending, value.confirmedDigest == value.digest else { throw IdentitySetupError.invalid("请先保存恢复文件并完成二次确认。") }
            value.submissionStarted = true; try storage.save(value, scope: scope); pending = value
        }
        try await bindChallenge(using: signingIdentity)
        try requireClock()
        let device = try signingIdentity.requireDevice()
        let message = V5Crypto.message("Chirp identity activation v1", [authentication.origin, authentication.accountID, ClientLoginRequest.clientID,
            V5Crypto.hash(Data(authentication.token.utf8)), V5Crypto.hash(Data(verifier.utf8)), challenge, device.accountKey, device.digest])
        struct Request: Encodable { let setup_token: String; let code_verifier: String; let device: V5Device; let signature: String; let device_name: String }
        let data: Data = try await IdentitySetupAPI.post("api/client/identity/complete", connection: connection,
            body: JSONEncoder().encode(Request(setup_token: authentication.token, code_verifier: verifier, device: device, signature: signingIdentity.signIdentityMessage(message), device_name: RecoveryFile.deviceName)), configuration: configuration)
        guard self.authentication?.token == authentication.token, identity.currentScope == expectedScope else { throw CancellationError() }
        try requireClock()
        let session = try ClientSession(data: data, connection: connection, expectedDevice: device)
        guard session.member.id == authentication.accountID else { throw V5IdentityError.wrongDevice }
        if signingIdentity === identity { try identity.markBound() }
        else { try identity.activateEnrollmentCandidate(signingIdentity) }
        try storage.remove(scope); pending = nil; step = .idle; enrollment = nil; pairing = nil
        password = ""; confirmation = ""; verifier = ""; rootSeed = nil; self.authentication = nil
        onComplete?(session)
    }
    func cancel() { stopPairing(); rootSeed = nil; password = ""; confirmation = ""; verifier = ""; authentication = nil; connection = nil; enrollment = nil; step = .idle }
    func reset() throws { cancel(); pending = nil; try storage.clear() }
    private func perform(_ operation: StaticString = #function, _ action: () async throws -> Void) async {
        guard !busy else { return }; busy = true; failure = nil; defer { busy = false }
        let span = ClientLog.shared.begin()
        ClientLog.shared.record(.identity, operation, outcome: .started)
        do {
            try requireClock()
            try await action()
            ClientLog.shared.finish(span, .identity, operation)
        } catch {
            ClientLog.shared.finish(span, .identity, operation, error: error)
            password = ""; confirmation = ""
            failure = error.localizedDescription
        }
    }

    #if DEBUG
    /// Isolated UI fixtures: no server connection or persistent device identity.
    static func designPreview(step: Step = .password, saved: Bool = false) async throws -> IdentitySetupController {
        let identity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let storage = PendingIdentityStorage(directory: FileManager.default.temporaryDirectory.appendingPathComponent("ChirpRecoveryPreview-" + UUID().uuidString))
        let setup = IdentitySetupController(identity: identity, storage: storage, requireClock: {})
        setup.designPreview = true
        try identity.select(origin: "https://chirp.example:443", accountID: "preview-account")
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let device = try identity.makeCandidate(rootSeed: seed)
        setup.authentication = AuthenticatedIdentitySetup(token: UUID().uuidString, accountID: "preview-account", username: "Youzi",
            origin: "https://chirp.example:443", accountKey: step == .authorize ? device.accountKey : "", expiresAt: Int64(Date().timeIntervalSince1970) + 300)
        setup.rootSeed = seed
        setup.step = .password
        if saved || step == .confirmation || step == .resume {
            setup.password = "Chirp recovery preview password"
            setup.confirmation = setup.password
            await setup.saveEncryptedFile()
            if saved || step == .confirmation { setup.exported(success: true) }
        }
        setup.step = step
        return setup
    }
    #endif
}
