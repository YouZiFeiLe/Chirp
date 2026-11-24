import ChirpMLS
import CryptoKit
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Suite struct AuthorizationTests {
    private let origin = "https://fixture.test:443"

    @Test func bundledKeyWorksAcrossServersAndNormalizesTrailingSlashes() throws {
        var publicKeys = Set<String>()
        for (address, expectedOrigin, expectedURL) in [
            ("https://chirp.first.test", "https://chirp.first.test:443", "https://chirp.first.test/authorization"),
            ("https://chirp.first.test/", "https://chirp.first.test:443", "https://chirp.first.test/authorization"),
            ("https://chirp.second.test", "https://chirp.second.test:443", "https://chirp.second.test/authorization"),
            ("https://chirp.second.test/", "https://chirp.second.test:443", "https://chirp.second.test/authorization"),
            ("  https://CHIRP.second.test:8443/  ", "https://chirp.second.test:8443", "https://chirp.second.test:8443/authorization")
        ] {
            let config = try AuthorizationConfiguration.bundled(origin: address)
            #expect(config.origin == expectedOrigin)
            #expect(config.url.absoluteString == expectedURL)
            _ = try V5Crypto.bytes(config.publicKey, count: 32)
            publicKeys.insert(config.publicKey)
        }
        #expect(publicKeys.count == 1)
    }

    @Test func derivedAuthorizationRejectsUnsafeAddressesAndInvalidPublicKeys() throws {
        let trust = AuthorizationTrust(publicKey: Data(repeating: 1, count: 32).base64EncodedString())
        for address in ["http://chirp.test", "https://user:pass@chirp.test", "https://chirp.test?next=x", "https://chirp.test#fragment", "https://chirp.test/path"] {
            #expect(throws: (any Error).self) { try trust.configuration(origin: address) }
        }
        #expect(throws: (any Error).self) { try AuthorizationTrust(publicKey: "invalid").configuration(origin: origin) }
    }

    @Test func sharingPinnedKeyAcrossServersDoesNotAllowCrossOriginSnapshotReplay() throws {
        let key = Data(repeating: 12, count: 32)
        let trust = AuthorizationTrust(publicKey: try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation.base64EncodedString())
        let first = try trust.configuration(origin: "https://first.test/")
        let second = try trust.configuration(origin: "https://second.test")
        let nonce = V5Crypto.random().base64EncodedString()
        let payload = try JSONEncoder().encode(AuthorizationSnapshot(protocol: 5, origin: first.origin, nonce: nonce,
            issuedAt: Int64(Date().timeIntervalSince1970), accounts: []))
        let signature = try V5Crypto.sign(key, V5Crypto.message("Chirp authorization snapshot v5", [first.origin, nonce, V5Crypto.hash(payload)]))
        let envelope = AuthorizationEnvelope(payload: payload.base64EncodedString(), signature: signature)
        _ = try envelope.verify(configuration: first, nonce: nonce, roots: [], checkpoints: [:])
        #expect(throws: (any Error).self) { try envelope.verify(configuration: second, nonce: nonce, roots: [], checkpoints: [:]) }
    }

    @Test func productionAuthorizationUsesApplicationEndpoint() throws {
        let publicKey = Data(repeating: 1, count: 32).base64EncodedString()
        for endpoint in ["https://fixture.test/authorization", "https://fixture.test:443/authorization"] {
            try AuthorizationConfiguration(origin: origin, url: URL(string: endpoint)!, publicKey: publicKey).validateApplicationEndpoint()
        }
        for endpoint in ["https://other.test/authorization", "https://fixture.test:8443/authorization", "https://fixture.test/v5", "https://fixture.test/authorization?redirect=x"] {
            #expect(throws: (any Error).self) {
                try AuthorizationConfiguration(origin: origin, url: URL(string: endpoint)!, publicKey: publicKey).validateApplicationEndpoint()
            }
        }
    }

    private func enrollment(_ fixture: V5TestIdentity) throws -> AuthorizationAccount {
        var event = AuthorizationEvent(origin: origin, version: 1, previousHash: "", operation: "enroll", signer: fixture.device)
        event.signature = try V5Crypto.sign(fixture.key, event.message)
        return AuthorizationAccount(root: fixture.device.accountKey, records: [AuthorizationRecord(event: event, acceptedAt: Int64(Date().timeIntervalSince1970))])
    }

    @Test func challengeAndPinnedKeyAreRequiredEvenForValidSignedHistory() throws {
        let fixture = try V5TestIdentity("v5-snapshot")
        let account = try enrollment(fixture)
        let key = Data(repeating: 12, count: 32)
        let publicKey = try Curve25519.Signing.PrivateKey(rawRepresentation: key).publicKey.rawRepresentation.base64EncodedString()
        let config = AuthorizationConfiguration(origin: origin, url: URL(string: "https://fixture.test/authorization")!, publicKey: publicKey)
        let nonce = V5Crypto.random().base64EncodedString()
        let payload = try JSONEncoder().encode(AuthorizationSnapshot(protocol: 5, origin: origin, nonce: nonce,
            issuedAt: Int64(Date().timeIntervalSince1970), accounts: [account]))
        let signature = try V5Crypto.sign(key, V5Crypto.message("Chirp authorization snapshot v5", [origin, nonce, V5Crypto.hash(payload)]))
        let envelope = AuthorizationEnvelope(payload: payload.base64EncodedString(), signature: signature)
        let verified = try envelope.verify(configuration: config, nonce: nonce, roots: [account.root], checkpoints: [:])
        #expect(verified[account.root]?.active(fixture.device) == true)
        #expect(throws: (any Error).self) {
            try envelope.verify(configuration: config, nonce: V5Crypto.random().base64EncodedString(), roots: [account.root], checkpoints: [:])
        }
        let replacement = AuthorizationConfiguration(origin: origin, url: config.url, publicKey: fixture.device.leafKey)
        #expect(throws: (any Error).self) { try envelope.verify(configuration: replacement, nonce: nonce, roots: [account.root], checkpoints: [:]) }
        #expect(throws: (any Error).self) { try envelope.verify(configuration: config, nonce: nonce, roots: [], checkpoints: [:]) }
    }

    @Test func committedRevocationCannotBeRolledBackOrUsedToAuthorizeNewTrust() throws {
        let fixture = try V5TestIdentity("v5-revocation")
        let original = try enrollment(fixture)
        var revoke = AuthorizationEvent(origin: origin, version: 2, previousHash: original.records[0].event.digest,
            operation: "revoke", signer: fixture.device, targetKey: fixture.device.leafKey)
        revoke.signature = try V5Crypto.sign(fixture.key, revoke.message)
        let now = Int64(Date().timeIntervalSince1970)
        let revoked = AuthorizationAccount(root: original.root, records: original.records + [AuthorizationRecord(event: revoke, acceptedAt: now)])
        let state = try AuthorizedAccount.verify(revoked, origin: origin, issuedAt: now, previous: nil)
        #expect(!state.active(fixture.device))
        #expect(throws: (any Error).self) { try AuthorizedAccount.verify(original, origin: origin, issuedAt: now, previous: state.checkpoint) }
        #expect(throws: (any Error).self) {
            try AuthorizedAccount.verify(AuthorizationAccount(root: original.root, records: []), origin: origin, issuedAt: now, previous: state.checkpoint)
        }
        var trust = SocialIdentityEvent(origin: origin, accountID: "member", version: 1, previousHash: "", operation: "trust",
            friendID: "friend", friendKey: fixture.device.accountKey, deviceKey: fixture.device.leafKey, name: "Friend", signer: fixture.device)
        trust.signature = try V5Crypto.sign(fixture.key, trust.message)
        var event = AuthorizationEvent(origin: origin, version: 3, previousHash: revoke.digest, operation: "social", signer: fixture.device, social: trust)
        event.signature = try V5Crypto.sign(fixture.key, event.message)
        let invalid = AuthorizationAccount(root: original.root, records: revoked.records + [AuthorizationRecord(event: event, acceptedAt: now)])
        #expect(throws: (any Error).self) { try AuthorizedAccount.verify(invalid, origin: origin, issuedAt: now, previous: state.checkpoint) }
    }

    @Test func authorityTimePreventsLocalClockRollbackFromRevivingExpiredCertificates() throws {
        let fixture = try V5TestIdentity("v5-clock-rollback")
        let account = try enrollment(fixture)
        let expiredAt = try #require(fixture.device.certificates.last).notAfter + 1
        let state = try AuthorizedAccount.verify(account, origin: origin, issuedAt: expiredAt, previous: nil)
        #expect(!state.active(fixture.device, now: account.records[0].acceptedAt))
    }

    @Test func keyAgeCannotBeRenewedByAnotherBeginOrByServerLeases() throws {
        let start = ContinuousClock.now
        var key = KeyLifetime(); key.begin(now: start)
        key.begin(now: start.advanced(by: .seconds(100)))
        #expect(key.shouldRotate(now: start.advanced(by: .seconds(90))))
        var lease = MediaLease()
        try lease.renew(requestStartedAt: start.advanced(by: .seconds(119)), milliseconds: 3000)
        #expect(lease.isValid(at: start.advanced(by: .seconds(120))))
        #expect(!key.isValid(now: start.advanced(by: .seconds(120))))
    }

    @Test func expiredCaptureAuthorizationCannotBeRevivedByDelayedLease() {
        let gate = MediaContentGate(), start = ContinuousClock.now
        gate.install(keyDeadline: start.advanced(by: .seconds(120)))
        #expect(!gate.permitsCapture(now: start)) // Waiting for all-ready is not fatal.
        #expect(!gate.permitsReceiving(now: start))
        #expect(gate.authorize(until: start.advanced(by: .seconds(3)), now: start))
        #expect(gate.permitsReceiving(now: start) && !gate.permitsCapture(now: start))
        gate.microphone(true)
        #expect(gate.permitsCapture(now: start.advanced(by: .seconds(2))))
        #expect(!gate.permitsCapture(now: start.advanced(by: .seconds(3))))
        #expect(!gate.permitsReceiving(now: start.advanced(by: .seconds(3))))
        #expect(!gate.authorize(until: start.advanced(by: .seconds(6)), now: start.advanced(by: .seconds(4))))
        gate.install(keyDeadline: start.advanced(by: .seconds(10)))
        #expect(gate.authorize(until: start.advanced(by: .seconds(200)), now: start.advanced(by: .seconds(5))))
        gate.microphone(true)
        #expect(!gate.permitsCapture(now: start.advanced(by: .seconds(10))))
    }

    @Test @MainActor func captureExpiryDoesNotRequireMainActorScheduling() {
        let gate = MediaContentGate(), result = Mutex<Bool?>(nil), done = DispatchSemaphore(value: 0)
        let start = ContinuousClock.now, retired = Mutex(false)
        gate.install(keyDeadline: start.advanced(by: .seconds(120))) { retired.withLock { $0 = true } }
        #expect(gate.authorize(until: start.advanced(by: .milliseconds(30))))
        gate.microphone(true)
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + .milliseconds(60)) {
            result.withLock { $0 = gate.permitsCapture() }; done.signal()
        }
        // Intentionally block the UI executor. The audio-side check still closes.
        #expect(done.wait(timeout: .now() + .seconds(2)) == .success)
        #expect(result.withLock { $0 } == false)
        #expect(retired.withLock { $0 })
    }
}


private final class BatchAuthorityProtocol: URLProtocol, @unchecked Sendable {
    struct State: Sendable {
        var requests: [(String, [String])] = []
        var failAt = 0
        var advanceSeconds = 0
        var now = ContinuousClock.now
    }
    static let state = Mutex(State())
    static let key = Data(repeating: 27, count: 32)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        do {
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
            }
            struct Input: Decodable { let origin: String; let nonce: String; let roots: [String] }
            let input = try JSONDecoder().decode(Input.self, from: data)
            let nonce = Self.state.withLock { value in
                value.requests.append((input.nonce, input.roots)); value.now = value.now.advanced(by: .seconds(value.advanceSeconds))
                return value.requests.count == value.failAt ? V5Crypto.random().base64EncodedString() : input.nonce
            }
            let payload = try JSONEncoder().encode(AuthorizationSnapshot(protocol: 5, origin: input.origin, nonce: nonce,
                issuedAt: Int64(Date().timeIntervalSince1970), accounts: input.roots.map { AuthorizationAccount(root: $0, records: []) }))
            let envelope = AuthorizationEnvelope(payload: payload.base64EncodedString(), signature: try V5Crypto.sign(Self.key,
                V5Crypto.message("Chirp authorization snapshot v5", [input.origin, nonce, V5Crypto.hash(payload)])))
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONEncoder().encode(envelope)); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
}

@Suite(.serialized) struct AuthorizationBatchTests {
    private func api() throws -> AuthorizationAPI {
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [BatchAuthorityProtocol.self]
        let key = try Curve25519.Signing.PrivateKey(rawRepresentation: BatchAuthorityProtocol.key).publicKey.rawRepresentation.base64EncodedString()
        return try AuthorizationAPI(configuration: AuthorizationConfiguration(origin: "https://fixture.test:443", url: URL(string: "https://fixture.test/authorization")!, publicKey: key), network: network,
            now: { BatchAuthorityProtocol.state.withLock { $0.now } })
    }
    private var roots: [String] { (0..<5).map { V5Crypto.hash(Data("root-\($0)".utf8)) } }
    @Test func completeBatchesHaveDistinctChallengesAndExactRoots() async throws {
        BatchAuthorityProtocol.state.withLock { $0 = .init() }
        let result = try await api().snapshot(roots: roots, checkpoints: [:])
        #expect(Set(result.accounts.keys) == Set(roots))
        let requests = BatchAuthorityProtocol.state.withLock { $0.requests }
        #expect(requests.map { $0.1.count } == [2, 2, 1])
        #expect(Set(requests.map { $0.0 }).count == 3)
    }
    @Test func wrongChallengeInLaterBatchRejectsWholeRefresh() async throws {
        BatchAuthorityProtocol.state.withLock { $0 = .init(failAt: 2) }
        await #expect(throws: (any Error).self) { try await api().snapshot(roots: roots, checkpoints: [:]) }
        #expect(BatchAuthorityProtocol.state.withLock { $0.requests.count } == 2)
    }
    @Test func totalRequestTimeConsumesFirstBatchFreshness() async throws {
        BatchAuthorityProtocol.state.withLock { $0 = .init(advanceSeconds: 31) }
        await #expect(throws: (any Error).self) { try await api().snapshot(roots: roots, checkpoints: [:]) }
    }
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_AUTHORIZATION_TEST_URL"] != nil))
func swiftClientVerifiesApplicationAuthorizationEnrollmentRevocationAndChallenge() async throws {
    let environment = ProcessInfo.processInfo.environment
    let url = try #require(environment["CHIRP_AUTHORIZATION_TEST_URL"].flatMap(URL.init(string:)))
    let key = try #require(environment["CHIRP_AUTHORIZATION_TEST_KEY"])
    let configuration = AuthorizationConfiguration(origin: "https://fixture.test:443", url: url, publicKey: key)
    let fixture = try V5TestIdentity("real-go-authority-v5")
    let signingKey = fixture.key
    let api = try AuthorizationAPI(configuration: configuration, device: fixture.device, signer: { try V5Crypto.sign(signingKey, $0) })
    let root = fixture.device.accountKey
    let empty = try await api.snapshot(roots: [root], checkpoints: [:])
    #expect(empty.accounts[root]?.checkpoint.version == 0)
    var enrollment = AuthorizationEvent(origin: configuration.origin, version: 1, previousHash: "", operation: "enroll", signer: fixture.device)
    enrollment.signature = try V5Crypto.sign(fixture.key, enrollment.message)
    try await api.append(enrollment)
    let enrolled = try await api.snapshot(roots: [root], checkpoints: [:])
    let state = try #require(enrolled.accounts[root])
    #expect(state.active(fixture.device))
    var social = SocialIdentityEvent(origin: configuration.origin, accountID: "member", version: 1, previousHash: "", operation: "trust",
        friendID: "friend", friendKey: root, deviceKey: fixture.device.leafKey, name: "Friend", signer: fixture.device)
    social.signature = try V5Crypto.sign(fixture.key, social.message)
    var socialEvent = AuthorizationEvent(origin: configuration.origin, version: 2, previousHash: state.checkpoint.hash,
        operation: "social", signer: fixture.device, social: social)
    socialEvent.signature = try V5Crypto.sign(fixture.key, socialEvent.message)
    try await api.append(socialEvent)
    let otherRoot = V5Crypto.hash(Data("unregistered peer root".utf8))
    let trusted = try await api.snapshot(roots: [otherRoot, root], checkpoints: [root: state.checkpoint])
    #expect(trusted.accounts[root]?.social.first?.digest == social.digest)
    let peerAPI = try AuthorizationAPI(configuration: configuration)
    let peerView = try await peerAPI.snapshot(roots: [root], checkpoints: [root: state.checkpoint])
    #expect(peerView.accounts[root]?.hasCompleteSocial == false)
    #expect(peerView.accounts[root]?.social.isEmpty == true)
    #expect(peerView.accounts[root]?.active(fixture.device) == true)
    #expect(peerView.accounts[root]?.checkpoint == trusted.accounts[root]?.checkpoint)
    var revoke = AuthorizationEvent(origin: configuration.origin, version: 3, previousHash: socialEvent.digest,
        operation: "revoke", signer: fixture.device, targetKey: fixture.device.leafKey)
    revoke.signature = try V5Crypto.sign(fixture.key, revoke.message)
    try await api.append(revoke)
    let revoked = try await api.snapshot(roots: [root], checkpoints: [root: state.checkpoint])
    #expect(revoked.accounts[root]?.active(fixture.device) == false)
    var invalid = AuthorizationEvent(origin: configuration.origin, version: 4, previousHash: revoke.digest,
        operation: "enroll", signer: fixture.device)
    invalid.signature = try V5Crypto.sign(fixture.key, invalid.message)
    await #expect(throws: (any Error).self) { try await api.append(invalid) }
    try await api.append(enrollment) // Idempotence does not undo revocation.
    let final = try await api.snapshot(roots: [root], checkpoints: [root: try #require(revoked.accounts[root]).checkpoint])
    #expect(final.accounts[root]?.checkpoint.version == 3)
    #expect(final.accounts[root]?.active(fixture.device) == false)
}
