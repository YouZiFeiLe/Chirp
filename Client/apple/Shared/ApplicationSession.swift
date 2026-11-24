import Combine
import Foundation
import Observation

/// All windows observe this same application lifetime, rather than owning calls.
@MainActor @Observable
final class ApplicationSession {
    let networkClock: NetworkClock
    let login: LoginSession
    let call: CallController
    let directory: RoomDirectory
    let stateSync: ClientStateSync
    let identity: DeviceIdentityStore
    let identitySetup: IdentitySetupController
    let social: SocialIdentity
    let roomIdentity: RoomIdentity
    @ObservationIgnored private var cacheCleared: AnyCancellable?

    init(dependencies: CallDependencies, networkClock: NetworkClock = NetworkClock()) {
        self.networkClock = networkClock
        identity = dependencies.identity ?? DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        identitySetup = IdentitySetupController(identity: identity, requireClock: networkClock.requireReady)
        social = SocialIdentity(identity: identity)
        roomIdentity = RoomIdentity(identity: identity, social: social)
        call = CallController(dependencies: dependencies)
        if dependencies.identity != nil { call.roomIdentity = roomIdentity }
        login = LoginSession()
        directory = RoomDirectory()
        stateSync = ClientStateSync(directory: directory, profiles: login.profiles) { [weak login] reason in login?.clear(reason) }
        identitySetup.onComplete = { [weak login] value in login?.accept(value) }
        social.onRevoked = { [weak login] in login?.clear(ClientFailure(.identityBlacklisted)) }
        social.onChange = { [weak roomIdentity] in roomIdentity?.localTrustChanged() }
        login.onSessionChange = { [weak call, weak stateSync, weak social] value in
            social?.reset(for: value)
            call?.setClientSession(value)
            stateSync?.reset(for: value)
        }
        cacheCleared = NotificationCenter.default.publisher(for: AttachmentCache.didClear)
            .sink { [weak call] _ in
                Task { @MainActor [weak call] in call?.attachments.cacheWasCleared() }
            }
    }
    func resetAllLocalData() async throws {
        await call.shutdown(); login.clear()
        ClientLog.shared.setEnabled(false)
        try await ClientLog.shared.clear()
        try identitySetup.reset(); try identity.clearAll(); try social.clearAll(); roomIdentity.end()
        try AttachmentCache.shared.clearAll()
        URLCache.shared.removeAllCachedResponses()
        HTTPCookieStorage.shared.cookies?.forEach { HTTPCookieStorage.shared.deleteCookie($0) }
        if let bundleID = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: bundleID) }
        login.server.resetAll(); await call.resetLocalSettings()
    }

}
