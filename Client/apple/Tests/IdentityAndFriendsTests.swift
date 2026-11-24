import ChirpMLS
import CryptoKit
import Darwin
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
import UniformTypeIdentifiers
@testable import Chirp
#endif

private final class SetupURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var challenges = 0
        var completions = 0
        var device: V5Device?
        var failChallenges = false
        var failCompletions = false
    }
    static let state = Mutex(State())
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let data: Data
            if let body = request.httpBody { data = body }
            else if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }; data = bytes
            } else { throw URLError(.badServerResponse) }
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let device = try JSONDecoder().decode(V5Device.self, from: JSONSerialization.data(withJSONObject: body["device"]!))
            let challenge = String(repeating: "c", count: 43)
            let response: [String: Any]
            if request.url!.path.hasSuffix("challenge") {
                Self.state.withLock { $0.challenges += 1; $0.device = device }; response = ["challenge": challenge]
                if Self.state.withLock({ $0.failChallenges }) { throw URLError(.notConnectedToInternet) }
            } else {
                Self.state.withLock { $0.completions += 1 }
                let message = V5Crypto.message("Chirp identity activation v1", ["https://keys.example.test:443", "member_setup", ClientLoginRequest.clientID,
                    V5Crypto.hash(Data((body["setup_token"] as! String).utf8)), V5Crypto.hash(Data((body["code_verifier"] as! String).utf8)), challenge, device.accountKey, device.digest])
                try V5Crypto.verify(key: device.leafKey, signature: body["signature"] as! String, message: message)
                if Self.state.withLock({ $0.failCompletions }) { throw URLError(.networkConnectionLost) }
                response = ["member": ["id": "member_setup", "display_name": "Setup"], "credential": "chirp_" + String(repeating: "x", count: 43),
                    "expires_at": Date().timeIntervalSince1970 + 3600, "participant_identity": "member_setup.login_test", "device_identity": body["device"]!]
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: response)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct IdentityAndFriendsTests {
    @Test func blacklistPresentationGroupsUsersWithoutConfusingAccountAndDeviceKeys() {
        let records = [
            BlacklistRecord(sequence: 3, kind: "device", subject: "device-b", accountID: "member", accountKey: "root-a", username: "New name", createdAt: 300),
            BlacklistRecord(sequence: 1, kind: "account", subject: "member", accountID: "member", accountKey: "root-a", username: "Old name", createdAt: 100),
            BlacklistRecord(sequence: 4, kind: "device", subject: "device-c", accountID: "member", accountKey: "root-b", username: "Other root", createdAt: 400),
            BlacklistRecord(sequence: 2, kind: "device", subject: "device-a", accountID: "member", accountKey: "root-a", username: "Old name", createdAt: 200),
        ]
        let users = BlacklistedIdentity.grouped(records)
        #expect(users.count == 2 && Set(users.map(\.id)).count == 2)
        #expect(users[0].accountKey == "root-b" && !users[0].accountBlocked)
        #expect(users[1].accountBlocked && users[1].name == "New name")
        #expect(users[1].devices.map(\.subject) == ["device-a", "device-b"])
        #expect(BlacklistedIdentity.grouped([]).isEmpty)
        let accountOnly = BlacklistedIdentity.grouped([records[1]])
        #expect(accountOnly[0].accountBlocked && accountOnly[0].devices.isEmpty)
    }

    @Test func deviceTimestampsDecodeWithOlderServerCompatibility() throws {
        let fixture = try V5TestIdentity("device-timestamps")
        var payload: [String: Any] = [
            "device_key": fixture.device.leafKey, "account_id": "member_fixture", "account_key": fixture.device.accountKey,
            "device": try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.device)),
            "name": "My Mac", "platform": "macos", "created_at": 1700000000, "last_login_at": 1700000100, "revoked": false,
        ]
        func decode() throws -> RegisteredIdentityDevice {
            try JSONDecoder().decode(RegisteredIdentityDevice.self, from: JSONSerialization.data(withJSONObject: payload))
        }
        let device = try decode()
        #expect(device.createdAt == 1700000000 && device.lastLoginAt == 1700000100)
        payload["last_login_at"] = 0
        #expect(try decode().lastLoginAt == 0)
        payload.removeValue(forKey: "last_login_at")
        #expect(try decode().lastLoginAt == nil)
    }

    private func temporaryStorage() throws -> PendingIdentityStorage {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return PendingIdentityStorage(directory: directory)
    }
    private func authentication(root: String = "") -> AuthenticatedIdentitySetup {
        AuthenticatedIdentitySetup(token: "setup_" + UUID().uuidString, accountID: "member_setup", username: "Setup", origin: "https://keys.example.test:443", accountKey: root, expiresAt: Int64(Date().timeIntervalSince1970) + 300)
    }
    private func controller(_ identity: DeviceIdentityStore, storage: PendingIdentityStorage,
                            requireClock: @escaping @MainActor () throws -> Void = {}) -> IdentitySetupController {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [SetupURLProtocol.self]
        return IdentitySetupController(identity: identity, storage: storage, configuration: configuration, requireClock: requireClock)
    }
    @Test func clockChangesDuringLoginBlockSessionAcceptanceUntilCorrected() async throws {
        SetupURLProtocol.state.withLock { $0 = .init() }
        defer { SetupURLProtocol.state.withLock { $0 = .init() } }
        let identity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let auth = authentication()
        try identity.select(origin: auth.origin, accountID: auth.accountID)
        let device = try identity.makeCandidate(rootSeed: V5Crypto.random())
        try identity.markBound()
        let login = authentication(root: device.accountKey)
        let sample = NetworkTimeSample(utc: Date(), received: .now, roundTrip: .milliseconds(5))
        var correctAfterReply = false
        let clock = NetworkClock(wallNow: {
            let networkTime = sample.utc(at: .now)
            let receivedReply = SetupURLProtocol.state.withLock { $0.completions > 0 }
            return networkTime.addingTimeInterval(receivedReply && !correctAfterReply ? 30 : 0)
        }, query: { [sample] })
        let setup = controller(identity, storage: storage, requireClock: clock.requireReady)
        var accepted: ClientSession?
        setup.onComplete = { accepted = $0 }
        let verifier = String(repeating: "v", count: 43)
        await #expect(throws: ClientFailure(.networkTimeRequired)) {
            try await setup.begin(login, connection: testServerConnection, verifier: verifier)
        }
        #expect(SetupURLProtocol.state.withLock { $0.challenges } == 0)
        await clock.check()
        try await setup.begin(login, connection: testServerConnection, verifier: verifier)
        #expect(SetupURLProtocol.state.withLock { $0.completions } == 1)
        #expect(accepted == nil && !clock.isReadyNow())
        correctAfterReply = true
        try await setup.begin(login, connection: testServerConnection, verifier: verifier)
        #expect(accepted?.member.id == auth.accountID)
    }
    @Test func firstLoginCannotCommitBeforeExportAndForegroundConfirmation() async throws {
        SetupURLProtocol.state.withLock { $0 = .init() }
        let persistence = MemoryIdentityPersistence(); let identity = DeviceIdentityStore(persistence: persistence)
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(identity, storage: storage)
        var login: ClientSession?; setup.onComplete = { login = $0 }
        try await setup.begin(authentication(), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        #expect(setup.step == .password && identity.isEnrolled && !identity.isBound)
        #expect(SetupURLProtocol.state.withLock { $0.completions } == 0)
        setup.password = " random long password for backup 😀 "; setup.confirmation = setup.password
        await setup.saveEncryptedFile(); let record = try #require(setup.pending)
        #expect(!record.exported && record.confirmedDigest == nil)
        setup.exported(success: true, expectedScope: "https://other.test:443|other", expectedDigest: record.digest)
        setup.exported(success: true, expectedScope: setup.scope, expectedDigest: "another-file")
        #expect(setup.pending?.exported == false)
        setup.showConfirmation(); #expect(setup.step == .password)
        setup.exported(success: false); setup.showConfirmation(); #expect(setup.step == .password)
        setup.exported(success: true); setup.showConfirmation(); await setup.confirmBackup()
        #expect(SetupURLProtocol.state.withLock { $0.completions } == 0)
        setup.backToSave(); setup.showConfirmation(); #expect(setup.clock.remaining() == 5)
        setup.clock.setVisible(false, now: .now.advanced(by: .seconds(5)))
        await setup.confirmBackup()
        #expect(login?.member.id == "member_setup" && identity.isBound && setup.pending == nil)
        #expect(try storage.load(record.origin + "|" + record.accountID) == nil)
        #expect(SetupURLProtocol.state.withLock { $0.completions } == 1)
    }
    @Test func interruptedBackupResumesSameRootAndCiphertext() async throws {
        SetupURLProtocol.state.withLock { $0 = .init() }
        let persistence = MemoryIdentityPersistence(); let identity = DeviceIdentityStore(persistence: persistence)
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(identity, storage: storage)
        try await setup.begin(authentication(), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        setup.password = "long random backup password"; setup.confirmation = setup.password
        await setup.saveEncryptedFile(); let record = try #require(setup.pending)
        setup.cancel()
        let reloaded = DeviceIdentityStore(persistence: persistence); let resumed = controller(reloaded, storage: storage)
        try await resumed.begin(authentication(), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        #expect(resumed.step == .resume && resumed.pending?.file == record.file)
        resumed.password = "long random backup password"; await resumed.resume()
        #expect(resumed.step == .password && resumed.pending?.rootKey == record.rootKey && resumed.pending?.device == record.device)
        let root = try await RecoveryFile.decrypt(record.file, password: "long random backup password")
        #expect(!String(decoding: try #require(persistence.data), as: UTF8.self).contains(root.rootSeed))
        resumed.exported(success: true)
        resumed.backToSave()
        #expect(resumed.pending?.file == record.file && resumed.pending?.rootKey == record.rootKey)
        #expect(try await RecoveryFile.decrypt(try #require(resumed.pending).file, password: "long random backup password").rootPublicKey == root.rootPublicKey)
    }
    @Test func backupVerificationCanRetryWithoutConfirmingOrReplacingTheSavedFile() async throws {
        SetupURLProtocol.state.withLock { $0 = .init() }
        let identity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(identity, storage: storage)
        try await setup.begin(authentication(), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        let password = "long random backup password"
        setup.password = password; setup.confirmation = password
        await setup.saveEncryptedFile()
        let record = try #require(setup.pending)
        setup.exported(success: true)

        setup.password = "wrong password"
        await setup.verifyBackup(record.file)
        #expect(!setup.backupVerified && setup.failure != nil && setup.password.isEmpty)
        #expect(setup.pending?.exported == true && setup.pending?.confirmedDigest == nil)

        setup.password = password
        await setup.verifyBackup(record.file)
        #expect(setup.backupVerified && setup.failure == nil && setup.password.isEmpty)
        #expect(setup.pending?.file == record.file && setup.pending?.rootKey == record.rootKey)
        #expect(SetupURLProtocol.state.withLock { $0.completions } == 0)

        setup.password = "wrong password"
        await setup.verifyBackup(record.file)
        #expect(!setup.backupVerified && setup.failure != nil)
        #expect(setup.pending?.exported == true && setup.pending?.confirmedDigest == nil)
    }
    @Test func recoveryIsPlatformIndependentAndBoundToAccountAndOrigin() async throws {
        #expect(RecoveryFile.filename(username: "Fixture").hasSuffix("_\(RecoveryFile.platform).chirpkey"))
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        var payload = RecoveryPayload(rootSeed: seed.base64EncodedString(), rootPublicKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString(), serviceOrigin: "https://fixture.test:443", accountID: "member_fixture", username: "Fixture", createdAt: "2026-11-17T00:00:00Z", sourcePlatform: "iOS")
        for platform in ["iOS", "macOS"] {
            payload.sourcePlatform = platform
            let file = try await RecoveryFile.encrypt(payload, password: "random password with emoji 😀", confirmation: "random password with emoji 😀")
            #expect(file.starts(with: "CHIRPKEY".utf8))
            let recovered = try await RecoveryFile.decrypt(file, password: "random password with emoji 😀")
            try recovered.validate(origin: payload.serviceOrigin, accountID: payload.accountID, root: payload.rootPublicKey)
            #expect(recovered.rootSeed == payload.rootSeed)
            #expect(throws: (any Error).self) { try recovered.validate(origin: "https://other.test:443", accountID: payload.accountID, root: payload.rootPublicKey) }
            #expect(throws: (any Error).self) { try recovered.validate(origin: payload.serviceOrigin, accountID: "member_other", root: payload.rootPublicKey) }
        }
        #expect(throws: (any Error).self) { try RecoveryFile.validatePassword("éabcdefghijklmnop", confirmation: "e\u{301}abcdefghijklmnop") }
        #expect(throws: (any Error).self) { try RecoveryFile.validatePassword("123456789012345", confirmation: "123456789012345") }
        try RecoveryFile.validatePassword(" 123456789012345 ", confirmation: " 123456789012345 ")
    }
    #if !SWIFT_PACKAGE
    @Test func systemRecoveryDocumentTypeUsesChirpkey() throws {
        let declarations = try #require(Bundle.main.object(forInfoDictionaryKey: "UTExportedTypeDeclarations") as? [[String: Any]])
        let recovery = try #require(declarations.first { $0["UTTypeIdentifier"] as? String == UTType.chirpRecovery.identifier })
        let tags = try #require(recovery["UTTypeTagSpecification"] as? [String: Any])
        #expect(tags["public.filename-extension"] as? [String] == ["chirpkey"])
        #expect(UTType.chirpRecovery.preferredFilenameExtension == "chirpkey")
    }
    #endif
    @Test func recoveryFileKDFOnTargetHardware() async throws {
        // Public fixture only. Keep the same parameters on every actual target;
        // report process peak RSS, not a claim about isolated KDF allocations.
        let seed = Data(repeating: 7, count: 32)
        let payload = RecoveryPayload(rootSeed: seed.base64EncodedString(),
            rootPublicKey: try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString(),
            serviceOrigin: "https://fixture.test:443", accountID: "member_measurement", username: "Fixture",
            createdAt: "2026-11-17T00:00:00Z", sourcePlatform: RecoveryFile.platform)
        let start = ContinuousClock.now
        let file = try await RecoveryFile.encrypt(payload, password: "public measurement password", confirmation: "public measurement password")
        let encryption = start.duration(to: .now)
        let decryptionStart = ContinuousClock.now
        let recovered = try await RecoveryFile.decrypt(file, password: "public measurement password")
        let decryption = decryptionStart.duration(to: .now)
        #expect(recovered.rootPublicKey == payload.rootPublicKey)
        var usage = rusage(); #expect(getrusage(RUSAGE_SELF, &usage) == 0)
        print("CHIRPKEY v1 hardware: platform=\(RecoveryFile.platform), OS=\(ProcessInfo.processInfo.operatingSystemVersionString), Argon2id=65536KiB/3/4, encrypt+self-test=\(encryption), decrypt=\(decryption), process-peak-RSS-bytes=\(usage.ru_maxrss)")
    }
    @Test func confirmationCountsOnlyMonotonicForegroundTimeAndReentryRestarts() {
        let start = ContinuousClock.now; var clock = BackupConfirmationClock()
        clock.setVisible(true, now: start); #expect(clock.remaining(now: start.advanced(by: .seconds(2))) == 3)
        clock.setVisible(false, now: start.advanced(by: .seconds(2)))
        #expect(clock.remaining(now: start.advanced(by: .seconds(120))) == 3)
        clock.setVisible(true, now: start.advanced(by: .seconds(120)))
        #expect(clock.remaining(now: start.advanced(by: .seconds(122))) == 1)
        #expect(clock.remaining(now: start.advanced(by: .seconds(123))) == 0)
        clock = BackupConfirmationClock(); #expect(clock.remaining(now: start.advanced(by: .seconds(200))) == 5)
    }
    @Test func scopedDeviceMaterialsDoNotFollowUsernamesOrAnotherServer() throws {
        let disk = MemoryIdentityPersistence(); let identity = DeviceIdentityStore(persistence: disk)
        try identity.select(origin: "https://a.test:443", accountID: "member_a")
        let a = try identity.makeCandidate(rootSeed: Curve25519.Signing.PrivateKey().rawRepresentation)
        try identity.select(origin: "https://a.test:443", accountID: "member_b"); #expect(!identity.isEnrolled)
        _ = try identity.makeCandidate(rootSeed: Curve25519.Signing.PrivateKey().rawRepresentation)
        try identity.select(origin: "https://b.test:443", accountID: "member_a"); #expect(!identity.isEnrolled)
        let restored = DeviceIdentityStore(persistence: disk); try restored.select(origin: "https://a.test:443", accountID: "member_a")
        #expect(try restored.requireDevice() == a)
        try restored.clearAll(); #expect(disk.data == nil && !restored.isEnrolled)
    }

    @Test(arguments: [true, false])
    func failedRecoveryPreservesAndRetriesHealthyDevice(failChallenge: Bool) async throws {
        SetupURLProtocol.state.withLock { $0 = .init(failChallenges: failChallenge, failCompletions: !failChallenge) }
        defer { SetupURLProtocol.state.withLock { $0 = .init() } }
        let disk = MemoryIdentityPersistence()
        let healthy = DeviceIdentityStore(persistence: disk)
        let auth = authentication()
        try healthy.select(origin: auth.origin, accountID: auth.accountID)
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let original = try healthy.makeCandidate(rootSeed: seed); try healthy.markBound()
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(healthy, storage: storage)
        try await setup.begin(authentication(root: original.accountKey), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        #expect(setup.step == .authorize)
        let password = "public recovery test password"
        let payload = RecoveryPayload(rootSeed: seed.base64EncodedString(), rootPublicKey: original.accountKey, serviceOrigin: auth.origin, accountID: auth.accountID, username: auth.username, createdAt: "2026-11-17T00:00:00Z", sourcePlatform: "macOS")
        let file = try await RecoveryFile.encrypt(payload, password: password, confirmation: password)
        setup.password = password; await setup.importRecovery(file)
        #expect(setup.failure != nil && healthy.device == original && healthy.isBound)
        let reloaded = DeviceIdentityStore(persistence: disk)
        try reloaded.select(origin: auth.origin, accountID: auth.accountID)
        #expect(reloaded.device == original && reloaded.isBound)
        SetupURLProtocol.state.withLock { $0.failChallenges = false; $0.failCompletions = false }
        setup.password = password; await setup.importRecovery(file)
        #expect(setup.step == .idle && healthy.device == original && healthy.isBound)
        #expect(SetupURLProtocol.state.withLock { $0.device } == original)
    }

    @Test func failedReplacementEnrollmentKeepsActiveKeyAndResumesCandidateAfterRestart() async throws {
        SetupURLProtocol.state.withLock { $0 = .init(failCompletions: true) }
        defer { SetupURLProtocol.state.withLock { $0 = .init() } }
        let disk = MemoryIdentityPersistence(), identity = DeviceIdentityStore(persistence: disk)
        let auth = authentication()
        try identity.select(origin: auth.origin, accountID: auth.accountID)
        _ = try identity.makeCandidate(rootSeed: Curve25519.Signing.PrivateKey().rawRepresentation); try identity.markBound()
        let original = try identity.requireDevice()
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(identity, storage: storage)
        try await setup.begin(authentication(root: original.accountKey), connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        setup.prepareEnrollment()
        #expect(identity.device == original && identity.isBound)
        #expect(setup.enrollmentDeviceFingerprint != identity.deviceFingerprint)
        setup.approvalCode = try identity.approveDevice(setup.enrollmentRequest, expectedDeviceFingerprint: setup.enrollmentDeviceFingerprint, canEnroll: true)
        setup.approvalFingerprint = identity.fingerprint
        await setup.acceptApproval()
        #expect(setup.failure != nil && identity.device == original && identity.isBound)
        let candidate = try identity.enrollmentCandidate().requireDevice()
        #expect(candidate.accountKey == original.accountKey && candidate.leafKey != original.leafKey)
        setup.cancel()
        let restored = DeviceIdentityStore(persistence: disk)
        try restored.select(origin: auth.origin, accountID: auth.accountID)
        #expect(restored.device == original && restored.isBound)
        #expect(try restored.enrollmentCandidate().requireDevice() == candidate)
        SetupURLProtocol.state.withLock { $0.failCompletions = false }
        let resumed = controller(restored, storage: storage)
        try await resumed.begin(authentication(root: original.accountKey), connection: testServerConnection, verifier: String(repeating: "w", count: 43))
        #expect(resumed.step == .idle && restored.device == candidate && restored.isBound)
        #expect(try restored.enrollmentCandidate().device == nil)
    }

    @Test func newDeviceRecoveryResumesSameCandidateAfterActivationReplyIsLost() async throws {
        SetupURLProtocol.state.withLock { $0 = .init(failCompletions: true) }
        defer { SetupURLProtocol.state.withLock { $0 = .init() } }
        let disk = MemoryIdentityPersistence(), identity = DeviceIdentityStore(persistence: disk)
        let seed = Curve25519.Signing.PrivateKey().rawRepresentation
        let root = try Curve25519.Signing.PrivateKey(rawRepresentation: seed).publicKey.rawRepresentation.base64EncodedString()
        let auth = authentication(root: root)
        let storage = try temporaryStorage(); defer { try? storage.clear() }
        let setup = controller(identity, storage: storage)
        try await setup.begin(auth, connection: testServerConnection, verifier: String(repeating: "v", count: 43))
        let password = "public recovered device password"
        let payload = RecoveryPayload(rootSeed: seed.base64EncodedString(), rootPublicKey: root, serviceOrigin: auth.origin, accountID: auth.accountID, username: auth.username, createdAt: "2026-11-17T00:00:00Z", sourcePlatform: "iOS")
        let file = try await RecoveryFile.encrypt(payload, password: password, confirmation: password)
        setup.password = password; await setup.importRecovery(file)
        #expect(setup.failure != nil && !identity.isEnrolled && setup.password.isEmpty)
        let candidate = try identity.enrollmentCandidate().requireDevice()
        #expect(candidate.accountKey == root)
        #expect(!String(decoding: try #require(disk.data), as: UTF8.self).contains(payload.rootSeed))
        setup.cancel()
        SetupURLProtocol.state.withLock { $0.failCompletions = false }
        let restored = DeviceIdentityStore(persistence: disk)
        let retry = controller(restored, storage: storage)
        try await retry.begin(authentication(root: root), connection: testServerConnection, verifier: String(repeating: "w", count: 43))
        #expect(retry.step == .idle && restored.device == candidate && restored.isBound)
        #expect(try restored.enrollmentCandidate().device == nil)
    }
}

final class IdentityBusURLProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var accounts: [String: (String, V5Device)] = [:]
        var events: [String: [SocialIdentityEvent]] = [:]
        var authorization: [String: AuthorizationAccount] = [:]
        var signals: [(Int64, IdentitySignal)] = []
        var blacklist: [BlacklistRecord] = []
        var rejectWrites = false
        var rejectTrustWrites = false
        var redactFirstSocial = false
        var holdSocialReads = false
        var heldSocialRead: IdentityBusURLProtocol?
    }
    static let state = Mutex(State())
    static let authorityKey = Data(repeating: 9, count: 32)
    static var authorityConfiguration: AuthorizationConfiguration {
        AuthorizationConfiguration(origin: "https://keys.example.test:443", url: URL(string: "https://keys.example.test/authorization")!,
            publicKey: try! Curve25519.Signing.PrivateKey(rawRepresentation: authorityKey).publicKey.rawRepresentation.base64EncodedString())
    }
    static func register(_ fixture: V5TestIdentity) throws {
        var event = AuthorizationEvent(origin: authorityConfiguration.origin, version: 1, previousHash: "", operation: "enroll", signer: fixture.device)
        event.signature = try V5Crypto.sign(fixture.key, event.message)
        let account = AuthorizationAccount(root: fixture.device.accountKey, records: [AuthorizationRecord(event: event, acceptedAt: Int64(Date().timeIntervalSince1970))])
        state.withLock { $0.authorization[account.root] = account }
    }
    private func body() throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { throw URLError(.badServerResponse) }
        stream.open(); defer { stream.close() }
        var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }
        return bytes
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let response: Data? = try Self.state.withLock { state in
                if request.url!.path == "/authorization/v5/snapshot" {
                    if state.holdSocialReads { state.heldSocialRead = self; return nil }
                    struct Request: Decodable { let origin: String; let nonce: String; let roots: [String] }
                    let input = try JSONDecoder().decode(Request.self, from: body())
                    let payload = try JSONEncoder().encode(AuthorizationSnapshot(protocol: 5, origin: input.origin, nonce: input.nonce,
                        issuedAt: Int64(Date().timeIntervalSince1970), accounts: input.roots.map { root in
                            let account = state.authorization[root] ?? AuthorizationAccount(root: root, records: [])
                            guard state.redactFirstSocial else { return account }
                            var redacted = false
                            return AuthorizationAccount(root: root, records: account.records.map { record in
                                var event = record.event
                                if !redacted, let social = event.social {
                                    event.socialHash = social.digest; event.social = nil; redacted = true
                                }
                                return AuthorizationRecord(event: event, acceptedAt: record.acceptedAt)
                            })
                        }))
                    let signature = try V5Crypto.sign(Self.authorityKey, V5Crypto.message("Chirp authorization snapshot v5", [input.origin, input.nonce, V5Crypto.hash(payload)]))
                    return try JSONEncoder().encode(AuthorizationEnvelope(payload: payload.base64EncodedString(), signature: signature))
                }
                if request.url!.path == "/authorization/v5/append" {
                    if state.rejectWrites { throw URLError(.notConnectedToInternet) }
                    let event = try JSONDecoder().decode(AuthorizationEvent.self, from: body())
                    if state.rejectTrustWrites && event.social?.operation == "trust" { throw URLError(.notConnectedToInternet) }
                    let records = (state.authorization[event.signer.accountKey]?.records ?? []) + [AuthorizationRecord(event: event, acceptedAt: Int64(Date().timeIntervalSince1970))]
                    let account = AuthorizationAccount(root: event.signer.accountKey, records: records)
                    _ = try AuthorizedAccount.verify(account, origin: Self.authorityConfiguration.origin, issuedAt: Int64(Date().timeIntervalSince1970), previous: nil)
                    state.authorization[account.root] = account
                    if let social = event.social { state.events[social.accountID, default: []].append(social) }
                    return Data()
                }
                let token = String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
                guard let (accountID, device) = state.accounts[token] else { throw URLError(.userAuthenticationRequired) }
                let path = request.url!.path
                if path.hasSuffix("blacklist") { return try JSONEncoder().encode(state.blacklist) }
                if path.hasSuffix("devices") {
                    return try JSONSerialization.data(withJSONObject: [["device_key": device.leafKey, "account_id": accountID, "account_key": device.accountKey,
                        "device": JSONSerialization.jsonObject(with: JSONEncoder().encode(device)), "name": "Fixture", "platform": "macos", "created_at": Int(Date().timeIntervalSince1970), "revoked": false]])
                }
                if request.httpMethod == "POST" {
                    if state.rejectWrites { throw URLError(.notConnectedToInternet) }
                    let data: Data
                    if let body = request.httpBody { data = body }
                    else if let stream = request.httpBodyStream {
                        stream.open(); defer { stream.close() }; var bytes = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
                        while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; bytes.append(contentsOf: buffer.prefix(count)) }; data = bytes
                    } else { throw URLError(.badServerResponse) }
                    if path.hasSuffix("social") {
                        let event = try JSONDecoder().decode(SocialIdentityEvent.self, from: data)
                        try V5Crypto.verify(key: device.leafKey, signature: event.signature, message: event.message)
                        var events = state.events[accountID] ?? []
                        guard event.version == Int64(events.count + 1) else { throw URLError(.badServerResponse) }
                        events.append(event); state.events[accountID] = events
                    } else {
                        let signal = try JSONDecoder().decode(IdentitySignal.self, from: data)
                        try V5Crypto.verify(key: device.leafKey, signature: signal.signature, message: signal.message)
                        state.signals.append((Int64(state.signals.count + 1), signal))
                    }
                    return Data()
                }
                let after = Int64(path.split(separator: "/").last!)!
                if path.contains("/social/") {
                    if state.holdSocialReads { state.heldSocialRead = self; return nil }
                    return try JSONEncoder().encode((state.events[accountID] ?? []).filter { $0.version > after })
                }
                let signals = state.signals.filter { $0.0 > after && $0.1.recipient == accountID }
                return try JSONSerialization.data(withJSONObject: signals.map { sequence, signal in ["sequence": sequence, "signal": try JSONSerialization.jsonObject(with: JSONEncoder().encode(signal))] })
            }
            if let response { deliver(response) }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    func deliver(_ response: Data) {
        let status = request.httpMethod == "POST" && request.url?.path != "/authorization/v5/snapshot" ? 204 : 200
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: response); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor private func identityCondition(_ predicate: () -> Bool, line: UInt = #line) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(20))
    while !predicate() { guard ContinuousClock.now < deadline else { throw NSError(domain: "Identity integration condition", code: Int(line)) }; try await Task.sleep(for: .milliseconds(10)) }
}
@MainActor private final class IdentityRekeyGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@MainActor private final class VerificationGate {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func waitOnce() async {
        guard !entered else { return }
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

@Suite(.serialized) @MainActor struct MutualIdentityIntegrationTests {
    private func configuration() -> URLSessionConfiguration { let c = URLSessionConfiguration.ephemeral; c.protocolClasses = [IdentityBusURLProtocol.self]; return c }
    private func session(_ id: String, fixture: V5TestIdentity, token: String) throws -> ClientSession {
        try ClientSession(data: JSONSerialization.data(withJSONObject: ["member": ["id": id, "display_name": id], "credential": token,
            "participant_identity": id + ".login_test", "expires_at": Date().timeIntervalSince1970 + 3600,
            "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.device))]), connection: testServerConnection, expectedDevice: fixture.device)
    }
    @Test(arguments: ["timeout", "failure", "room-change"])
    func interruptedVerificationKeepsAnExplanationWithoutTrustingTheDevice(interruption: String) async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let a = try V5TestIdentity("interrupted-a"), b = try V5TestIdentity("interrupted-b")
        try IdentityBusURLProtocol.register(a); try IdentityBusURLProtocol.register(b)
        let store = try testIdentityStore("interrupted-a", fixture: a)
        let token = "chirp_" + String(repeating: "a", count: 43)
        IdentityBusURLProtocol.state.withLock { $0.accounts[token] = ("member_a", a.device) }
        let login = try session("member_a", fixture: a, token: token)
        let social = SocialIdentity(identity: store, persistence: MemoryIdentityPersistence(), configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        social.reset(for: login); defer { social.reset(for: nil) }
        try await identityCondition { social.voiceAllowed }
        let room = RoomIdentity(identity: store, social: social, configuration: configuration(),
            verificationTimeout: interruption == "timeout" ? .milliseconds(50) : .seconds(120), security: { native, parameters in
                if interruption == "failure", parameters["action"] == "sas_start" { throw URLError(.notConnectedToInternet) }
                return try await native.security(parameters)
            })
        defer { room.end() }
        let policy = V5RoomPolicy.mutual(origin: "https://keys.example.test:443", roomID: "friends")
        let entryA = login.participantIdentity + ".entry_a", entryB = "member_b.login_test.entry_b"
        let peerA = MLSPeer(identity: entryA, name: "A", publicKey: a.device.leafKey, keyPackage: "", binding: try a.binding(policy: policy, identity: entryA, mlsKey: a.device.leafKey))
        let peerB = MLSPeer(identity: entryB, name: "B", publicKey: b.device.leafKey, keyPackage: "", binding: try b.binding(policy: policy, identity: entryB, mlsKey: b.device.leafKey))
        room.begin(login: login, admission: RoomAdmission(roomID: "friends", entryID: "entry_a", identity: entryA))
        try room.updateRoster([peerA, peerB])
        room.presentVerification(peerB)
        let presentationID = try #require(room.verificationPresentation?.id)
        await room.startVerification(peerB)
        if interruption == "room-change" { try room.updateRoster([peerA]) }
        try await identityCondition { room.verification == nil }
        #expect(room.verificationPresentation?.id == presentationID)
        switch interruption {
        case "timeout": #expect(room.verificationPresentation?.phase == .ended(.timedOut))
        case "room-change":
            #expect(room.verificationPresentation?.phase == .ended(.roomChanged))
            #expect(!room.canVerify(peerB))
        default:
            #expect(room.failure != nil)
            #expect(room.verificationPresentation?.phase == .ended(.failed(URLError(.notConnectedToInternet).localizedDescription)))
        }
        #expect(!social.trusts(accountID: "member_b", device: b.device))
        room.dismissVerification()
        #expect(room.verificationPresentation == nil)
    }
    @Test(arguments: ["sas_start", "sas_accept"], ["cancel", "leave", "rejoin"])
    func lateVerificationResultCannotRestoreOrReplaceADismissedSheet(action: String, interruption: String) async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let a = try V5TestIdentity("late-sas-a"), b = try V5TestIdentity("late-sas-b")
        try IdentityBusURLProtocol.register(a); try IdentityBusURLProtocol.register(b)
        let store = try testIdentityStore("late-sas-a", fixture: a)
        let token = "chirp_" + String(repeating: "a", count: 43)
        IdentityBusURLProtocol.state.withLock { $0.accounts[token] = ("member_a", a.device) }
        let login = try session("member_a", fixture: a, token: token)
        let social = SocialIdentity(identity: store, persistence: MemoryIdentityPersistence(), configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        social.reset(for: login); defer { social.reset(for: nil) }
        try await identityCondition { social.voiceAllowed }
        let gate = VerificationGate(); defer { gate.release() }
        let room = RoomIdentity(identity: store, social: social, configuration: configuration(), security: { native, parameters in
            let data = try await native.security(parameters)
            if parameters["action"] == action { await gate.waitOnce() }
            return data
        })
        defer { room.end() }
        let policy = V5RoomPolicy.mutual(origin: "https://keys.example.test:443", roomID: "friends")
        let remoteID = "member_b.login_test.entry_b"
        let peerB = MLSPeer(identity: remoteID, name: "朋友 B 😀", publicKey: b.device.leafKey, keyPackage: "", binding: try b.binding(policy: policy, identity: remoteID, mlsKey: b.device.leafKey))
        func join(_ entryID: String) throws {
            let entry = login.participantIdentity + "." + entryID
            let peerA = MLSPeer(identity: entry, name: "A", publicKey: a.device.leafKey, keyPackage: "", binding: try a.binding(policy: policy, identity: entry, mlsKey: a.device.leafKey))
            room.begin(login: login, admission: RoomAdmission(roomID: "friends", entryID: entryID, identity: entry))
            try room.updateRoster([peerA, peerB])
        }
        try join("entry_a")
        if action == "sas_accept" {
            let message = String(decoding: try JSONSerialization.data(withJSONObject: ["kind": "Request", "commitment": V5Crypto.hash(Data("commitment".utf8))]), as: UTF8.self)
            let payload = String(decoding: try JSONSerialization.data(withJSONObject: ["transaction": "incoming-sas", "message": message]), as: UTF8.self)
            var signal = IdentitySignal(id: "incoming-signal", origin: policy.origin, roomID: policy.roomID, sender: "member_b", recipient: "member_a",
                senderEntry: remoteID, recipientEntry: login.participantIdentity + ".entry_a", kind: "sas", payload: payload,
                expiresAt: Int64(Date().timeIntervalSince1970) + 120, device: b.device)
            signal.signature = try V5Crypto.sign(b.key, signal.message)
            IdentityBusURLProtocol.state.withLock { $0.signals.append((1, signal)) }
            try await identityCondition { room.verification != nil }
        }
        let pending = Task {
            if action == "sas_start" { await room.startVerification(peerB) }
            else { await room.acceptVerification() }
        }
        try await identityCondition { gate.entered }
        if interruption == "cancel" { room.cancelVerification() }
        else { room.end() }
        #expect(room.verification == nil)
        if interruption == "rejoin" { try join("entry_new") }
        var replacementID: String?
        if interruption != "leave" {
            await room.startVerification(peerB)
            replacementID = try #require(room.verification?.id)
        }
        gate.release(); await pending.value
        #expect(room.verification?.id == replacementID && room.failure == nil)
        #expect(!social.trusts(accountID: "member_b", device: b.device))
        room.cancelVerification()
        #expect(room.verification == nil)
    }
    @Test func redactedOwnHistoryCannotReplaceTrustOrRenewAuthorization() async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let own = try V5TestIdentity("private-own"), friend = try V5TestIdentity("private-friend")
        try IdentityBusURLProtocol.register(own); try IdentityBusURLProtocol.register(friend)
        let identity = try testIdentityStore("private-own", fixture: own)
        let token = "chirp_" + String(repeating: "p", count: 43)
        IdentityBusURLProtocol.state.withLock { $0.accounts[token] = ("member_own", own.device) }
        let login = try session("member_own", fixture: own, token: token)
        let social = SocialIdentity(identity: identity, persistence: MemoryIdentityPersistence(), configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        social.reset(for: login); defer { social.reset(for: nil) }
        try await identityCondition { social.voiceAllowed && !social.isRefreshing }
        await social.change(operation: "trust", friendID: "member_friend", device: friend.device, name: "Friend")
        await social.change(operation: "friend", friendID: "member_friend", device: friend.device, name: "Private name")
        let deadline = try #require(social.sendingDeadline)
        #expect(social.friends.first?.trustedDevices.contains(friend.device.leafKey) == true)
        IdentityBusURLProtocol.state.withLock { $0.redactFirstSocial = true }
        await social.refresh()
        #expect(social.failure != nil)
        #expect(social.sendingDeadline == deadline)
        #expect(social.friends.first?.name == "Private name")
        #expect(social.friends.first?.trustedDevices.contains(friend.device.leafKey) == true)
    }

    @Test func joiningPeerDuringARefreshSchedulesItsOwnSignedSnapshot() async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let own = try V5TestIdentity("overlap-own"), other = try V5TestIdentity("overlap-peer")
        try IdentityBusURLProtocol.register(own); try IdentityBusURLProtocol.register(other)
        let identity = try testIdentityStore("overlap-own", fixture: own)
        let login = try session("member_own", fixture: own, token: "chirp_" + String(repeating: "o", count: 43))
        IdentityBusURLProtocol.state.withLock { $0.accounts[login.credential] = (login.member.id, own.device) }
        let social = SocialIdentity(identity: identity, persistence: MemoryIdentityPersistence(), configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        social.reset(for: login); defer { social.reset(for: nil) }
        try await identityCondition { social.voiceAllowed && !social.isRefreshing }
        IdentityBusURLProtocol.state.withLock { $0.holdSocialReads = true }
        let refresh = Task { await social.refresh() }
        try await identityCondition { IdentityBusURLProtocol.state.withLock { $0.heldSocialRead != nil } }
        let policy = V5RoomPolicy.mutual(origin: IdentityBusURLProtocol.authorityConfiguration.origin, roomID: "friends")
        let entry = "member_peer.login_test.entry_b"
        let peer = MLSPeer(identity: entry, name: "Peer", publicKey: other.device.leafKey, keyPackage: "",
            binding: try other.binding(policy: policy, identity: entry, mlsKey: other.device.leafKey))
        social.observe([peer])
        #expect(!social.deviceAuthorized(other.device))
        let held = IdentityBusURLProtocol.state.withLock { state in
            state.holdSocialReads = false
            defer { state.heldSocialRead = nil }
            return state.heldSocialRead
        }
        held?.startLoading(); await refresh.value
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !social.deviceAuthorized(other.device), .now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(social.deviceAuthorized(other.device))
        #expect(!social.trusts(accountID: "member_peer", device: other.device))
    }

    @Test(arguments: ["remove_friend", "untrust"])
    func revocationDuringSocialReadCannotBeOverwritten(operation: String) async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let own = try V5TestIdentity("inflight-own"), friend = try V5TestIdentity("inflight-friend")
        try IdentityBusURLProtocol.register(own); try IdentityBusURLProtocol.register(friend)
        let identity = try testIdentityStore("inflight-own", fixture: own)
        let token = "chirp_" + String(repeating: "r", count: 43)
        IdentityBusURLProtocol.state.withLock { $0.accounts[token] = ("member_own", own.device) }
        let login = try session("member_own", fixture: own, token: token)
        let disk = MemoryIdentityPersistence()
        let social = SocialIdentity(identity: identity, persistence: disk, configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        social.reset(for: login); defer { social.reset(for: nil) }
        try await identityCondition { social.voiceAllowed }
        await social.change(operation: "trust", friendID: "member_friend", device: friend.device, name: "Friend")
        try await identityCondition { social.trusts(accountID: "member_friend", device: friend.device) && !social.isRefreshing }
        IdentityBusURLProtocol.state.withLock { $0.holdSocialReads = true }
        let refresh = Task { await social.refresh() }
        try await identityCondition { IdentityBusURLProtocol.state.withLock { $0.heldSocialRead != nil } }
        await social.change(operation: operation, friendID: "member_friend", device: friend.device, name: "Friend")
        #expect(!social.trusts(accountID: "member_friend", device: friend.device))
        let held = IdentityBusURLProtocol.state.withLock { state in
            let held = state.heldSocialRead; state.heldSocialRead = nil; state.holdSocialReads = false; return held
        }
        held?.startLoading(); await refresh.value
        #expect(!social.trusts(accountID: "member_friend", device: friend.device))
        #expect(IdentityBusURLProtocol.state.withLock { $0.events["member_own"]?.last?.operation } == operation)
        #expect(social.socialVersion == 2)
        let restored = SocialIdentity(identity: identity, persistence: disk, configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        restored.reset(for: login); defer { restored.reset(for: nil) }
        try await identityCondition { restored.voiceAllowed }
        #expect(!restored.trusts(accountID: "member_friend", device: friend.device))
    }
    @Test func thirdParticipantGetsBusyAndCanReinviteAfterTrustSyncs() async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let policy = V5RoomPolicy.mutual(origin: IdentityBusURLProtocol.authorityConfiguration.origin, roomID: "friends")
        typealias Participant = (room: RoomIdentity, peer: MLSPeer, fixture: V5TestIdentity)
        func participant(_ name: String) throws -> Participant {
            let fixture = try V5TestIdentity("busy-" + name)
            try IdentityBusURLProtocol.register(fixture)
            let login = try session("member_" + name, fixture: fixture, token: "chirp_" + String(repeating: name, count: 43))
            IdentityBusURLProtocol.state.withLock { $0.accounts[login.credential] = (login.member.id, fixture.device) }
            let store = try testIdentityStore(name, fixture: fixture)
            let social = SocialIdentity(identity: store, persistence: MemoryIdentityPersistence(), configuration: configuration(),
                                        authority: IdentityBusURLProtocol.authorityConfiguration)
            social.reset(for: login)
            let entryID = "entry_" + name, entry = login.participantIdentity + "." + entryID
            let peer = MLSPeer(identity: entry, name: name, publicKey: fixture.device.leafKey, keyPackage: "",
                               binding: try fixture.binding(policy: policy, identity: entry, mlsKey: fixture.device.leafKey))
            let room = RoomIdentity(identity: store, social: social, configuration: configuration())
            room.begin(login: login, admission: RoomAdmission(roomID: policy.roomID, entryID: entryID, identity: entry))
            return (room, peer, fixture)
        }
        func deliver(_ packet: [String: String], from sender: Participant, to recipient: Participant, transaction: String) throws {
            let message = String(decoding: try JSONEncoder().encode(packet), as: UTF8.self)
            let payload = String(decoding: try JSONEncoder().encode(["transaction": transaction, "message": message]), as: UTF8.self)
            var signal = IdentitySignal(id: V5Crypto.random().base64EncodedString(), origin: policy.origin, roomID: policy.roomID,
                sender: MemberProfile.memberID(for: sender.peer.identity), recipient: MemberProfile.memberID(for: recipient.peer.identity),
                senderEntry: sender.peer.identity, recipientEntry: recipient.peer.identity, kind: "sas", payload: payload,
                expiresAt: Int64(Date().timeIntervalSince1970) + 120, device: sender.fixture.device)
            signal.signature = try V5Crypto.sign(sender.fixture.key, signal.message)
            IdentityBusURLProtocol.state.withLock { $0.signals.append((Int64($0.signals.count + 1), signal)) }
        }

        let a = try participant("a"), b = try participant("b"), c = try participant("c")
        let participants = [a, b, c], roster = participants.map(\.peer)
        defer { for p in participants { p.room.end(); p.room.social.reset(for: nil) } }
        for p in participants { try p.room.updateRoster(roster) }
        try await identityCondition { participants.allSatisfy { $0.room.trust == .pending } }
        func inviteBusyParticipant(_ target: Participant) async throws {
            await c.room.startVerification(target.peer)
            try await identityCondition { c.room.verificationPresentation?.phase == .ended(.peerBusy) }
            #expect(c.room.verification == nil && c.room.failure == nil)
            #expect(c.room.verificationPresentation?.peer == target.peer)
        }

        await b.room.startVerification(a.peer)
        let original = try #require(b.room.verification?.id)
        try await identityCondition { a.room.verification?.id == original }
        let commitment = try #require(a.room.verification?.commitment)
        try deliver(["kind": "Request", "commitment": commitment], from: b, to: a, transaction: original)
        try await inviteBusyParticipant(a)
        c.room.dismissVerification()
        try await inviteBusyParticipant(b)
        #expect(a.room.verification?.accepted == false && b.room.verification?.awaitingPeerAcceptance == true)

        await a.room.acceptVerification()
        try await identityCondition { a.room.verification?.decimals.count == 3 && b.room.verification?.decimals.count == 3 }
        let codes = try #require(a.room.verification?.decimals)
        await b.room.confirmVerification(matches: true)
        try deliver(["kind": "Request", "commitment": commitment], from: a, to: b, transaction: V5Crypto.random().base64EncodedString())
        try await inviteBusyParticipant(b)
        let busy = try #require(c.room.verificationPresentation?.transaction)
        #expect(a.room.verification?.id == original && b.room.verification?.id == original)
        #expect(a.room.verification?.decimals == codes && b.room.verification?.decimals == codes)
        #expect(b.room.verification?.confirmed == true)
        #expect(participants.allSatisfy { $0.room.social.friends.isEmpty && $0.room.trust == .pending })

        IdentityBusURLProtocol.state.withLock { $0.rejectTrustWrites = true }
        await a.room.confirmVerification(matches: true)
        try await identityCondition { a.room.verificationPresentation?.phase == .trustPending && b.room.verificationPresentation?.phase == .trustPending }
        b.room.dismissVerification()
        try await inviteBusyParticipant(b)
        let stillBusy = try #require(c.room.verificationPresentation?.transaction)
        #expect(stillBusy != busy && b.room.verificationPresentation == nil)
        IdentityBusURLProtocol.state.withLock { $0.rejectTrustWrites = false }
        await b.room.social.refresh()
        await a.room.retryVerificationTrustSync()
        #expect(b.room.social.trusts(accountID: "member_a", device: a.fixture.device))
        #expect(a.room.social.trusts(accountID: "member_b", device: b.fixture.device))

        await c.room.startVerification(b.peer)
        let retry = try #require(c.room.verification?.id)
        #expect(retry != stillBusy)
        try await identityCondition { b.room.verification?.id == retry }
        try deliver(["kind": "Busy"], from: b, to: c, transaction: stillBusy)
        try deliver(["kind": "Busy"], from: a, to: c, transaction: retry)
        await b.room.acceptVerification()
        try await identityCondition { c.room.verification?.decimals.count == 3 && b.room.verification?.decimals.count == 3 }
        #expect(c.room.verification?.decimals == b.room.verification?.decimals)
        try deliver(["kind": "Busy"], from: b, to: c, transaction: retry)
        await b.room.confirmVerification(matches: true)
        await c.room.confirmVerification(matches: true)
        try await identityCondition { c.room.verificationPresentation?.phase == .completed && b.room.verificationPresentation?.phase == .completed }
        #expect(c.room.social.trusts(accountID: "member_b", device: b.fixture.device))
        #expect(!c.room.social.trusts(accountID: "member_a", device: a.fixture.device))
    }

    @Test(arguments: [false, true])
    func twoSidedSASCreatesSignedSharedTrustAndOnlyTrustsAfterNewKeys(trustUploadFails: Bool) async throws {
        IdentityBusURLProtocol.state.withLock { $0 = .init() }
        let a = try V5TestIdentity("mutual-a"), b = try V5TestIdentity("mutual-b")
        try IdentityBusURLProtocol.register(a); try IdentityBusURLProtocol.register(b)
        let storeA = try testIdentityStore("mutual-a", fixture: a), storeB = try testIdentityStore("mutual-b", fixture: b)
        let tokenA = "chirp_" + String(repeating: "a", count: 43), tokenB = "chirp_" + String(repeating: "b", count: 43)
        IdentityBusURLProtocol.state.withLock { $0.accounts = [tokenA: ("member_a", a.device), tokenB: ("member_b", b.device)] }
        let loginA = try session("member_a", fixture: a, token: tokenA), loginB = try session("member_b", fixture: b, token: tokenB)
        let diskA = MemoryIdentityPersistence()
        let socialA = SocialIdentity(identity: storeA, persistence: diskA, configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration), socialB = SocialIdentity(identity: storeB, persistence: MemoryIdentityPersistence(), configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration)
        socialA.reset(for: loginA); socialB.reset(for: loginB)
        defer { socialA.reset(for: nil); socialB.reset(for: nil) }
        try await identityCondition { socialA.voiceAllowed && socialB.voiceAllowed }
        let startGateA = VerificationGate(), startGateB = VerificationGate()
        let roomA = RoomIdentity(identity: storeA, social: socialA, configuration: configuration(), security: { native, parameters in
            let result = try await native.security(parameters)
            if trustUploadFails, parameters["action"] == "sas_start" { await startGateA.waitOnce() }
            return result
        })
        let roomB = RoomIdentity(identity: storeB, social: socialB, configuration: configuration(), security: { native, parameters in
            let result = try await native.security(parameters)
            if trustUploadFails, parameters["action"] == "sas_start" { await startGateB.waitOnce() }
            return result
        })
        defer { startGateA.release(); startGateB.release(); roomA.end(); roomB.end() }
        socialA.onChange = { roomA.localTrustChanged() }; socialB.onChange = { roomB.localTrustChanged() }
        let policy = V5RoomPolicy.mutual(origin: "https://keys.example.test:443", roomID: "friends")
        let entryA = loginA.participantIdentity + ".entry_a", entryB = loginB.participantIdentity + ".entry_b"
        let peerA = MLSPeer(identity: entryA, name: "Alice", publicKey: a.device.leafKey, keyPackage: "", binding: try a.binding(policy: policy, identity: entryA, mlsKey: a.device.leafKey))
        let peerB = MLSPeer(identity: entryB, name: "Bob", publicKey: b.device.leafKey, keyPackage: "", binding: try b.binding(policy: policy, identity: entryB, mlsKey: b.device.leafKey))
        roomA.begin(login: loginA, admission: RoomAdmission(roomID: "friends", entryID: "entry_a", identity: entryA))
        roomB.begin(login: loginB, admission: RoomAdmission(roomID: "friends", entryID: "entry_b", identity: entryB))
        try roomA.updateRoster([peerA, peerB]); try roomB.updateRoster([peerA, peerB])
        #expect(roomA.trust == .pending && roomB.trust == .pending)
        #expect(roomA.peersNeedingVerification.map(\.identity) == [entryB])
        #expect(try roomA.approveRoster([peerA, peerB]) == nil)
        #expect(try roomB.approveRoster([peerA, peerB]) == nil)
        await roomA.addFriend(peerB)
        try await identityCondition { socialA.friends.count == 1 && socialB.friends.isEmpty }
        #expect(!socialA.trusts(accountID: "member_b", device: b.device))
        let signalCount = IdentityBusURLProtocol.state.withLock { $0.signals.filter { $0.1.kind == "sas" }.count }
        roomA.presentPendingVerification(for: entryA)
        #expect(roomA.verificationPresentation == nil)
        roomA.presentPendingVerification(for: entryB)
        #expect(roomA.verificationPresentation?.phase == .preparation && roomA.verificationPresentation?.peer.identity == entryB)
        #expect(roomA.verification == nil)
        #expect(IdentityBusURLProtocol.state.withLock { $0.signals.filter { $0.1.kind == "sas" }.count } == signalCount)
        roomA.dismissVerification()
        #expect(roomA.verificationPresentation == nil)
        // Declining before accepting still cancels the initiator's spinner.
        if trustUploadFails {
            startGateA.entered = false
            let startA = Task { await roomA.startVerification(peerB) }
            let startB = Task { await roomB.startVerification(peerA) }
            try await identityCondition { startGateA.entered && startGateB.entered }
            #expect(roomA.verification?.id != roomB.verification?.id)
            startGateA.release(); startGateB.release()
            await startA.value; await startB.value
            try await identityCondition { roomA.verification?.id == roomB.verification?.id && roomA.verification != nil }
        } else { await roomA.startVerification(peerB) }
        try await identityCondition { roomB.verification != nil }
        await roomB.confirmVerification(matches: false)
        #expect(roomB.verification == nil)
        #expect(roomB.verificationPresentation?.phase == .ended(.mismatch))
        try await identityCondition { roomA.verification == nil }
        #expect(roomA.verificationPresentation?.phase == .ended(.peerCancelled))
        roomA.prepareVerificationAgain()
        #expect(roomA.verificationPresentation?.phase == .preparation && roomA.verification == nil)
        await roomA.startVerification(peerB)
        #expect(roomA.failure == nil)
        #expect(roomA.verification != nil)

        try await identityCondition { roomB.verification != nil }
        await roomB.acceptVerification()
        try await identityCondition { roomA.verification?.decimals.count == 3 && roomB.verification?.decimals.count == 3 }
        #expect(roomA.verification?.decimals == roomB.verification?.decimals)
        await roomA.confirmVerification(matches: true)
        #expect(!socialA.trusts(accountID: "member_b", device: b.device))
        #expect(roomA.verificationPresentation?.phase == .active && roomA.verification?.confirmed == true)
        IdentityBusURLProtocol.state.withLock { $0.rejectTrustWrites = trustUploadFails }
        await roomB.confirmVerification(matches: true)
        if trustUploadFails {
            try await identityCondition { roomA.verificationPresentation?.phase == .trustPending && roomB.verificationPresentation?.phase == .trustPending }
            #expect(!socialA.trusts(accountID: "member_b", device: b.device) && !socialB.trusts(accountID: "member_a", device: a.device))
            IdentityBusURLProtocol.state.withLock { $0.rejectTrustWrites = false }
            await roomA.retryVerificationTrustSync(); await roomB.retryVerificationTrustSync()
        }
        try await identityCondition { roomA.trust == .rebuilding && roomB.trust == .rebuilding }
        #expect(roomA.verificationPresentation?.phase == .completed && roomB.verificationPresentation?.phase == .completed)
        #expect(roomA.trust == .rebuilding && roomB.trust == .rebuilding)
        #expect(roomA.peersNeedingVerification.isEmpty && roomB.peersNeedingVerification.isEmpty)
        #expect(socialA.trusts(accountID: "member_b", device: b.device) && socialB.trusts(accountID: "member_a", device: a.device))
        #expect(try roomA.approveRoster([peerA, peerB]) != nil)
        #expect(try roomB.approveRoster([peerA, peerB]) != nil)
        try roomA.keysReady(); try roomB.keysReady()
        try await identityCondition { roomA.trust == .trusted && roomB.trust == .trusted }
        // A newly joined device does not inherit another participant's trust.
        let c = try V5TestIdentity("mutual-c"), entryC = "member_c.login_test.entry_c"
        let peerC = MLSPeer(identity: entryC, name: "Carol", publicKey: c.device.leafKey, keyPackage: "", binding: try c.binding(policy: policy, identity: entryC, mlsKey: c.device.leafKey))
        try roomA.updateRoster([peerA, peerB, peerC]); #expect(roomA.trust == .pending)
        #expect(roomA.peersNeedingVerification.map(\.identity) == [entryC])
        #expect(socialA.trusts(accountID: "member_b", device: b.device) && !socialA.trusts(accountID: "member_c", device: c.device))
        IdentityBusURLProtocol.state.withLock { $0.rejectWrites = true }
        await socialA.change(operation: "remove_friend", friendID: "member_b", device: b.device, name: "Bob")
        #expect(!socialA.trusts(accountID: "member_b", device: b.device))
        // A competing accepted update must not silently discard the offline
        // deletion when its old version is no longer the server's next version.
        try IdentityBusURLProtocol.state.withLock { state in
            let events = state.events["member_a"] ?? []
            var concurrent = SocialIdentityEvent(origin: "https://keys.example.test:443", accountID: "member_a", version: Int64(events.count + 1),
                previousHash: events.last?.digest ?? "", operation: "friend", friendID: "member_b", friendKey: b.device.accountKey,
                deviceKey: "", name: "Concurrent update", signer: a.device)
            concurrent.signature = try storeA.signIdentityMessage(concurrent.message)
            state.events["member_a", default: []].append(concurrent)
            let old = state.authorization[a.device.accountKey]!
            var event = AuthorizationEvent(origin: IdentityBusURLProtocol.authorityConfiguration.origin, version: Int64(old.records.count + 1),
                previousHash: old.records.last!.event.digest, operation: "social", signer: a.device, social: concurrent)
            event.signature = try storeA.signIdentityMessage(event.message)
            state.authorization[a.device.accountKey] = AuthorizationAccount(root: old.root, records: old.records + [AuthorizationRecord(event: event, acceptedAt: Int64(Date().timeIntervalSince1970))])
        }
        let restored = SocialIdentity(identity: storeA, persistence: diskA, configuration: configuration(), authority: IdentityBusURLProtocol.authorityConfiguration); restored.reset(for: loginA)
        defer { restored.reset(for: nil) }
        try await identityCondition { restored.voiceAllowed && !restored.isRefreshing }
        #expect(!restored.trusts(accountID: "member_b", device: b.device))
        IdentityBusURLProtocol.state.withLock { $0.rejectWrites = false }
        await restored.refresh(); #expect(restored.friends.isEmpty)
        #expect(IdentityBusURLProtocol.state.withLock { $0.events["member_a"]?.last?.operation } == "remove_friend")
        let blacklist = BlacklistRecord(sequence: 1, kind: "device", subject: b.device.leafKey, accountID: "member_b", accountKey: b.device.accountKey, username: "Bob", createdAt: Int64(Date().timeIntervalSince1970))
        IdentityBusURLProtocol.state.withLock { $0.blacklist = [blacklist] }
        await socialB.refresh(); #expect(socialB.blocked(accountID: "member_b", device: b.device))
        IdentityBusURLProtocol.state.withLock { $0.blacklist = [] }
        await socialB.refresh(); #expect(socialB.blacklist == [blacklist])
    }
}
