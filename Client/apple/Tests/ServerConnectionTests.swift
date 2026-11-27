import ChirpMLS
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

let testClientIdentity = ClientIdentity(platform: "macos", version: "0.14.0", build: 14)
let testClientPolicy = ClientVersionPolicy(platform: "macos", latestVersion: "0.14.0", latestBuild: 14, minimumVersion: "0.14.0", minimumBuild: 14)

// Complete deployment fixtures are confined to tests; production requires discovery.
func testEndpointValues(api: String = "./", origin: String) -> [String: String] {
    ["api_base_url": api, "health_url": "healthz", "authorization_url": origin + "/",
     "registration_url": origin + "/register", "token_url": origin + "/api/client/exchange",
     "device_start_url": origin + "/api/client/device/start", "device_poll_url": origin + "/api/client/device/poll",
     "device_cancel_url": origin + "/api/client/device/cancel", "device_verification_url": origin + "/device",
     "group_base_url": "v1/group"]
}
func testClientConfiguration(origin: String = "https://keys.example.test:8443", overrides: [String: String] = [:]) throws -> Data {
    let endpoints = testEndpointValues(origin: origin).merging(overrides) { _, value in value }
    return try JSONSerialization.data(withJSONObject: ["service": "chirp", "protocol_version": 5, "passkey_origin": origin,
        "default_room_id": "friends", "endpoints": endpoints,
        "client_policy": ["platform": "macos", "latest_version": "0.14.0", "latest_build": 14, "minimum_version": "0.14.0", "minimum_build": 14],
        "capabilities": ["registration": true, "device_login": true, "dynamic_rooms": true, "state_events": true, "attachment_protocol": 3, "max_members": 0, "max_room_participants": 0]])
}
extension ServerConnection {
    init(apiURL: URL, passkeyOrigin: URL, overrides: [String: String] = [:]) throws {
        let endpoints = try JSONDecoder().decode(ClientEndpoints.self, from: JSONSerialization.data(withJSONObject:
            testEndpointValues(origin: passkeyOrigin.absoluteString).merging(overrides) { _, value in value }))
        try self.init(discoveryURL: apiURL, passkeyOrigin: passkeyOrigin, endpoints: endpoints, defaultRoomID: "friends",
            capabilities: ClientCapabilities(registration: true, deviceLogin: true, dynamicRooms: true, stateEvents: true, attachmentProtocol: 3, maxMembers: 0, maxRoomParticipants: 0), client: testClientIdentity, clientPolicy: testClientPolicy)
    }
}

let testServerConnection = try! ServerConnection(apiURL: URL(string: "https://api.example.test")!,
                                                passkeyOrigin: URL(string: "https://keys.example.test")!)

private final class ConnectionURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: Data; var mime = "application/json" }
    static let state = Mutex((replies: [String: Reply](), requests: [URLRequest]()))
    static let paused = Mutex((enabled: false, pending: [(ConnectionURLProtocol, Reply)]()))
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let reply = Self.state.withLock { state in
            state.requests.append(request)
            return state.replies[request.url!.absoluteString]
        }
        guard let reply else { client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost)); return }
        let held = Self.paused.withLock { state in
            guard state.enabled else { return false }
            state.pending.append((self, reply))
            return true
        }
        if !held { respond(reply) }
    }
    private func respond(_ reply: Reply) {
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": reply.mime])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    static func release() {
        let pending = paused.withLock { state in
            let pending = state.pending
            state = (false, [])
            return pending
        }
        for (transport, reply) in pending { transport.respond(reply) }
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct ServerConnectionTests {
    private func api(_ overrides: [String: ConnectionURLProtocol.Reply] = [:]) throws -> ServerConnectionAPI {
        let config = try testClientConfiguration()
        var replies: [String: ConnectionURLProtocol.Reply] = [
            "https://api.example.test/v1/client-config": .init(status: 200, body: config),
            "https://api.example.test/healthz": .init(status: 200, body: Data(#"{"status":"ok","service":"chirp"}"#.utf8)),
            "https://keys.example.test:8443/healthz": .init(status: 200, body: Data(#"{"status":"ok","service":"passkey"}"#.utf8)),
        ]
        replies.merge(overrides) { _, new in new }
        ConnectionURLProtocol.state.withLock { $0 = (replies, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        return ServerConnectionAPI(configuration: configuration, identity: testClientIdentity)
    }

    @Test(arguments: ["resume-v1_", "resume_"])
    func savedLoginProvesPossessionAtThePinnedOriginAndKeepsItsDeadline(prefix: String) async throws {
        let origin = "https://keys.example.test:8443", account = "member_original", participant = account + ".login_original"
        let identity = DeviceIdentityStore(persistence: MemoryIdentityPersistence())
        try identity.select(origin: origin, accountID: account)
        let device = try identity.makeCandidate(rootSeed: V5Crypto.random())
        try identity.markBound()
        let expiresAt = Date().addingTimeInterval(3600)
        func response(_ marker: String, expiry: Date) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["member": ["id": account, "display_name": "Test"],
                "credential": "chirp_" + String(repeating: marker, count: 43), "participant_identity": participant,
                "device_identity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(device)),
                "expires_at": expiry.timeIntervalSince1970])
        }
        let connection = try ServerConnection(apiURL: testServerConnection.apiURL, passkeyOrigin: URL(string: origin)!)
        let original = try ClientSession(data: response("a", expiry: expiresAt), connection: connection)
        let token = prefix + String(repeating: "r", count: 43), nonce = String(repeating: "n", count: 43)
        let ticket = try #require(SavedLogin(session: original, token: token))
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(ticket)) as? [String: Any])
        #expect(legacy["sessionExpiresAt"] == nil)
        legacy["sessionExpiresAt"] = legacy["expiresAt"]
        legacy["expiresAt"] = Date.distantPast.timeIntervalSinceReferenceDate
        let older = try JSONDecoder().decode(SavedLogin.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(older.expiresAt == original.expiresAt)
        let challengeURL = origin + "/api/client/resume/challenge", completeURL = origin + "/api/client/resume/complete"
        let discovery = try api([challengeURL: .init(status: 200, body: JSONEncoder().encode(["challenge": nonce])),
                                 completeURL: .init(status: 200, body: response("b", expiry: expiresAt.addingTimeInterval(600)))])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let clock = NetworkClock(query: { [NetworkTimeSample(utc: Date(), received: .now, roundTrip: .zero)] })
        let result = try await ticket.restore(identity: identity, clock: clock, discovery: discovery, configuration: configuration)
        #expect(result.credential != original.credential && result.participantIdentity == participant)
        #expect(result.expiresAt == original.expiresAt && result.expiresAt == ticket.expiresAt)
        let posts = ConnectionURLProtocol.state.withLock { $0.requests.filter { $0.httpMethod == "POST" } }
        #expect(posts.map { $0.url?.absoluteString } == [challengeURL, completeURL])
        let request = try #require(posts.last)
        let body: [String: String]
        if let data = request.httpBody { body = try JSONDecoder().decode([String: String].self, from: data) }
        else {
            let stream = try #require(request.httpBodyStream)
            stream.open()
            defer { stream.close() }
            body = try #require(JSONSerialization.jsonObject(with: stream) as? [String: String])
        }
        #expect(body["resume_token"] == token && body.count == 2)
        let signature = try #require(body["signature"])
        let expectedDomain = prefix == "resume-v1_" ? "Chirp login resumption v1" : "Chirp Apple login resumption v1"
        let message = V5Crypto.message(expectedDomain, [origin, "macos", participant,
            V5Crypto.hash(Data(token.utf8)), nonce, device.digest])
        try V5Crypto.verify(key: device.leafKey, signature: signature, message: message)
    }

    @Test func freshInstallIsEmptyAndOnlySuccessfulChecksPersist() async throws {
        let suite = "ServerSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        #expect(settings.address.isEmpty && settings.connection == nil)
        let client = try api()
        await settings.confirm(using: client)
        #expect(settings.connection == nil && defaults.data(forKey: ServerSettings.preferenceKey) == nil)
        #expect(ConnectionURLProtocol.state.withLock { $0.requests.isEmpty })
        settings.address = "  https://API.example.test:443/  "
        await settings.confirm(using: client)
        let connection = try #require(settings.connection)
        #expect(settings.address == "https://api.example.test")
        #expect(connection.passkeyOrigin.absoluteString == "https://keys.example.test:8443")
        #expect(settings.notice?.localized(in: AppLanguage.simplifiedChinese.locale) == "地址保存成功")
        #expect(!settings.isChecking)
        let restored = ServerSettings(defaults: defaults)
        #expect(restored.connection == connection && restored.address == settings.address)
        let persisted = try #require(defaults.data(forKey: ServerSettings.preferenceKey))
        settings.address = "https://unreachable.example.test"
        #expect(settings.connection == nil)
        await settings.confirm(using: client)
        #expect(settings.connection == nil && settings.failure != nil)
        #expect(defaults.data(forKey: ServerSettings.preferenceKey) == persisted)
    }

    @Test func changingConfirmedServerRebuildsAuthorizationAddressAndPersistsOnlyTheConnection() async throws {
        let suite = "ServerAuthorizationSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        var replies: [String: ConnectionURLProtocol.Reply] = [:]
        for origin in ["https://first-deployment.test", "https://second-deployment.test"] {
            replies[origin + "/v1/client-config"] = .init(status: 200, body: try testClientConfiguration(origin: origin))
            replies[origin + "/healthz"] = .init(status: 200, body: Data(#"{"status":"ok","service":"chirp"}"#.utf8))
        }
        let client = try api(replies)
        settings.address = "first-deployment.test"
        await settings.confirm(using: client)
        let first = try #require(settings.connection)
        #expect(settings.address == "https://first-deployment.test")
        let firstAuthorization = try first.authorizationConfiguration
        #expect(firstAuthorization.url.absoluteString == "https://first-deployment.test/authorization")
        settings.address = "https://second-deployment.test/"
        #expect(settings.connection == nil)
        await settings.confirm(using: client)
        let second = try #require(settings.connection)
        let secondAuthorization = try second.authorizationConfiguration
        #expect(secondAuthorization.url.absoluteString == "https://second-deployment.test/authorization")
        #expect(secondAuthorization.origin == "https://second-deployment.test:443")
        #expect(secondAuthorization.publicKey == firstAuthorization.publicKey)
        let restored = try #require(ServerSettings(defaults: defaults).connection)
        #expect(try restored.authorizationConfiguration.url == secondAuthorization.url)
        settings.address = "https://unreachable-deployment.test/"
        await settings.confirm(using: client)
        #expect(settings.connection == nil && settings.failure != nil)
    }

    @Test func detectsAPIAndPasskeyWithoutSendingCredentialsAndRefetchesOnRegistration() async throws {
        let client = try api()
        let connection = try await client.detect("https://api.example.test")
        #expect(try await client.registrationURL(for: connection) == URL(string: "https://keys.example.test:8443/register"))
        let requests = ConnectionURLProtocol.state.withLock { $0.requests }
        #expect(requests.count == 4)
        #expect(requests.filter { $0.url?.path == "/v1/client-config" }.count == 2)
        for request in requests {
            #expect(request.httpMethod == "GET")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
            #expect(request.value(forHTTPHeaderField: "Origin") == nil)
        }
    }

    @Test func passkeyExchangeUsesDiscoveredOriginAndBindsTheResultToItsAPI() async throws {
        let connection = try ServerConnection(apiURL: URL(string: "https://second-api.example.test:8443")!,
                                              passkeyOrigin: URL(string: "https://second-keys.example.test:9443")!, overrides: [
                "authorization_url": "https://second-keys.example.test:9443/account/login",
                "token_url": "https://second-keys.example.test:9443/account/token"])
        let data = try JSONSerialization.data(withJSONObject: ["setup_token": "setup_fixture", "account_id": "member_test", "username": "Oliver", "service_origin": "https://second-keys.example.test:9443", "account_key": "", "expires_at": Int64(Date().timeIntervalSince1970) + 300])
        ConnectionURLProtocol.state.withLock {
            $0 = (["https://second-keys.example.test:9443/account/token": .init(status: 200, body: data)], [])
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ConnectionURLProtocol.self]
        let login = try ClientLoginRequest(connection: connection)
        #expect(login.authorizationURL.host == "second-keys.example.test" && login.authorizationURL.port == 9443 && login.authorizationURL.path == "/account/login")
        let callback = try #require(URL(string: "cn.youzifeile.chirp://auth/callback?code=\(String(repeating: "c", count: 43))&state=\(login.state)"))
        let setup = try await ClientLoginAPI.authenticate(login, callback: callback, configuration: configuration)
        #expect(setup.accountID == "member_test" && setup.origin == ServerAddress.identityOrigin(connection.passkeyOrigin))
        let request = try #require(ConnectionURLProtocol.state.withLock { $0.requests.first })
        #expect(request.httpMethod == "POST" && request.url?.host == "second-keys.example.test" && request.url?.path == "/account/token")
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil && request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func rejectsOtherWebsitesIncompatibleProtocolsAndUntrustedRegistrationURLs() async throws {
        for body in [
            #"{"service":"other","protocol_version":1,"passkey_origin":"https://keys.example.test","registration_url":"https://keys.example.test/register"}"#,
            #"{"service":"chirp","protocol_version":3,"passkey_origin":"https://keys.example.test","registration_url":"https://keys.example.test/register"}"#,
            #"{"service":"chirp","protocol_version":1,"passkey_origin":"https://keys.example.test","registration_url":"https://unrelated.test/register"}"#,
            #"{"service":"chirp","protocol_version":1,"passkey_origin":"https://keys.example.test","registration_url":"https://keys.example.test/register?redirect=https://unrelated.test"}"#,
            #"{"service":"chirp","protocol_version":1,"passkey_origin":"http://keys.example.test","registration_url":"http://keys.example.test/register"}"#,
            "<html>Login</html>",
        ] {
            let client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: Data(body.utf8))])
            await #expect(throws: ClientFailure.self) { try await client.detect("https://api.example.test") }
        }
        for status in [301, 401, 404, 503] {
            let client = try api(["https://api.example.test/v1/client-config": .init(status: status, body: Data())])
            await #expect(throws: ClientFailure.self) { try await client.detect("https://api.example.test") }
        }
    }

    @Test func eitherHealthFailurePreventsSavingAndChangedAuthOriginRequiresConfirmation() async throws {
        for url in ["https://api.example.test/healthz"] {
            let client = try api([url: .init(status: 503, body: Data())])
            await #expect(throws: ClientFailure.self) { try await client.detect("https://api.example.test") }
        }
        let client = try api(["https://api.example.test/healthz": .init(status: 200, body: Data(#"{"status":"ok","service":"admin"}"#.utf8))])
        await #expect(throws: ClientFailure.self) { try await client.detect("https://api.example.test") }
        let changed = try api()
        await #expect(throws: ClientFailure(.serverConfigurationChanged)) {
            try await changed.registrationURL(for: testServerConnection)
        }
    }

    @Test func editingDuringCheckDiscardsLateSuccessAndCancellationNeverSaves() async throws {
        let suite = "ServerSettingsRaceTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        settings.address = "https://api.example.test"
        let client = try api()
        ConnectionURLProtocol.paused.withLock { $0.enabled = true }
        let pending = Task { await settings.confirm(using: client) }
        while ConnectionURLProtocol.paused.withLock({ $0.pending.isEmpty }) { await Task.yield() }
        settings.address = "https://different.example.test"
        ConnectionURLProtocol.release()
        await pending.value
        #expect(settings.connection == nil && settings.notice == nil)
        #expect(defaults.data(forKey: ServerSettings.preferenceKey) == nil)
        settings.address = "https://api.example.test"
        let cancelled = Task { await settings.confirm(using: client) }
        cancelled.cancel()
        await cancelled.value
        #expect(settings.connection == nil && !settings.isChecking)
        #expect(defaults.data(forKey: ServerSettings.preferenceKey) == nil)
    }

    @Test func discoversPrefixesSeparateGroupHostsAndRefreshesPathsBeforeLogin() async throws {
        let config = try testClientConfiguration(overrides: ["api_base_url": "api/", "health_url": "status/api",
            "authorization_url": "https://keys.example.test:8443/account/login", "registration_url": "https://keys.example.test:8443/account/register",
            "token_url": "https://keys.example.test:8443/account/token", "group_base_url": "https://groups.example.test/coordinator/"])
        let client = try api([
            "https://api.example.test/chirp/v1/client-config": .init(status: 200, body: config),
            "https://api.example.test/chirp/status/api": .init(status: 200, body: Data(#"{"status":"ok","service":"chirp"}"#.utf8))])
        let connection = try await client.detect("https://api.example.test/chirp")
        #expect(connection.discoveryURL.absoluteString == "https://api.example.test/chirp/")
        #expect(connection.apiURL.absoluteString == "https://api.example.test/chirp/api/")
        #expect(connection.endpoints.groupBaseURL.host == "groups.example.test")
        #expect(try ClientLoginRequest(connection: connection).authorizationURL.path == "/account/login")
        #expect(connection.endpoints.tokenURL.path == "/account/token")
        let suite = "Refresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        settings.address = "https://api.example.test/chirp"
        await settings.confirm(using: client)
        let changed = try testClientConfiguration(overrides: ["registration_url": "https://keys.example.test:8443/new-registration",
            "group_base_url": "https://GROUPS.example.test:443/new-coordinator/"])
        ConnectionURLProtocol.state.withLock { state in
            state.replies["https://api.example.test/chirp/v1/client-config"] = .init(status: 200, body: changed)
            state.replies["https://api.example.test/chirp/healthz"] = .init(status: 200, body: Data(#"{"status":"ok","service":"chirp"}"#.utf8))
        }
        let refreshed = try await settings.prepareConnection(using: client)
        #expect(refreshed.registrationURL.path == "/new-registration")
        #expect(refreshed.endpoints.groupBaseURL.absoluteString == "https://groups.example.test/new-coordinator/")
        #expect(connection.endpoints.tokenURL.path == "/account/token")
    }

    @Test func changedGroupOriginRequiresConfirmationBeforeLogin() async throws {
        let suite = "GroupOrigin.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        let client = try api()
        settings.address = "https://api.example.test"
        await settings.confirm(using: client)
        let confirmed = try #require(settings.connection)
        for group in ["https://groups.example.test/v1/group", "https://api.example.test:8443/v1/group"] {
            let changed = try testClientConfiguration(overrides: ["group_base_url": group])
            ConnectionURLProtocol.state.withLock {
                $0.replies["https://api.example.test/v1/client-config"] = .init(status: 200, body: changed)
            }
            await #expect(throws: ClientFailure(.serverConfigurationChanged)) {
                try await settings.prepareConnection(using: client)
            }
            #expect(settings.connection == confirmed)
            #expect(ServerSettings(defaults: defaults).connection == confirmed)
        }
    }

    @Test func rejectsUnsafeDiscoveredEndpoints() async throws {
        for (key, value) in [("token_url", "https://untrusted.test/token"), ("registration_url", "https://keys.example.test:8443/register?redirect=elsewhere"),
                             ("group_base_url", "http://groups.example.test"), ("api_base_url", "//elsewhere.test/api"),
                             ("authorization_url", "https://user@keys.example.test:8443/login")] {
            let config = try testClientConfiguration(overrides: [key: value])
            let client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: config)])
            await #expect(throws: (any Error).self) { try await client.detect("https://api.example.test") }
        }
    }

    @Test func outdatedResponseStopsBeforeAcceptingConfigurationAndPersistsNothing() async throws {
        let policy: [String: Any] = ["platform": "macos", "latest_version": "0.15.0", "latest_build": 19, "minimum_version": "0.14.0", "minimum_build": 17]
        let body = try JSONSerialization.data(withJSONObject: ["error": ["code": "CLIENT_UPDATE_REQUIRED", "message": "untrusted arbitrary server text"], "client_policy": policy])
        let client = try api(["https://api.example.test/v1/client-config": .init(status: 403, body: body)])
        let suite = "VersionReject.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = ServerSettings(defaults: defaults)
        settings.address = "https://api.example.test"
        await settings.confirm(using: client)
        #expect(settings.connection == nil && settings.notice == nil)
        #expect(settings.failure?.code == "CLIENT_UPDATE_REQUIRED")
        #expect(defaults.data(forKey: ServerSettings.preferenceKey) == nil)
        #expect(settings.address == "https://api.example.test")
        let failure = try #require(settings.failure)
        #expect(failure.localized(in: AppLanguage.english.locale).contains("0.15.0 (build 19)"))
        #expect(failure.localized(in: AppLanguage.english.locale).contains("minimum supported version: 0.14.0 (build 17)"))
        #expect(!failure.localized(in: AppLanguage.english.locale).contains("untrusted"))
        let requests = ConnectionURLProtocol.state.withLock { $0.requests }
        #expect(requests.count == 1)
        #expect(requests[0].value(forHTTPHeaderField: "X-Chirp-Platform") == "macos")
        #expect(requests[0].value(forHTTPHeaderField: "X-Chirp-Version") == "0.14.0")
        #expect(requests[0].value(forHTTPHeaderField: "X-Chirp-Build") == "14")
    }

    @Test func successfulHTTPStillChecksPolicyBeforeEndpointsAndCachedLoginsRefresh() async throws {
        var value = try #require(JSONSerialization.jsonObject(with: testClientConfiguration()) as? [String: Any])
        value["client_policy"] = ["platform": "macos", "latest_version": "0.15.0", "latest_build": 19, "minimum_version": "0.14.0", "minimum_build": 15]
        value["endpoints"] = ["invalid": "an outdated client must not parse this"]
        let body = try JSONSerialization.data(withJSONObject: value)
        let rejected = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: body)])
        do {
            _ = try await rejected.detect("https://api.example.test")
            Issue.record("Old client accepted configuration")
        } catch let failure as ClientFailure { #expect(failure.code == "CLIENT_UPDATE_REQUIRED") }
        #expect(ConnectionURLProtocol.state.withLock { $0.requests.count } == 1)
        let suite = "VersionRefresh.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = try api()
        let settings = ServerSettings(defaults: defaults)
        settings.address = "https://api.example.test"
        await settings.confirm(using: client)
        #expect(settings.connection != nil)
        ConnectionURLProtocol.state.withLock { $0.replies["https://api.example.test/v1/client-config"] = .init(status: 200, body: body) }
        await #expect(throws: ClientFailure.self) { try await settings.prepareConnection(using: client) }
        #expect(settings.connection == nil && settings.failure?.code == "CLIENT_UPDATE_REQUIRED")
    }

    @Test func minimumBuildDoesNotForceLatestOrAllowForeignPlatformPolicies() async throws {
        var value = try #require(JSONSerialization.jsonObject(with: testClientConfiguration()) as? [String: Any])
        value["client_policy"] = ["platform": "macos", "latest_version": "0.15.0", "latest_build": 19, "minimum_version": "0.14.0", "minimum_build": 14]
        var client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: JSONSerialization.data(withJSONObject: value))])
        #expect(try await client.detect("https://api.example.test").clientPolicy.latestBuild == 19)
        value["client_policy"] = ["platform": "ios", "latest_version": "0.15.0", "latest_build": 19, "minimum_version": "0.14.0", "minimum_build": 14]
        client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: JSONSerialization.data(withJSONObject: value))])
        await #expect(throws: ClientFailure.self) { try await client.detect("https://api.example.test") }
    }

    @Test func discoveryChecksTheVersionBeforeBuildAndRequiresTheCompletePolicy() async throws {
        var value = try #require(JSONSerialization.jsonObject(with: testClientConfiguration()) as? [String: Any])
        value["client_policy"] = ["platform": "macos", "latest_version": "0.14.1", "latest_build": 1, "minimum_version": "0.14.0", "minimum_build": 14]
        var client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: JSONSerialization.data(withJSONObject: value))])
        #expect(try await client.detect("https://api.example.test").clientPolicy.latestBuild == 1)
        value["client_policy"] = ["platform": "macos", "latest_version": "0.14.1", "latest_build": 1, "minimum_version": "0.14.1", "minimum_build": 1]
        value["endpoints"] = ["invalid": "an old version must not accept endpoints even with a higher build"]
        client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: JSONSerialization.data(withJSONObject: value))])
        do {
            _ = try await client.detect("https://api.example.test")
            Issue.record("Old version bypassed the minimum with a higher build")
        } catch let failure as ClientFailure { #expect(failure.code == "CLIENT_UPDATE_REQUIRED") }
        value["client_policy"] = ["platform": "macos", "latest_version": "0.14.1", "latest_build": 1, "minimum_build": 1]
        client = try api(["https://api.example.test/v1/client-config": .init(status: 200, body: JSONSerialization.data(withJSONObject: value))])
        await #expect(throws: (any Error).self) { try await client.detect("https://api.example.test") }
    }

    @Test func originRejectsPathsCredentialsQueriesAndInvalidStoredConfiguration() throws {
        for address in ["", "api.example.test", "https://api.example.test/v1", "https://user@api.example.test", "https://api.example.test?", "https://api.example.test#", "https://api.example.test:65536"] {
            #expect(throws: (any Error).self) { try ServerAddress.origin(address) }
        }
        let invalid = Data(#"{"apiURL":"https://api.example.test","passkeyOrigin":"https://keys.example.test/unsafe"}"#.utf8)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(ServerConnection.self, from: invalid) }
    }
}
