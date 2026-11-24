import ChirpMLS
import Foundation

struct AuthorizationTrust: Codable, Sendable {
    let publicKey: String
    enum CodingKeys: String, CodingKey { case publicKey = "public_key" }

    func configuration(origin: String) throws -> AuthorizationConfiguration {
        let server = try ServerAddress.origin(origin)
        let configuration = AuthorizationConfiguration(origin: ServerAddress.identityOrigin(server),
            url: server.appendingPathComponent("authorization"), publicKey: publicKey)
        try configuration.validateApplicationEndpoint()
        return configuration
    }
}

// Addresses are session state derived from a validated connection, never bundled trust data.
struct AuthorizationConfiguration: Sendable {
    let origin: String
    let url: URL
    let publicKey: String

    func validate(origin expected: String) throws {
        guard origin == expected else { throw V5IdentityError.untrusted }
        _ = try V5Crypto.bytes(publicKey, count: 32)
        _ = try ServerAddress.validate(url.absoluteString)
        guard url.query == nil, url.fragment == nil else { throw V5IdentityError.invalid }
    }

    // Production authorization is served by the application. The pinned key
    // authenticates snapshots; it cannot prove freshness against a compromised server.
    func validateApplicationEndpoint() throws {
        let application = try ServerAddress.origin(origin)
        guard ServerAddress.sameOrigin(application, url), url.path == "/authorization" else { throw V5IdentityError.untrusted }
        try validate(origin: origin)
    }

    static func bundled(origin: String) throws -> Self {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle.main
        #endif
        guard let file = bundle.url(forResource: "AuthorizationTrust", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let trust = try? JSONDecoder().decode(AuthorizationTrust.self, from: data) else {
            throw IdentitySetupError.invalid("未配置服务端 V5 授权签名公钥，无法开放聊天。请安装包含正确授权公钥的客户端。")
        }
        return try trust.configuration(origin: origin)
    }
}

struct AuthorizationEvent: Codable, Sendable {
    let origin: String
    let version: Int64
    let previousHash: String
    let operation: String
    let signer: V5Device
    var targetKey = ""
    var social: SocialIdentityEvent?
    var socialHash: String?
    var signature = ""
    var message: Data {
        V5Crypto.message("Chirp authorization event v5", [origin, String(version), previousHash, operation, signer.digest, targetKey, social?.digest ?? socialHash ?? ""])
    }
    var digest: String { V5Crypto.hash(V5Crypto.record("Chirp authorization event digest v5", [message, Data(signature.utf8)])) }
    enum CodingKeys: String, CodingKey { case origin, version, previousHash = "previous_hash", operation, signer, targetKey = "target_key", social, socialHash = "social_hash", signature }
}

struct AuthorizationRecord: Codable, Sendable {
    let event: AuthorizationEvent
    let acceptedAt: Int64
    enum CodingKeys: String, CodingKey { case event, acceptedAt = "accepted_at" }
}

struct AuthorizationAccount: Codable, Sendable {
    let root: String
    let records: [AuthorizationRecord]
}

struct AuthorizationCheckpoint: Codable, Sendable, Equatable {
    let version: Int64
    let hash: String
}

struct AuthorizedAccount: Sendable {
    let root: String
    var checkpoint = AuthorizationCheckpoint(version: 0, hash: "")
    var devices: [String: V5Device] = [:]
    var revoked: Set<String> = []
    var social: [SocialIdentityEvent] = []
    private var verifiedAt: Int64 = 0
    private var socialVersion: Int64 = 0
    private var socialHead = ""
    private(set) var hasCompleteSocial = true

    func active(_ device: V5Device, now: Int64 = Int64(Date().timeIntervalSince1970)) -> Bool {
        devices[device.leafKey] == device && !revoked.contains(device.leafKey) && (try? device.validate(now: max(now, verifiedAt))) != nil
    }

    static func verify(_ account: AuthorizationAccount, origin: String, issuedAt: Int64,
                       previous: AuthorizationCheckpoint?) throws -> Self {
        _ = try V5Crypto.bytes(account.root, count: 32)
        guard account.records.count <= 8192 else { throw V5IdentityError.invalid }
        if let previous, previous.version > 0 {
            guard previous.version <= account.records.count,
                  account.records[Int(previous.version)-1].event.digest == previous.hash else { throw V5IdentityError.changed }
        }
        var state = Self(root: account.root)
        var lastTime: Int64 = 0
        for record in account.records {
            let e = record.event
            guard record.acceptedAt > 0, record.acceptedAt >= lastTime, record.acceptedAt <= issuedAt,
                  e.origin == origin, e.signer.accountKey == account.root,
                  e.version == state.checkpoint.version + 1, e.previousHash == state.checkpoint.hash else { throw V5IdentityError.changed }
            try e.signer.validate(now: record.acceptedAt)
            try V5Crypto.verify(key: e.signer.leafKey, signature: e.signature, message: e.message)
            guard e.operation == "revoke" || e.version <= 4096 else { throw V5IdentityError.invalid }
            switch e.operation {
            case "enroll":
                guard e.social == nil, e.socialHash == nil, e.targetKey.isEmpty, state.devices.count < 128, state.devices[e.signer.leafKey] == nil,
                      !state.revoked.contains(e.signer.leafKey) else { throw V5IdentityError.untrusted }
                if e.signer.certificates.count > 1 {
                    let issuer = V5Device(accountKey: account.root, certificates: Array(e.signer.certificates.dropLast()))
                    guard state.active(issuer, now: record.acceptedAt), issuer.certificates.last?.canEnroll == true else { throw V5IdentityError.untrusted }
                } else {
                    guard e.signer.certificates.first?.issuerKey == account.root else { throw V5IdentityError.untrusted }
                }
                state.devices[e.signer.leafKey] = e.signer
            case "revoke":
                guard e.social == nil, e.socialHash == nil, state.active(e.signer, now: record.acceptedAt), e.signer.certificates.last?.canEnroll == true,
                      state.devices[e.targetKey] != nil, !state.revoked.contains(e.targetKey) else { throw V5IdentityError.untrusted }
                state.revoked.insert(e.targetKey)
            case "social":
                guard e.targetKey.isEmpty, state.active(e.signer, now: record.acceptedAt) else { throw V5IdentityError.untrusted }
                if let social = e.social {
                    guard e.socialHash == nil,
                          social.signer == e.signer, social.origin == origin,
                          social.version == state.socialVersion + 1, social.previousHash == state.socialHead,
                          !social.accountID.isEmpty, !social.friendID.isEmpty, social.accountID.utf8.count <= 128,
                          social.friendID.utf8.count <= 128, social.name.utf8.count <= 320 else { throw V5IdentityError.untrusted }
                    _ = try V5Crypto.bytes(social.friendKey, count: 32)
                    switch social.operation {
                    case "friend", "remove_friend": guard social.deviceKey.isEmpty else { throw V5IdentityError.invalid }
                    case "trust", "untrust": _ = try V5Crypto.bytes(social.deviceKey, count: 32)
                    default: throw V5IdentityError.invalid
                    }
                    try V5Crypto.verify(key: social.signer.leafKey, signature: social.signature, message: social.message)
                    state.social.append(social)
                    state.socialHead = social.digest
                } else {
                    guard let hash = e.socialHash else { throw V5IdentityError.invalid }
                    _ = try V5Crypto.bytes(hash, count: 32)
                    state.socialHead = hash; state.hasCompleteSocial = false
                }
                state.socialVersion += 1
            default: throw V5IdentityError.invalid
            }
            state.checkpoint = AuthorizationCheckpoint(version: e.version, hash: e.digest)
            lastTime = record.acceptedAt
        }
        // A rolled-back local wall clock cannot make a certificate older than
        // the authority's fresh, signed snapshot valid again.
        state.verifiedAt = issuedAt
        return state
    }
}

struct AuthorizationSnapshot: Codable, Sendable {
    let `protocol`: Int
    let origin: String
    let nonce: String
    let issuedAt: Int64
    let accounts: [AuthorizationAccount]
    enum CodingKeys: String, CodingKey { case `protocol`, origin, nonce, issuedAt = "issued_at", accounts }
}

struct AuthorizationEnvelope: Codable, Sendable {
    let payload: String
    let signature: String

    func verify(configuration: AuthorizationConfiguration, nonce: String, roots: [String],
                checkpoints: [String: AuthorizationCheckpoint]) throws -> [String: AuthorizedAccount] {
        guard let data = Data(base64Encoded: payload), data.count <= 6 * 1024 * 1024,
              data.base64EncodedString() == payload else { throw V5IdentityError.invalid }
        try V5Crypto.verify(key: configuration.publicKey, signature: signature,
            message: V5Crypto.message("Chirp authorization snapshot v5", [configuration.origin, nonce, V5Crypto.hash(data)]))
        let snapshot = try JSONDecoder().decode(AuthorizationSnapshot.self, from: data)
        guard snapshot.protocol == 5, snapshot.origin == configuration.origin, snapshot.nonce == nonce,
              snapshot.accounts.count == roots.count, Set(snapshot.accounts.map(\.root)) == Set(roots),
              snapshot.issuedAt > 0 else { throw V5IdentityError.changed }
        var verified: [String: AuthorizedAccount] = [:]
        for account in snapshot.accounts {
            verified[account.root] = try AuthorizedAccount.verify(account, origin: configuration.origin,
                issuedAt: snapshot.issuedAt, previous: checkpoints[account.root])
        }
        return verified
    }
}

final class AuthorizationAPI: Sendable {
    let configuration: AuthorizationConfiguration
    private let session: HTTPDataSession
    private let now: @Sendable () -> ContinuousClock.Instant
    private let device: V5Device?
    private let signer: (@MainActor @Sendable (Data) throws -> String)?
    init(configuration: AuthorizationConfiguration, network: URLSessionConfiguration? = nil,
         now: @escaping @Sendable () -> ContinuousClock.Instant = { .now }, device: V5Device? = nil,
         signer: (@MainActor @Sendable (Data) throws -> String)? = nil) throws {
        try configuration.validate(origin: configuration.origin)
        self.configuration = configuration
        self.now = now
        self.device = device; self.signer = signer
        let network = network ?? .ephemeral
        network.httpCookieStorage = nil; network.urlCache = nil
        network.timeoutIntervalForRequest = 10; network.timeoutIntervalForResource = 15
        session = HTTPDataSession(configuration: network)
    }
    deinit { session.close() }

    func snapshot(roots: [String], checkpoints: [String: AuthorizationCheckpoint]) async throws -> (accounts: [String: AuthorizedAccount], deadline: ContinuousClock.Instant) {
        guard !roots.isEmpty, Set(roots).count == roots.count else { throw V5IdentityError.invalid }
        var accounts: [String: AuthorizedAccount] = [:]
        var deadline = now().advanced(by: .seconds(60))
        // Each account is at most 2 MiB. Batching keeps complete history within
        // the signed response limit without accepting a truncated prefix.
        for start in stride(from: 0, to: roots.count, by: 2) {
            let result = try await snapshotBatch(roots: Array(roots[start..<min(start + 2, roots.count)]), checkpoints: checkpoints)
            accounts.merge(result.accounts) { _, new in new }; deadline = min(deadline, result.deadline)
        }
        guard deadline > now() else { throw V5IdentityError.expired }
        return (accounts, deadline)
    }

    private func snapshotBatch(roots: [String], checkpoints: [String: AuthorizationCheckpoint]) async throws -> (accounts: [String: AuthorizedAccount], deadline: ContinuousClock.Instant) {
        struct Request: Encodable {
            let origin: String; let nonce: String; let roots: [String]
            var device: V5Device?; var signedAt: Int64?; var signature: String?
            enum CodingKeys: String, CodingKey { case origin, nonce, roots, device, signedAt = "signed_at", signature }
        }
        guard !roots.isEmpty, roots.count <= 2, Set(roots).count == roots.count else { throw V5IdentityError.invalid }
        let nonce = V5Crypto.random().base64EncodedString(), started = now()
        var request = Request(origin: configuration.origin, nonce: nonce, roots: roots)
        if let device, let signer {
            let signedAt = Int64(Date().timeIntervalSince1970)
            request.device = device; request.signedAt = signedAt
            request.signature = try await signer(V5Crypto.message("Chirp authorization read v5",
                [configuration.origin, nonce, device.digest, String(signedAt)] + roots.sorted()))
        }
        let data = try await post("snapshot", body: JSONEncoder().encode(request))
        let envelope = try JSONDecoder().decode(AuthorizationEnvelope.self, from: data)
        let accounts = try envelope.verify(configuration: configuration, nonce: nonce, roots: roots, checkpoints: checkpoints)
        let deadline = started.advanced(by: .seconds(60))
        guard deadline > now() else { throw V5IdentityError.expired }
        return (accounts, deadline)
    }

    func append(_ event: AuthorizationEvent) async throws { _ = try await post("append", body: JSONEncoder().encode(event)) }

    private func post(_ path: String, body: Data, operation: StaticString = #function) async throws -> Data {
        var request = URLRequest(url: configuration.url.appendingPathComponent("v5/" + path))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.data(for: request, maxBytes: 9 * 1024 * 1024, operation: operation)
        guard let response = response as? HTTPURLResponse else { throw V5IdentityError.invalid }
        guard response.statusCode == (path == "append" ? 204 : 200) else {
            throw ClientFailure.response(data: data, status: response.statusCode)
        }
        return data
    }
}
