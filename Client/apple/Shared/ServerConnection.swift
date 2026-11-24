import Foundation
import Observation

struct ClientEndpoints: Codable, Equatable, Sendable {
    let apiBaseURL: URL
    let healthURL: URL
    let authorizationURL: URL
    let registrationURL: URL
    let tokenURL: URL
    let deviceStartURL: URL
    let devicePollURL: URL
    let deviceCancelURL: URL
    let deviceVerificationURL: URL
    let groupBaseURL: URL
    enum CodingKeys: String, CodingKey {
        case apiBaseURL = "api_base_url", healthURL = "health_url"
        case authorizationURL = "authorization_url", registrationURL = "registration_url", tokenURL = "token_url"
        case deviceStartURL = "device_start_url", devicePollURL = "device_poll_url", deviceCancelURL = "device_cancel_url"
        case deviceVerificationURL = "device_verification_url", groupBaseURL = "group_base_url"
    }

    func resolved(against base: URL, passkeyOrigin: URL) throws -> Self {
        func resolve(_ url: URL, auth: Bool = false, directory: Bool = false) throws -> URL {
            let raw = url.relativeString
            guard !raw.isEmpty, !raw.hasPrefix("//"), (!auth || url.scheme != nil), let absolute = URL(string: raw, relativeTo: base)?.absoluteURL else {
                throw ClientFailure(.invalidServerConfiguration)
            }
            let validated = try ServerAddress.validate(absolute.absoluteString)
            guard !auth || ServerAddress.sameOrigin(validated, passkeyOrigin) else {
                throw ClientFailure(.invalidServerConfiguration)
            }
            return directory ? try ServerAddress.baseURL(validated.absoluteString) : validated
        }
        return try Self(apiBaseURL: resolve(apiBaseURL, directory: true), healthURL: resolve(healthURL),
            authorizationURL: resolve(authorizationURL, auth: true), registrationURL: resolve(registrationURL, auth: true),
            tokenURL: resolve(tokenURL, auth: true), deviceStartURL: resolve(deviceStartURL, auth: true),
            devicePollURL: resolve(devicePollURL, auth: true), deviceCancelURL: resolve(deviceCancelURL, auth: true),
            deviceVerificationURL: resolve(deviceVerificationURL, auth: true),
            groupBaseURL: resolve(groupBaseURL, directory: true))
    }
}

struct ClientCapabilities: Codable, Equatable, Sendable {
    let registration: Bool
    let deviceLogin: Bool
    let dynamicRooms: Bool
    let stateEvents: Bool
    let attachmentProtocol: Int
    let maxMembers: Int
    let maxRoomParticipants: Int
    enum CodingKeys: String, CodingKey {
        case registration, deviceLogin = "device_login", dynamicRooms = "dynamic_rooms", stateEvents = "state_events"
        case attachmentProtocol = "attachment_protocol"
        case maxMembers = "max_members", maxRoomParticipants = "max_room_participants"
    }
}

/// Public configuration only. A login keeps its immutable endpoint snapshot.
struct ServerConnection: Codable, Equatable, Sendable {
    let client: ClientIdentity
    let clientPolicy: ClientVersionPolicy
    let discoveryURL: URL
    let passkeyOrigin: URL
    let endpoints: ClientEndpoints
    let defaultRoomID: String
    let capabilities: ClientCapabilities
    var apiURL: URL { endpoints.apiBaseURL }
    var registrationURL: URL { endpoints.registrationURL }
    var authorizationConfiguration: AuthorizationConfiguration {
        get throws { try AuthorizationConfiguration.bundled(origin: passkeyOrigin.absoluteString) }
    }

    init(discoveryURL: URL, passkeyOrigin: URL, endpoints: ClientEndpoints,
         defaultRoomID: String, capabilities: ClientCapabilities, client: ClientIdentity, clientPolicy: ClientVersionPolicy) throws {
        try clientPolicy.validate(for: client)
        self.client = client
        self.clientPolicy = clientPolicy
        self.discoveryURL = try ServerAddress.baseURL(discoveryURL.absoluteString)
        self.passkeyOrigin = try ServerAddress.origin(passkeyOrigin.absoluteString)
        self.endpoints = try endpoints.resolved(against: self.discoveryURL, passkeyOrigin: self.passkeyOrigin)
        guard VoiceRooms.validID(defaultRoomID), capabilities.dynamicRooms, capabilities.stateEvents, capabilities.attachmentProtocol == 3,
              capabilities.maxMembers == 0, capabilities.maxRoomParticipants == 0 else {
            throw ClientFailure(.invalidServerConfiguration)
        }
        self.defaultRoomID = defaultRoomID
        self.capabilities = capabilities
    }

    private enum CodingKeys: String, CodingKey { case discoveryURL, passkeyOrigin, endpoints, defaultRoomID, capabilities, client, clientPolicy }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(discoveryURL: values.decode(URL.self, forKey: .discoveryURL),
            passkeyOrigin: values.decode(URL.self, forKey: .passkeyOrigin),
            endpoints: values.decode(ClientEndpoints.self, forKey: .endpoints),
            defaultRoomID: values.decode(String.self, forKey: .defaultRoomID),
            capabilities: values.decode(ClientCapabilities.self, forKey: .capabilities),
            client: values.decode(ClientIdentity.self, forKey: .client), clientPolicy: values.decode(ClientVersionPolicy.self, forKey: .clientPolicy))
    }
}

final class ServerConnectionAPI: Sendable {
    private let session: HTTPDataSession
    private let identity: ClientIdentity?

    init(configuration: URLSessionConfiguration? = nil, identity: ClientIdentity? = nil) {
        self.identity = identity
        let configuration = configuration ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        session = HTTPDataSession(configuration: configuration)
    }

    deinit { session.close() }

    func detect(_ address: String) async throws -> ServerConnection {
        struct Configuration: Decodable {
            let service: String
            let protocolVersion: Int
            let passkeyOrigin: String
            let defaultRoomID: String
            let endpoints: ClientEndpoints
            let capabilities: ClientCapabilities
            let clientPolicy: ClientVersionPolicy
            enum CodingKeys: String, CodingKey {
                case service, protocolVersion = "protocol_version"
                case passkeyOrigin = "passkey_origin", defaultRoomID = "default_room_id", endpoints, capabilities, clientPolicy = "client_policy"
            }
        }
        let apiURL = try ServerAddress.baseURL(forUserInput: address)
        let client = try identity ?? ClientIdentity.current()
        guard client.isValid else { throw ClientFailure(.clientVersionInvalid) }
        let data = try await get(apiURL.appendingPathComponent("v1/client-config"), identity: client)
        // Parse and check the small policy before decoding or resolving endpoints.
        struct PolicyEnvelope: Decodable {
            let service: String
            let protocolVersion: Int
            let clientPolicy: ClientVersionPolicy
            enum CodingKeys: String, CodingKey { case service, protocolVersion = "protocol_version", clientPolicy = "client_policy" }
        }
        guard let envelope = try? JSONDecoder().decode(PolicyEnvelope.self, from: data),
              envelope.service == "chirp", envelope.protocolVersion == 5 else { throw ClientFailure(.invalidServerConfiguration) }
        let policy = envelope.clientPolicy
        try policy.validate(for: client)
        guard let config = try? JSONDecoder().decode(Configuration.self, from: data),
              config.service == "chirp", config.protocolVersion == 5,
              let origin = try? ServerAddress.origin(config.passkeyOrigin),
              let connection = try? ServerConnection(discoveryURL: apiURL, passkeyOrigin: origin, endpoints: config.endpoints,
                  defaultRoomID: config.defaultRoomID, capabilities: config.capabilities, client: client, clientPolicy: policy) else {
            throw ClientFailure(.invalidServerConfiguration)
        }
        try await health(connection.endpoints.healthURL, service: "chirp")
        try Task.checkCancellation()
        return connection
    }

    func refresh(_ connection: ServerConnection) async throws -> ServerConnection {
        let refreshed = try await detect(connection.discoveryURL.absoluteString)
        guard refreshed.passkeyOrigin == connection.passkeyOrigin,
              ServerAddress.sameOrigin(refreshed.apiURL, connection.apiURL),
              ServerAddress.sameOrigin(refreshed.endpoints.groupBaseURL, connection.endpoints.groupBaseURL) else {
            throw ClientFailure(.serverConfigurationChanged)
        }
        return refreshed
    }

    func registrationURL(for connection: ServerConnection) async throws -> URL {
        try await refresh(connection).registrationURL
    }

    private func health(_ url: URL, service: String) async throws {
        struct Health: Decodable { let status: String; let service: String }
        let data = try await get(url)
        guard let health = try? JSONDecoder().decode(Health.self, from: data),
              health.status == "ok", health.service == service else {
            throw ClientFailure(.invalidServerConfiguration)
        }
    }

    private func get(_ url: URL, identity: ClientIdentity? = nil, operation: StaticString = #function) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        identity?.apply(to: &request)
        let (data, response) = try await session.data(for: request, maxBytes: 16_384, operation: operation)
        guard let response = response as? HTTPURLResponse else { throw ClientFailure(.invalidResponse) }
        guard response.statusCode == 200 else {
            if response.statusCode == 404 { throw ClientFailure(.invalidServerConfiguration) }
            throw ClientFailure.response(data: data, status: response.statusCode)
        }
        guard response.mimeType == "application/json", data.count <= 16_384 else {
            throw ClientFailure(.invalidServerConfiguration)
        }
        return data
    }
}

@MainActor @Observable
final class ServerSettings {
    static let preferenceKey = "chirp.serverConnection.v5"
    var address: String {
        didSet {
            guard address != oldValue else { return }
            connection = nil; notice = nil; failure = nil
            checkID = nil; isChecking = false
        }
    }
    private(set) var connection: ServerConnection?
    private(set) var isChecking = false
    private(set) var notice: LocalizedMessage?
    private(set) var failure: ClientFailure?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var checkID: UUID?

    func resetAll() { address = ""; connection = nil; failure = nil }
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.preferenceKey)
            .flatMap { try? JSONDecoder().decode(ServerConnection.self, from: $0) }
        connection = saved
        address = saved.map { ServerAddress.normalized($0.discoveryURL) } ?? ""
    }

    func prepareConnection(using api: ServerConnectionAPI = ServerConnectionAPI()) async throws -> ServerConnection {
        guard let previous = connection else { throw ClientFailure(.serverNotConfigured) }
        let currentAddress = address
        let refreshed: ServerConnection
        do { refreshed = try await api.refresh(previous) }
        catch {
            if let rejected = error as? ClientFailure, rejected.code == ClientErrorCode.clientUpdateRequired.rawValue,
               connection == previous, address == currentAddress {
                connection = nil; notice = nil; failure = rejected
            }
            throw error
        }
        try Task.checkCancellation()
        guard connection == previous, address == currentAddress else { throw CancellationError() }
        let data = try JSONEncoder().encode(refreshed)
        connection = refreshed
        defaults.set(data, forKey: Self.preferenceKey)
        return refreshed
    }

    func confirm(using api: ServerConnectionAPI = ServerConnectionAPI()) async {
        guard !isChecking else { return }
        let id = UUID()
        ClientLog.shared.record(.settings, "confirmServer", outcome: .started)
        let span = ClientLog.shared.begin()
        checkID = id; isChecking = true
        connection = nil; notice = nil; failure = nil
        defer { if checkID == id { isChecking = false; checkID = nil } }
        do {
            let detected = try await api.detect(address)
            try Task.checkCancellation()
            guard checkID == id else { return }
            let data = try JSONEncoder().encode(detected)
            // Normalizing the displayed address invalidates old checks first.
            address = ServerAddress.normalized(detected.discoveryURL)
            connection = detected
            defaults.set(data, forKey: Self.preferenceKey)
            ClientLog.shared.finish(span, .settings, "confirmServer")
            notice = "地址保存成功"
        } catch is CancellationError {
            ClientLog.shared.finish(span, .settings, "confirmServer", error: CancellationError())
            return
        } catch let error as URLError where error.code == .cancelled {
            ClientLog.shared.finish(span, .settings, "confirmServer", error: error)
            return
        } catch {
            ClientLog.shared.finish(span, .settings, "confirmServer", error: error)
            guard checkID == id else { return }
            failure = ClientFailure.capture(error)
        }
    }
}
