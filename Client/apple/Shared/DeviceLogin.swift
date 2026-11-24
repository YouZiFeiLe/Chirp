import Foundation
import ChirpMLS

struct ClientDeviceAuthorization: Sendable {
    let connection: ServerConnection
    let requestID: String
    let verificationURL: URL
    let expiresAt: Date
    let interval: TimeInterval
    let verifier: String

    private struct Response: Decodable {
        let requestID: String
        let verificationURI: String
        let expiresAt: Double
        let interval: Int
        enum CodingKeys: String, CodingKey {
            case requestID = "request_id", verificationURI = "verification_uri", expiresAt = "expires_at", interval
        }
    }

    init(data: Data, verifier: String, connection: ServerConnection, now: Date = Date()) throws {
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard response.requestID.range(of: "^[A-Za-z0-9_-]{43}$", options: .regularExpression) != nil,
              let url = URL(string: response.verificationURI),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ServerAddress.sameOrigin(url, connection.endpoints.deviceVerificationURL), url.user == nil, url.password == nil,
              url.path == connection.endpoints.deviceVerificationURL.path, url.fragment == nil,
              components.queryItems?.count == 1,
              components.queryItems?.first?.name == "request",
              components.queryItems?.first?.value == response.requestID,
              response.expiresAt > now.timeIntervalSince1970,
              response.expiresAt <= now.timeIntervalSince1970 + 240,
              (1...30).contains(response.interval) else {
            throw ClientFailure(.invalidDeviceAuthorization)
        }
        self.connection = connection
        self.requestID = response.requestID
        self.verificationURL = url
        self.expiresAt = Date(timeIntervalSince1970: response.expiresAt)
        self.interval = TimeInterval(response.interval)
        self.verifier = verifier
    }

    var proof: [String: String] { ["request_id": requestID, "code_verifier": verifier] }
}

enum DeviceLoginError: LocalizedError, ClientFailureProviding {
    case expired, unsupported, server(ClientFailure)
    var clientFailure: ClientFailure {
        switch self {
        case .expired: ClientFailure(.deviceAuthorizationExpired)
        case .unsupported: ClientFailure(.deviceLoginUnsupported)
        case .server(let failure): failure
        }
    }
    var errorDescription: String? { clientFailure.errorDescription }
}

final class ClientDeviceLoginAPI: Sendable {
    let connection: ServerConnection
    private let session: HTTPDataSession

    init(connection: ServerConnection, configuration: URLSessionConfiguration? = nil, identity: DeviceIdentityStore? = nil) {
        self.connection = connection
        let configuration = configuration ?? .ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = HTTPDataSession(configuration: configuration)
    }

    deinit { session.close() }

    func start() async throws -> ClientDeviceAuthorization {
        guard connection.capabilities.deviceLogin else { throw DeviceLoginError.unsupported }
        let login = try ClientLoginRequest(connection: connection)
        let (data, status) = try await post("start", body: ["client_id": ClientLoginRequest.clientID, "code_challenge": login.challenge, "code_challenge_method": "S256"])
        guard status == 201 else { throw ClientFailure(.deviceRequestFailed) }
        return try ClientDeviceAuthorization(data: data, verifier: login.verifier, connection: connection)
    }

    func pollIdentity(_ authorization: ClientDeviceAuthorization) async throws -> AuthenticatedIdentitySetup? {
        guard authorization.connection == connection else { throw ClientFailure(.invalidDeviceAuthorization) }
        let (data, status) = try await post("poll", body: authorization.proof)
        if status == 202 { return nil }
        return try JSONDecoder().decode(AuthenticatedIdentitySetup.self, from: data)
    }
    func cancel(_ authorization: ClientDeviceAuthorization) async {
        guard authorization.connection == connection else { return }
        _ = try? await post("cancel", body: authorization.proof)
    }

    private func endpoint(for action: String) -> URL {
        switch action {
        case "start": connection.endpoints.deviceStartURL
        case "poll": connection.endpoints.devicePollURL
        default: connection.endpoints.deviceCancelURL
        }
    }

    private func post(_ action: String, body: [String: Any], operation: StaticString = #function) async throws -> (Data, Int) {
        var request = URLRequest(url: endpoint(for: action))
        connection.client.apply(to: &request)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request, maxBytes: 65_536, operation: operation)
        guard let response = response as? HTTPURLResponse else { throw ClientFailure(.invalidResponse) }
        if response.statusCode == 404 { throw DeviceLoginError.unsupported }
        guard (200..<300).contains(response.statusCode) else {
            let failure = ClientFailure.response(data: data, status: response.statusCode,
                                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            if failure.code == "DEVICE_AUTHORIZATION_EXPIRED" { throw DeviceLoginError.expired }
            throw DeviceLoginError.server(failure)
        }
        return (data, response.statusCode)
    }
}
