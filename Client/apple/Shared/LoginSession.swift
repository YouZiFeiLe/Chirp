import Foundation
import Observation

@MainActor @Observable
final class LoginSession {
    private(set) var session: ClientSession?
    var message: ClientFailure?
    let profiles = MemberProfiles()
    let server = ServerSettings()
    private let log: ClientLog
    init(log: ClientLog = .shared) { self.log = log }

    private var monitor: Task<Void, Never>?
    var onSessionChange: (@MainActor (ClientSession?) -> Void)?

    func accept(_ value: ClientSession) {
        monitor?.cancel()
        log.record(.account, "loginAccepted", outcome: .succeeded)
        session = value
        profiles.reset(credential: value.credential, server: value.connection.apiURL)
        message = nil
        onSessionChange?(value)
        monitor = Task { [weak self] in
            let api = APIClient(baseURL: value.connection.apiURL, credential: value.credential)
            defer { api.close() }
            while !Task.isCancelled {
                guard self?.session?.credential == value.credential else { return }
                if Date() >= value.expiresAt { self?.clear(ClientFailure(.loginExpired)); return }
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
                do { try await Task.sleep(for: .seconds(min(3, max(0.01, value.expiresAt.timeIntervalSinceNow)))) }
                catch { return }
            }
        }
    }

    func clear(_ reason: ClientFailure? = nil) {
        let hadSession = session != nil
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
