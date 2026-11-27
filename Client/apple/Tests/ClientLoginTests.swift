import CryptoKit
import Foundation
import LocalAuthentication
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func loginUsesFreshPKCEAndStrictCallback() throws {
    let login = try ClientLoginRequest(connection: testServerConnection)
    let other = try ClientLoginRequest(connection: testServerConnection)
    #expect(login.verifier != other.verifier && login.state != other.state)
    let query = URLComponents(url: login.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(login.authorizationURL.host == "keys.example.test")
    #expect(query.first(where: { $0.name == "code_challenge" })?.value == login.challenge)
    #expect(!login.authorizationURL.absoluteString.contains(login.verifier))
    let code = String(repeating: "c", count: 43)
    #expect(try login.code(from: URL(string: "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(login.state)")!) == code)
    for value in [
        "cn.youzifeile.chirp://other/callback?code=\(code)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/wrong?code=\(code)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(other.state)",
        "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(login.state)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/callback?code=short&state=\(login.state)",
        "https://keys.example.test/?code=\(code)&state=\(login.state)",
    ] {
        #expect(throws: (any Error).self) { try login.code(from: URL(string: value)!) }
    }
}

@Test func loginSessionRejectsInvalidExpiryAndIdentity() throws {
    func data(expiry: Double, identity: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["member": ["id": "member_test", "display_name": "Oliver"], "credential": "chirp_" + String(repeating: "a", count: 43), "expires_at": expiry, "participant_identity": identity])
    }
    let valid = try ClientSession(data: data(expiry: Date().timeIntervalSince1970 + 72000, identity: "member_test.login_test"), connection: testServerConnection)
    #expect(valid.member.id == "member_test")
    for (expiry, identity) in [(Date().timeIntervalSince1970 - 1, "member_test.login_test"), (Date().timeIntervalSince1970 + 90000, "member_test.login_test"), (Date().timeIntervalSince1970 + 3600, "member_other.login_test")] {
        #expect(throws: (any Error).self) { try ClientSession(data: data(expiry: expiry, identity: identity), connection: testServerConnection) }
    }
}

@MainActor private final class TestLoginVault: LoginVault {
    var saved: SavedLogin?
    var hasSavedLogin: Bool { saved != nil }
    var expiration: Date? { saved?.expiresAt }
    var authenticate: () async throws -> Void = {}
    var saveFailure: ClientFailure?
    var reads = 0
    var saves = 0
    func save(_ login: SavedLogin) throws {
        saves += 1
        if let saveFailure { throw saveFailure }
        saved = login
    }
    func open() async throws -> SavedLogin {
        reads += 1
        try await authenticate()
        guard let saved else { throw ClientFailure(.loginExpired) }
        return saved
    }
    func clear() { saved = nil }
    func cancel() {}
}

@Suite @MainActor struct SavedLoginTests {
    private let token = "resume-v1_" + String(repeating: "r", count: 43)

    private func session(until expiry: Date = Date().addingTimeInterval(3600)) throws -> ClientSession {
        let device = try V5TestIdentity("resumption").device
        let data = try JSONSerialization.data(withJSONObject: [
            "member": ["id": "member_test", "display_name": "Oliver"], "participant_identity": "member_test.login_test",
            "credential": "chirp_" + String(repeating: "a", count: 43), "expires_at": expiry.timeIntervalSince1970,
            "device_identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(device))])
        return try ClientSession(data: data, connection: testServerConnection, expectedDevice: device)
    }

    private func wait(until ready: () -> Bool) async throws {
        let end = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(5)) }
        try #require(ready())
    }

    @Test func coldLaunchPromptsOnceAndWarmReturnsKeepTheSameSession() async throws {
        let vault = TestLoginVault(), session = try session(until: Date().addingTimeInterval(20 * 3600))
        let original = LoginSession(vault: vault)
        original.accept(session, savedLogin: SavedLogin(session: session, token: token))
        let ticket = try #require(vault.saved)
        let json = String(decoding: try JSONEncoder().encode(ticket), as: UTF8.self)
        #expect(!json.contains(session.credential))
        #expect(ticket.expiresAt == session.expiresAt)
        var restores = 0, activations = 0
        let login = LoginSession(vault: vault, restore: { _ in restores += 1; return session })
        login.onSessionChange = { _ in activations += 1 }
        #expect(login.isLocked && login.session == nil && restores == 0)
        vault.authenticate = { throw LAError(.userCancel) }
        login.enterForeground()
        try await wait { !login.isUnlocking }
        login.enterForeground() // The system prompt itself can produce another active event.
        login.leaveForeground()
        login.enterForeground()
        #expect(vault.reads == 1 && restores == 0 && login.isLocked && login.session == nil)
        vault.authenticate = {}
        login.unlock()
        login.unlock()
        try await wait { !login.isUnlocking }
        #expect(restores == 1 && vault.reads == 2 && !login.isLocked && login.session != nil)
        #expect(login.session?.expiresAt == session.expiresAt)
        for _ in 0..<2 {
            login.leaveForeground()
            #expect(!login.isLocked && login.session?.credential == session.credential)
            login.enterForeground()
            #expect(!login.isUnlocking && login.session?.credential == session.credential)
        }
        #expect(vault.reads == 2 && restores == 1 && activations == 1)
        #expect(vault.saves == 1 && vault.expiration == ticket.expiresAt)
        login.clear()
        #expect(vault.saved == nil && login.session == nil)
        original.clear()
    }

    @Test(arguments: [false, true])
    func missingOrUnsaveableGrantNeedsPasskeyOnlyAfterProcessExit(writeFails: Bool) throws {
        let vault = TestLoginVault(), live = try session()
        let login = LoginSession(vault: vault)
        login.leaveForeground()
        if writeFails { vault.saveFailure = ClientFailure(.secureLoginFailed) }
        login.accept(live, savedLogin: writeFails ? SavedLogin(session: live, token: token) : nil)
        login.enterForeground()
        login.leaveForeground()
        login.enterForeground()
        #expect(login.session?.credential == live.credential && !login.isLocked && !login.isUnlocking)
        let restarted = LoginSession(vault: vault)
        restarted.enterForeground()
        #expect(restarted.session == nil && !restarted.isLocked && !restarted.isUnlocking)
        #expect(vault.saved == nil && vault.reads == 0 && vault.saves == (writeFails ? 1 : 0))
        login.clear()
    }

    @Test func aNewProcessCanReadTheReferenceImmediatelyAfterSave() throws {
        let id = UUID().uuidString
        let directory = FileManager.default.temporaryDirectory.appending(path: id)
        let defaults = try #require(UserDefaults(suiteName: id))
        defer {
            try? FileManager.default.removeItem(at: directory)
            defaults.removePersistentDomain(forName: id)
        }
        let legacyKey = "chirp.savedLogin.reference.v1"
        let reference = LoginReferenceStore.Reference(account: UUID(), expiresAt: Date(timeIntervalSince1970: 1_800_000_000), usesSessionExpiry: true)
        defaults.set(try JSONEncoder().encode(reference), forKey: legacyKey)
        let store = LoginReferenceStore(directory: directory, defaults: defaults)
        #expect(store.load()?.account == reference.account)
        try store.save(reference)
        #expect(defaults.data(forKey: legacyKey) == nil)
        let restarted = LoginReferenceStore(directory: directory, defaults: defaults)
        let saved = try #require(restarted.load())
        #expect(saved.account == reference.account && saved.expiresAt == reference.expiresAt)
        restarted.clear()
        #expect(store.load() == nil)
    }

    @Test func transientRestoreFailureCanRetryAndRevocationForgetsTheGrant() async throws {
        let vault = TestLoginVault(), session = try session()
        vault.saved = SavedLogin(session: session, token: token)
        var rejection = ClientFailure(.networkUnavailable)
        let login = LoginSession(vault: vault, restore: { _ in throw rejection })
        login.enterForeground()
        try await wait { !login.isUnlocking }
        #expect(login.isLocked && vault.saved != nil && login.unlockFailure == rejection)
        rejection = ClientFailure(.invalidAuthorization)
        login.unlock()
        try await wait { !login.isUnlocking }
        #expect(!login.isLocked && login.session == nil && vault.saved == nil && login.message == rejection)
    }

    @Test func lateAuthenticationCannotRestoreAfterLeavingOrClearing() async throws {
        let vault = TestLoginVault(), session = try session()
        vault.saved = SavedLogin(session: session, token: token)
        var pending: CheckedContinuation<Void, Never>?
        vault.authenticate = { await withCheckedContinuation { pending = $0 } }
        var restores = 0
        let login = LoginSession(vault: vault, restore: { _ in restores += 1; return session })
        login.enterForeground()
        try await wait { pending != nil }
        login.leaveForeground()
        pending?.resume()
        pending = nil
        #expect(login.isLocked && login.session == nil)
        login.enterForeground()
        #expect(!login.isUnlocking && vault.reads == 1)
        login.unlock()
        try await wait { pending != nil }
        login.clear()
        pending?.resume()
        await Task.yield()
        #expect(restores == 0 && !login.isLocked && login.session == nil && vault.saved == nil)
    }

    @Test(arguments: [false, true])
    func warmAndColdLoginWorkInTheFinalHourAndEndAtTheOriginalCutoff(cold: Bool) async throws {
        let issued = Date()
        let live = try session(until: issued.addingTimeInterval(20 * 3600))
        let ticket = try #require(SavedLogin(session: live, token: token))
        #expect(ticket.expiresAt == live.expiresAt)
        var now = issued
        let vault = TestLoginVault()
        if cold { vault.saved = ticket }
        var restores = 0, ends = 0
        let login = LoginSession(vault: vault, now: { now }, restore: { _ in restores += 1; return live })
        login.onSessionChange = { if $0 == nil { ends += 1 } }
        if !cold { login.accept(live, savedLogin: ticket); login.leaveForeground() }
        now = live.expiresAt.addingTimeInterval(-1)
        login.enterForeground()
        try await wait { !login.isUnlocking }
        #expect(!login.isLocked && vault.reads == (cold ? 1 : 0) && restores == (cold ? 1 : 0))
        #expect(login.session?.expiresAt == live.expiresAt && vault.saved?.expiresAt == live.expiresAt)
        now = live.expiresAt
        login.enterForeground()
        #expect(login.session == nil && vault.saved == nil && ends == 1 && login.message == ClientFailure(.loginExpired))
        // A cold start at the identical boundary goes directly to Passkey.
        vault.saved = ticket
        let restarted = LoginSession(vault: vault, now: { now })
        restarted.enterForeground()
        #expect(!restarted.isLocked && restarted.session == nil && vault.saved == nil && vault.reads == (cold ? 1 : 0))
    }

    @Test func coldRestoreFinishingAtExpiryDiscardsTheLateCredential() async throws {
        let live = try session(), vault = TestLoginVault()
        vault.saved = SavedLogin(session: live, token: token)
        var now = live.expiresAt.addingTimeInterval(-1)
        var pending: CheckedContinuation<Void, Never>?
        let login = LoginSession(vault: vault, now: { now }, restore: { _ in
            await withCheckedContinuation { pending = $0 }
            return live
        })
        login.enterForeground()
        try await wait { pending != nil }
        now = live.expiresAt
        pending?.resume()
        try await wait { !login.isUnlocking }
        #expect(login.session == nil && vault.saved == nil && login.message == ClientFailure(.loginExpired))
    }

    @Test func expirationTimerEndsAnOpenSessionAndErasesTheReceipt() async throws {
        let vault = TestLoginVault(), short = try session(until: Date().addingTimeInterval(0.3))
        let login = LoginSession(vault: vault)
        login.accept(short, savedLogin: SavedLogin(session: short, token: token))
        try await wait { login.session == nil }
        #expect(vault.saved == nil && login.message == ClientFailure(.loginExpired))
    }
}
