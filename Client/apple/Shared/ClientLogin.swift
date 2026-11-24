import CryptoKit
import Foundation
import Security
import ChirpMLS

struct ClientLoginRequest: Sendable {
    let connection: ServerConnection
    static let callbackScheme = "cn.youzifeile.chirp"
    static let redirectURI = "cn.youzifeile.chirp://auth/callback"
    static let clientID = "chirp-apple"
    let verifier: String
    let state: String

    init(connection: ServerConnection) throws {
        self.connection = connection
        verifier = try Self.randomValue()
        state = try Self.randomValue()
    }

    var challenge: String { Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))) }

    var authorizationURL: URL {
        var components = URLComponents(url: connection.endpoints.authorizationURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
        ]
        return components.url!
    }

    func code(from callback: URL) throws -> String {
        guard callback.scheme == Self.callbackScheme, callback.host == "auth", callback.path == "/callback",
              callback.user == nil, callback.password == nil, callback.port == nil, callback.fragment == nil,
              let components = URLComponents(url: callback, resolvingAgainstBaseURL: false) else {
            throw ClientFailure(.invalidLoginCallback)
        }
        let items = components.queryItems ?? []
        guard items.count == 2, items.filter({ $0.name == "state" }).count == 1,
              items.first(where: { $0.name == "state" })?.value == state,
              let code = items.first(where: { $0.name == "code" })?.value,
              code.count == 43, code.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil else {
            throw ClientFailure(.loginVerificationFailed)
        }
        return code
    }

    private static func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ClientFailure(.secureLoginFailed)
        }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct ClientSession: Sendable {
    let connection: ServerConnection
    let member: MemberInfo
    let credential: String
    let expiresAt: Date
    let participantIdentity: String
    let deviceIdentity: V5Device?
    private struct Response: Decodable {
        let member: MemberInfo
        let credential: String
        let expiresAt: Double
        let participantIdentity: String
        let deviceIdentity: V5Device?
        enum CodingKeys: String, CodingKey {
            case member, credential
            case expiresAt = "expires_at", participantIdentity = "participant_identity"
            case deviceIdentity = "device_identity"
        }
    }

    init(data: Data, connection: ServerConnection, expectedDevice: V5Device? = nil) throws {
        let response = try JSONDecoder().decode(Response.self, from: data)
        self.connection = connection
        member = response.member
        credential = response.credential
        expiresAt = Date(timeIntervalSince1970: response.expiresAt)
        participantIdentity = response.participantIdentity
        deviceIdentity = response.deviceIdentity
        if let expectedDevice {
            guard deviceIdentity == expectedDevice else { throw V5IdentityError.wrongDevice }
            try expectedDevice.validate()
        }
        guard credential.hasPrefix("chirp_"), credential.count == 49,
              participantIdentity.hasPrefix(member.id + ".login_"),
              expiresAt > Date(), expiresAt.timeIntervalSinceNow <= 20 * 60 * 60 + 60 else {
            throw ClientFailure(.invalidLoginSession)
        }
    }
}

enum ClientLoginAPI {
    static func authenticate(_ login: ClientLoginRequest, callback: URL, configuration: URLSessionConfiguration? = nil) async throws -> AuthenticatedIdentitySetup {
        struct Request: Encodable { let code: String; let code_verifier: String; let client_id: String; let redirect_uri: String }
        return try await IdentitySetupAPI.post("api/client/exchange", connection: login.connection,
            body: JSONEncoder().encode(Request(code: login.code(from: callback), code_verifier: login.verifier, client_id: ClientLoginRequest.clientID, redirect_uri: ClientLoginRequest.redirectURI)), configuration: configuration, endpoint: login.connection.endpoints.tokenURL)
    }
}
