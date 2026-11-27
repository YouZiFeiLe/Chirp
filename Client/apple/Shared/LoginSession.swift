import Foundation
import LocalAuthentication
import Observation

@MainActor @Observable
final class LoginSession {
    private(set) var session: ClientSession?
    private(set) var isLocked = false
    private(set) var unlockFailure: ClientFailure?
    var message: ClientFailure?
    let profiles = MemberProfiles()
    let server = ServerSettings()
    private let log: ClientLog
    private let vault: (any LoginVault)?
    private let restore: @MainActor (SavedLogin) async throws -> ClientSession
    private let now: () -> Date
    private var monitor: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var unlockTask: Task<Void, Never>?
    private var inForeground = false
    private var firstForeground = true
    var isUnlocking: Bool { unlockTask != nil }
    var onSessionChange: (@MainActor (ClientSession?) -> Void)?

    init(log: ClientLog = .shared, vault: (any LoginVault)? = nil, now: @escaping () -> Date = Date.init,
         restore: @escaping @MainActor (SavedLogin) async throws -> ClientSession = { _ in throw ClientFailure(.invalidLoginSession) }) {
        self.log = log
        self.vault = vault
        self.restore = restore
        self.now = now
        isLocked = vault?.hasSavedLogin == true
        if let expiry = vault?.expiration {
            if expiry > now() {
                scheduleExpiry(expiry)
            } else {
                clear(ClientFailure(.loginExpired))
            }
        }
    }

    func accept(_ value: ClientSession, savedLogin: SavedLogin? = nil) {
        cancelUnlock()
        if let vault {
            vault.clear()
            if let savedLogin, savedLogin.expiresAt == value.expiresAt, savedLogin.expiresAt > now() {
                do { try vault.save(savedLogin) }
                catch { log.record(.account, "saveLoginForRelaunch", outcome: .failed, failure: ClientFailure(.secureLoginFailed)) }
            } else {
                log.record(.account, "loginWithoutResumptionGrant")
            }
        }
        firstForeground = false
        isLocked = false
        activate(value)
    }

    func leaveForeground() {
        inForeground = false
        if isUnlocking { cancelUnlock() }
    }

    func enterForeground() {
        inForeground = true
        if let expiry = session?.expiresAt ?? vault?.expiration, expiry <= now() { clear(ClientFailure(.loginExpired)); return }
        guard firstForeground else { return }
        firstForeground = false
        // Protected app data may first become readable when a background launch reaches the foreground.
        isLocked = session == nil && vault?.hasSavedLogin == true
        if isLocked { unlock() }
    }

    func unlock() {
        guard inForeground, isLocked, !isUnlocking, let vault else { return }
        unlockFailure = nil
        unlockTask = Task {
            defer {
                if !Task.isCancelled { unlockTask = nil }
            }
            do {
                let saved = try await vault.open()
                try Task.checkCancellation()
                guard saved.expiresAt == vault.expiration else { throw ClientFailure(.invalidLoginSession) }
                guard saved.expiresAt > now() else { throw ClientFailure(.loginExpired) }
                if expiryTask == nil { scheduleExpiry(saved.expiresAt) }
                let resumed = try await restore(saved)
                try Task.checkCancellation()
                guard resumed.expiresAt > now(), resumed.expiresAt <= saved.expiresAt else { throw ClientFailure(.loginExpired) }
                isLocked = false
                activate(resumed)
            } catch {
                guard !Task.isCancelled else { return }
                if let error = error as? LAError {
                    switch error.code {
                    case .biometryNotEnrolled, .passcodeNotSet:
                        clear(ClientFailure(.localUnlockFailed))
                    case .userCancel, .systemCancel, .appCancel:
                        break
                    default:
                        unlockFailure = ClientFailure(.localUnlockFailed)
                    }
                    return
                }
                let failure = ClientFailure.capture(error)
                switch ClientErrorCode(rawValue: failure.code) {
                case .loginExpired, .invalidLoginSession, .invalidAuthorization, .unauthorized, .memberDisabled,
                     .identityBlacklisted, .deviceIdentityRequired, .v5IdentityInvalid, .identityExpired, .identityChanged,
                     .clientUpdateRequired, .serverConfigurationChanged:
                    clear(failure)
                default:
                    unlockFailure = failure
                }
            }
        }
    }

    private func cancelUnlock() {
        unlockTask?.cancel()
        unlockTask = nil
        vault?.cancel()
        unlockFailure = nil
    }

    private func scheduleExpiry(_ date: Date) {
        expiryTask?.cancel()
        let interval = max(0, min(ClientSession.maximumReportedLifetime, date.timeIntervalSince(now())))
        expiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(interval)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.clear(ClientFailure(.loginExpired))
        }
    }

    private func activate(_ value: ClientSession) {
        guard value.expiresAt > now() else { clear(ClientFailure(.loginExpired)); return }
        monitor?.cancel()
        scheduleExpiry(value.expiresAt)
        log.record(.account, "loginAccepted", outcome: .succeeded)
        session = value
        profiles.reset(credential: value.credential, server: value.connection.apiURL)
        message = nil
        onSessionChange?(value)
        monitor = Task { [weak self, now] in
            let api = APIClient(baseURL: value.connection.apiURL, credential: value.credential)
            defer { api.close() }
            while !Task.isCancelled {
                guard self?.session?.credential == value.credential else { return }
                if now() >= value.expiresAt { self?.clear(ClientFailure(.loginExpired)); return }
                do {
                    _ = try await api.joinSequence(for: value)
                }
                catch APIError.unauthorized {
                    guard self?.session?.credential == value.credential else { return }
                    self?.clear(ClientFailure(.unauthorized)); return
                }
                catch APIError.disabled {
                    guard self?.session?.credential == value.credential else { return }
                    self?.clear(ClientFailure(.memberDisabled)); return
                }
                catch { /* A transient network failure does not extend or revoke the session. */ }
                do { try await Task.sleep(for: .seconds(min(3, max(0.01, value.expiresAt.timeIntervalSince(now()))))) }
                catch { return }
            }
        }
    }

    func clear(_ reason: ClientFailure? = nil) {
        let hadSession = session != nil
        cancelUnlock()
        vault?.clear()
        expiryTask?.cancel()
        expiryTask = nil
        firstForeground = false
        isLocked = false
        monitor?.cancel()
        monitor = nil
        session = nil
        profiles.reset(credential: nil, server: nil)
        message = reason
        if hadSession {
            log.record(.account, "sessionEnded", failure: reason)
            onSessionChange?(nil)
        }
    }

    func logout() async {
        log.record(.account, "logout")
        let previous = session
        clear()
        if let previous {
            let api = APIClient(baseURL: previous.connection.apiURL, credential: previous.credential)
            defer { api.close() }
            try? await api.logout()
        }
    }
}
