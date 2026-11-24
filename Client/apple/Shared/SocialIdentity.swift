import ChirpMLS
import Foundation
import Observation
import Network

struct BlacklistRecord: Codable, Sendable, Equatable {
    let sequence: Int64
    let kind: String
    let subject: String
    let accountID: String
    let accountKey: String
    let username: String
    let createdAt: Int64
    enum CodingKeys: String, CodingKey { case sequence, kind, subject, username, accountID = "account_id", accountKey = "account_key", createdAt = "created_at" }
}

/// Account revocation also produces a record for every registered device.
/// Group those records without treating an account key as a device fingerprint.
struct BlacklistedIdentity: Identifiable, Sendable {
    let accountID: String
    let accountKey: String
    let records: [BlacklistRecord]
    var id: String { accountID + "|" + accountKey }
    var name: String { records.last(where: { !$0.username.isEmpty })?.username ?? accountID }
    var accountBlocked: Bool { records.contains { $0.kind == "account" } }
    var devices: [BlacklistRecord] { records.filter { $0.kind == "device" } }

    static func grouped(_ records: [BlacklistRecord]) -> [Self] {
        Dictionary(grouping: records, by: { $0.accountID + "|" + $0.accountKey })
            .values.map { records in
                let sorted = records.sorted { $0.sequence < $1.sequence }
                return Self(accountID: sorted[0].accountID, accountKey: sorted[0].accountKey, records: sorted)
            }
            .sorted { ($0.records.last?.sequence ?? 0) > ($1.records.last?.sequence ?? 0) }
    }
}
struct RegisteredIdentityDevice: Decodable, Identifiable, Sendable {
    let deviceKey: String
    let accountID: String
    let accountKey: String
    let device: V5Device
    let name: String
    let platform: String
    let createdAt: Int64
    let lastLoginAt: Int64?
    let revoked: Bool
    var id: String { deviceKey }
    enum CodingKeys: String, CodingKey { case deviceKey = "device_key", accountID = "account_id", accountKey = "account_key", device, name, platform, createdAt = "created_at", lastLoginAt = "last_login_at", revoked }
}
struct SocialIdentityEvent: Codable, Sendable {
    let origin: String
    let accountID: String
    let version: Int64
    let previousHash: String
    let operation: String
    let friendID: String
    let friendKey: String
    let deviceKey: String
    let name: String
    let signer: V5Device
    var signature = ""
    var message: Data { V5Crypto.message("Chirp account social event v5", [origin, accountID, String(version), previousHash, operation, friendID, friendKey, deviceKey, name, signer.digest]) }
    var digest: String { V5Crypto.hash(V5Crypto.record("Chirp account social event digest v5", [message, Data(signature.utf8)])) }
    enum CodingKeys: String, CodingKey { case origin, accountID = "account_id", version, previousHash = "previous_hash", operation, friendID = "friend_id", friendKey = "friend_key", deviceKey = "device_key", name, signer, signature }
}
struct IdentityFriend: Codable, Identifiable, Sendable {
    let accountID: String
    let accountKey: String
    var name: String
    var trustedDevices: Set<String> = []
    var id: String { accountID + "|" + accountKey }
}
private struct SocialAccountState: Codable {
    var version: Int64 = 0
    var previousHash = ""
    var friends: [IdentityFriend] = []
    var pending: SocialIdentityEvent?
    var pendingRevocation: String?
}
private struct SocialVault: Codable {
    var accounts: [String: SocialAccountState] = [:]
    var blacklists: [String: [BlacklistRecord]] = [:]
    var checkpoints: [String: [String: AuthorizationCheckpoint]] = [:]
    var localRevocations: [String: Set<String>] = [:]
}

@MainActor @Observable
final class SocialIdentity {
    private let identity: DeviceIdentityStore
    private let persistence: any IdentityPersistence
    private let configuration: URLSessionConfiguration?
    private var vault = SocialVault()
    private var scope = ""
    private var origin = ""
    private var login: ClientSession?
    private var task: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    private var authorizationDeadline: ContinuousClock.Instant?
    private var authorized: [String: AuthorizedAccount] = [:]
    private var observedRoots: Set<String> = []
    private let authorityConfiguration: AuthorizationConfiguration?
    private var refreshID: UUID?
    private(set) var devices: [RegisteredIdentityDevice] = []
    private var storageCorrupt = false
    private var hasSocialSnapshot = false
    private(set) var failure: String?
    private(set) var revision: UInt64 = 0
    var onChange: (@MainActor () -> Void)?
    var onRevoked: (@MainActor () -> Void)?
    var socialVersion: Int64 { vault.accounts[scope]?.pending?.version ?? vault.accounts[scope]?.version ?? 0 }
    var hasPendingTrustWrite: Bool { vault.accounts[scope]?.pending?.operation == "trust" }
    var friends: [IdentityFriend] { vault.accounts[scope]?.friends ?? [] }
    var blacklist: [BlacklistRecord] { vault.blacklists[origin] ?? [] }
    var voiceAllowed: Bool {
        guard !storageCorrupt, let device = login?.deviceIdentity, let deadline = authorizationDeadline, deadline > .now else { return false }
        return authorized[device.accountKey]?.active(device) == true && !blocked(accountID: login?.member.id ?? "", device: device)
    }
    var sendingDeadline: ContinuousClock.Instant? { voiceAllowed ? authorizationDeadline : nil }
    var isRefreshing: Bool { refreshID != nil }
    init(identity: DeviceIdentityStore, persistence: any IdentityPersistence = KeychainIdentityPersistence(service: "cn.youzifeile.chirp.social.v5"), configuration: URLSessionConfiguration? = nil, authority: AuthorizationConfiguration? = nil) {
        self.identity = identity; self.persistence = persistence; self.configuration = configuration; self.authorityConfiguration = authority
        do { if let data = try persistence.load() { vault = try JSONDecoder().decode(SocialVault.self, from: data) } } catch { storageCorrupt = true; failure = "Local trust storage is damaged. Reset local data before using voice." }
    }
    private func persist() throws { try persistence.save(JSONEncoder().encode(vault)); revision &+= 1; onChange?() }
    func reset(for session: ClientSession?) {
        task?.cancel(); task = nil; pathMonitor?.cancel(); pathMonitor = nil; refreshID = nil; authorizationDeadline = nil; authorized = [:]; observedRoots = []; hasSocialSnapshot = false; login = session; devices = []
        guard let session else { onChange?(); return }
        origin = ServerAddress.identityOrigin(session.connection.passkeyOrigin); scope = origin + "|" + session.member.id
        if configuration == nil {
            let monitor = NWPathMonitor(); pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] path in
                if path.status == .satisfied { Task { @MainActor [weak self] in await self?.refresh() } }
            }
            monitor.start(queue: DispatchQueue(label: "cn.youzifeile.chirp.identity-network"))
        }
        task = Task { [weak self] in
            var elapsed = 20
            while !Task.isCancelled {
                guard let self else { return }
                if elapsed >= 20 { await refresh(); elapsed = 0 }
                onChange?()
                do { try await Task.sleep(for: .seconds(1)) } catch { return }; elapsed += 1
            }
        }
    }
    func observe(_ peers: [MLSPeer]) {
        let roots = Set(peers.compactMap { $0.binding?.device.accountKey })
        guard roots != observedRoots else { return }
        observedRoots = roots
        if refreshID == nil { Task { await refresh() } }
    }
    func deviceAuthorized(_ device: V5Device) -> Bool {
        voiceAllowed && authorized[device.accountKey]?.active(device) == true
    }
    func authorizationHash(for peers: [MLSPeer]) throws -> String {
        guard voiceAllowed else { throw V5IdentityError.expired }
        let roots = Set(peers.compactMap { $0.binding?.device.accountKey }).sorted()
        let fields = try roots.flatMap { root -> [String] in
            guard let account = authorized[root] else { throw V5IdentityError.untrusted }
            return [root, String(account.checkpoint.version), account.checkpoint.hash]
        }
        return V5Crypto.hash(V5Crypto.message("Chirp approved authorization v5", fields))
    }
    private func authorizationAPI() throws -> AuthorizationAPI {
        guard let login else { throw V5IdentityError.untrusted }
        let identity = identity
        return try AuthorizationAPI(configuration: authorityConfiguration ?? login.connection.authorizationConfiguration, network: configuration,
            device: identity.requireDevice(), signer: { try identity.signIdentityMessage($0) })
    }
    private func event(operation: String, account: AuthorizedAccount, target: String = "", social: SocialIdentityEvent? = nil) throws -> AuthorizationEvent {
        var event = AuthorizationEvent(origin: origin, version: account.checkpoint.version + 1, previousHash: account.checkpoint.hash,
            operation: operation, signer: try identity.requireDevice(), targetKey: target, social: social)
        event.signature = try identity.signIdentityMessage(event.message)
        return event
    }
    func refresh() async {
        guard refreshID == nil, let login, let device = login.deviceIdentity, !storageCorrupt else { return }
        let id = UUID(), startingRoots = observedRoots
        refreshID = id
        defer {
            if refreshID == id {
                refreshID = nil
                // A roster change during a snapshot needs a challenge covering the new roots.
                if observedRoots != startingRoots { Task { await self.refresh() } }
            }
        }
        do {
            let api = try authorizationAPI()
            let pendingRoots = vault.accounts[scope]?.pending.map { [$0.friendKey] } ?? []
            let roots = Array(observedRoots.union(pendingRoots).union([device.accountKey])).sorted()
            var response = try await api.snapshot(roots: roots, checkpoints: vault.checkpoints[origin] ?? [:])
            guard self.login?.credential == login.credential, refreshID == id else { return }
            guard var own = response.accounts[device.accountKey] else { throw V5IdentityError.untrusted }
            if own.devices[device.leafKey] == nil && !own.revoked.contains(device.leafKey) {
                try await api.append(event(operation: "enroll", account: own))
                response = try await api.snapshot(roots: roots, checkpoints: vault.checkpoints[origin] ?? [:])
                guard self.login?.credential == login.credential, refreshID == id, let enrolled = response.accounts[device.accountKey] else { return }
                own = enrolled
            }
            guard own.active(device) else { authorizationDeadline = nil; onRevoked?(); throw V5IdentityError.untrusted }
            guard own.hasCompleteSocial else { throw V5IdentityError.untrusted }
            var value = vault.accounts[scope] ?? SocialAccountState()
            var committed = SocialAccountState()
            for social in own.social {
                guard social.accountID == login.member.id else { throw V5IdentityError.changed }
                try apply(social, to: &committed)
                committed.version = social.version; committed.previousHash = social.digest
            }
            committed.pending = value.pending; committed.pendingRevocation = value.pendingRevocation
            if let pending = committed.pending, own.social.contains(where: { $0.digest == pending.digest }) { committed.pending = nil }
            if let target = committed.pendingRevocation, own.revoked.contains(target) { committed.pendingRevocation = nil }
            // Local removal intent survives an older, otherwise valid snapshot.
            if let pending = committed.pending, ["untrust", "remove_friend"].contains(pending.operation) { try apply(pending, to: &committed) }
            value = committed
            vault.accounts[scope] = value
            for (root, account) in response.accounts { vault.checkpoints[origin, default: [:]][root] = account.checkpoint }
            try persist()
            authorized = response.accounts; authorizationDeadline = response.deadline; hasSocialSnapshot = true
            // Server-owned labels and administrator bans may only reduce trust.
            let business = APIClient(baseURL: login.connection.apiURL, credential: login.credential, configuration: configuration)
            defer { business.close() }
            if let records = try? await business.identityBlacklist(), self.login?.credential == login.credential, refreshID == id,
               Set(records.map(\.sequence)).count == records.count, records.allSatisfy({ ["account", "device"].contains($0.kind) }),
               blacklist.allSatisfy({ records.contains($0) }) { vault.blacklists[origin] = records }
            let labels = (try? await business.identityDevices()) ?? []
            guard self.login?.credential == login.credential, refreshID == id else { return }
            devices = own.devices.values.map { registered in
                let label = labels.first { $0.device == registered }
                return RegisteredIdentityDevice(deviceKey: registered.leafKey, accountID: login.member.id, accountKey: device.accountKey,
                    device: registered, name: label?.name ?? "", platform: label?.platform ?? "", createdAt: label?.createdAt ?? 0,
                    lastLoginAt: label?.lastLoginAt, revoked: own.revoked.contains(registered.leafKey))
            }
            try persist()
            // Re-read pending intent after network suspension; UI may have added a removal.
            value = vault.accounts[scope] ?? value
            if let target = value.pendingRevocation {
                if !own.revoked.contains(target) { try await api.append(event(operation: "revoke", account: own, target: target)) }
                guard self.login?.credential == login.credential, refreshID == id else { return }
                // Keep the pending marker until a signed snapshot confirms it.
                refreshID = nil; await refresh(); return
            }
            if let pending = value.pending {
                var rebased = SocialIdentityEvent(origin: origin, accountID: login.member.id, version: Int64(own.social.count) + 1,
                    previousHash: own.social.last?.digest ?? "", operation: pending.operation, friendID: pending.friendID,
                    friendKey: pending.friendKey, deviceKey: pending.deviceKey, name: pending.name, signer: try identity.requireDevice())
                rebased.signature = try identity.signIdentityMessage(rebased.message)
                value.pending = rebased; vault.accounts[scope] = value; try persist()
                try await api.append(event(operation: "social", account: own, social: rebased))
                guard self.login?.credential == login.credential, refreshID == id else { return }
                refreshID = nil; await refresh(); return
            }
            failure = nil; onChange?()
        } catch { if self.login?.credential == login.credential { failure = error.localizedDescription; onChange?() } }
    }
    func revokeDevice(_ key: String) async throws {
        ClientLog.shared.record(.identity, "revokeDevice")
        guard let login, let device = login.deviceIdentity, device.certificates.last?.canEnroll == true,
              key != device.leafKey, authorized[device.accountKey]?.devices[key] != nil else { throw V5IdentityError.untrusted }
        vault.localRevocations[origin + "|" + device.accountKey, default: []].insert(key)
        var value = vault.accounts[scope] ?? SocialAccountState()
        guard value.pendingRevocation == nil || value.pendingRevocation == key else { throw V5IdentityError.changed }
        value.pendingRevocation = key; vault.accounts[scope] = value; try persist()
        await refresh()
        guard authorized[device.accountKey]?.revoked.contains(key) == true else {
            throw IdentitySetupError.invalid("本机已禁用此设备；授权服务尚未确认撤销，请保持联网重试。")
        }
        let api = APIClient(baseURL: login.connection.apiURL, credential: login.credential, configuration: configuration); defer { api.close() }
        try? await api.revokeIdentityDevice(key)
    }
    func change(operation: String, friendID: String, device: V5Device, name: String, deviceKey: String? = nil) async {
        let action: StaticString
        switch operation {
        case "friend": action = "addFriend"
        case "remove_friend": action = "removeFriend"
        case "trust": action = "trustDevice"
        case "untrust": action = "untrustDevice"
        default: action = "changeTrust"
        }
        ClientLog.shared.record(.identity, action, outcome: .started)
        guard let login, (operation != "trust" && operation != "friend") || !blocked(accountID: friendID, device: device) else { return }
        let span = ClientLog.shared.begin()
        do {
            guard vault.accounts[scope]?.pending == nil else { throw IdentitySetupError.invalid("请先同步上一次好友修改。") }
            var value = vault.accounts[scope] ?? SocialAccountState()
            var event = SocialIdentityEvent(origin: origin, accountID: login.member.id, version: value.version + 1, previousHash: value.previousHash, operation: operation,
                friendID: friendID, friendKey: device.accountKey, deviceKey: ["trust", "untrust"].contains(operation) ? (deviceKey ?? device.leafKey) : "", name: name, signer: try identity.requireDevice())
            event.signature = try identity.signIdentityMessage(event.message)
            // Persist the signed intent before returning; local revocations take
            // effect even if upload is interrupted and cannot be rolled back by
            // an older server response.
            if ["untrust", "remove_friend"].contains(operation) { try apply(event, to: &value) }; value.pending = event; vault.accounts[scope] = value; try persist()
            await refresh()
            ClientLog.shared.finish(span, .identity, action)
        } catch {
            ClientLog.shared.finish(span, .identity, action, error: error)
            failure = error.localizedDescription
        }
    }
    func blocked(accountID: String, device: V5Device) -> Bool {
        authorized[device.accountKey]?.revoked.contains(device.leafKey) == true ||
        vault.localRevocations[origin + "|" + device.accountKey]?.contains(device.leafKey) == true ||
        blacklist.contains { ($0.kind == "account" && ($0.subject == accountID || $0.accountKey == device.accountKey)) || ($0.kind == "device" && $0.subject == device.leafKey) }
    }
    func trusts(accountID: String, device: V5Device) -> Bool {
        hasSocialSnapshot && deviceAuthorized(device) && !blocked(accountID: accountID, device: device) && friends.contains { $0.accountID == accountID && $0.accountKey == device.accountKey && $0.trustedDevices.contains(device.leafKey) }
    }
    private func apply(_ event: SocialIdentityEvent, to value: inout SocialAccountState) throws {
        _ = try V5Crypto.bytes(event.friendKey, count: 32)
        let index = value.friends.firstIndex { $0.accountID == event.friendID && $0.accountKey == event.friendKey }
        switch event.operation {
        case "friend": if let index { value.friends[index].name = event.name } else { value.friends.append(IdentityFriend(accountID: event.friendID, accountKey: event.friendKey, name: event.name)) }
        case "remove_friend": if let index { value.friends.remove(at: index) }
        case "trust": _ = try V5Crypto.bytes(event.deviceKey, count: 32); if index == nil { value.friends.append(IdentityFriend(accountID: event.friendID, accountKey: event.friendKey, name: event.name)) }; let target = value.friends.firstIndex { $0.accountID == event.friendID && $0.accountKey == event.friendKey }!; value.friends[target].trustedDevices.insert(event.deviceKey)
        case "untrust": if let index { value.friends[index].trustedDevices.remove(event.deviceKey) }
        default: throw V5IdentityError.invalid
        }
    }
    func clearAll() throws { task?.cancel(); task = nil; pathMonitor?.cancel(); pathMonitor = nil; login = nil; refreshID = nil; authorizationDeadline = nil; authorized = [:]; observedRoots = []; hasSocialSnapshot = false; try persistence.clear(); vault = SocialVault(); storageCorrupt = false; failure = nil; devices = []; revision &+= 1 }
}
