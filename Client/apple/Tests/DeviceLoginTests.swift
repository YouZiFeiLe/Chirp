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

private let deviceRequestID = String(repeating: "a", count: 43)

private func deviceResponse(url: String? = nil, expiry: Double = Date().timeIntervalSince1970 + 180, interval: Int = 2) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "request_id": deviceRequestID,
        "verification_uri": url ?? "https://keys.example.test/device?request=\(deviceRequestID)",
        "expires_at": expiry, "interval": interval,
    ])
}

@Test func deviceAuthorizationRejectsUntrustedQRCodeURLsAndDeadlines() throws {
    let verifier = String(repeating: "v", count: 43)
    let now = Date()
    let authorization = try ClientDeviceAuthorization(data: deviceResponse(expiry: now.timeIntervalSince1970 + 180), verifier: verifier, connection: testServerConnection, now: now)
    #expect(authorization.requestID == deviceRequestID)
    #expect(authorization.proof["code_verifier"] == verifier)
    #expect(!authorization.verificationURL.absoluteString.contains(verifier))
    for url in [
        "http://keys.example.test/device?request=\(deviceRequestID)",
        "https://unrelated.test/device?request=\(deviceRequestID)",
        "https://keys.example.test:8443/device?request=\(deviceRequestID)",
        "https://user@keys.example.test/device?request=\(deviceRequestID)",
        "https://keys.example.test/register?request=\(deviceRequestID)",
        "https://keys.example.test/device?request=\(deviceRequestID)#fragment",
        "https://keys.example.test/device?request=other",
        "https://keys.example.test/device?request=\(deviceRequestID)&request=\(deviceRequestID)",
        "https://keys.example.test/device?request=\(deviceRequestID)&code_verifier=\(verifier)",
    ] {
        #expect(throws: (any Error).self) { try ClientDeviceAuthorization(data: deviceResponse(url: url), verifier: verifier, connection: testServerConnection) }
    }
    for (expiry, interval) in [(now.timeIntervalSince1970 - 1, 2), (now.timeIntervalSince1970 + 241, 2), (now.timeIntervalSince1970 + 180, 0), (now.timeIntervalSince1970 + 180, 31)] {
        #expect(throws: (any Error).self) { try ClientDeviceAuthorization(data: deviceResponse(expiry: expiry, interval: interval), verifier: verifier, connection: testServerConnection, now: now) }
    }
}

private final class DeviceURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { let status: Int; let body: Data }
    struct Recorded: Sendable { let url: URL; let method: String?; let headers: [String: String]; let body: Data }
    static let state = Mutex((replies: [Reply](), requests: [Recorded]()))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let record = Recorded(url: request.url!, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:], body: body)
        let reply = Self.state.withLock { state -> Reply? in
            state.requests.append(record)
            return state.replies.isEmpty ? nil : state.replies.removeFirst()
        }
        guard let reply else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite(.serialized) @MainActor struct DeviceLoginNetworkTests {
    private let identity = try! testIdentityStore("device-login")
    private func api(replies: [DeviceURLProtocol.Reply], connection: ServerConnection = testServerConnection) -> ClientDeviceLoginAPI {
        DeviceURLProtocol.state.withLock { $0 = (replies, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DeviceURLProtocol.self]
        configuration.httpCookieStorage = nil
        return ClientDeviceLoginAPI(connection: connection, configuration: configuration, identity: identity)
    }

    @Test func pendingIsNotLoginAndOnlyPrivatePOSTCanClaim() async throws {
        let session = try JSONSerialization.data(withJSONObject: ["setup_token": "setup_fixture", "account_id": "member_test", "username": "Oliver", "service_origin": "https://keys.example.test:443", "account_key": "", "expires_at": Int64(Date().timeIntervalSince1970) + 300])
        let connection = try ServerConnection(apiURL: testServerConnection.apiURL, passkeyOrigin: testServerConnection.passkeyOrigin, overrides: [
            "device_start_url": "https://keys.example.test/qr/begin", "device_poll_url": "https://keys.example.test/qr/status",
            "device_cancel_url": "https://keys.example.test/qr/stop", "device_verification_url": "https://keys.example.test/qr/authorize"])
        let client = try api(replies: [.init(status: 201, body: deviceResponse(url: "https://keys.example.test/qr/authorize?request=\(deviceRequestID)")), .init(status: 202, body: Data(#"{"status":"pending"}"#.utf8)), .init(status: 200, body: session), .init(status: 204, body: Data())], connection: connection)
        let authorization = try await client.start()
        #expect(try await client.pollIdentity(authorization) == nil)
        let login = try await client.pollIdentity(authorization)
        #expect(login?.accountID == "member_test")
        #expect(login?.origin == ServerAddress.identityOrigin(connection.passkeyOrigin))
        await client.cancel(authorization)
        let requests = DeviceURLProtocol.state.withLock { $0.requests }
        #expect(requests.count == 4)
        #expect(requests.map { $0.url.path } == ["/qr/begin", "/qr/status", "/qr/status", "/qr/stop"])
        for request in requests {
            #expect(request.method == "POST")
            #expect(request.url.host == "keys.example.test" && request.url.scheme == "https")
            #expect(request.url.query == nil)
            #expect(request.headers["X-Chirp-Platform"] == "macos")
            #expect(request.headers["X-Chirp-Version"] == "0.14.0")
            #expect(request.headers["X-Chirp-Build"] == "14")
            #expect(!request.headers.keys.contains { ["cookie", "origin", "authorization"].contains($0.lowercased()) })
            let body = try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
            if request.url.path == "/qr/begin" {
                let digest = Data(SHA256.hash(data: Data(authorization.verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                #expect(body["code_challenge"] as? String == digest && body["code_challenge_method"] as? String == "S256")
                #expect(body["code_verifier"] == nil)
            } else {
                for (key, value) in authorization.proof { #expect(body[key] as? String == value) }
                #expect(body["device_proof"] == nil) // Only final activation proves the selected device key.
            }
        }
    }

    @Test func unsupportedAndExpiredServerResponsesAreActionable() async throws {
        let unsupported = api(replies: [.init(status: 404, body: Data())])
        await #expect(throws: DeviceLoginError.self) { try await unsupported.start() }
        let expired = try api(replies: [.init(status: 201, body: deviceResponse()), .init(status: 400, body: Data(#"{"error":{"code":"DEVICE_AUTHORIZATION_EXPIRED","message":"expired"}}"#.utf8))])
        let authorization = try await expired.start()
        do {
            _ = try await expired.pollIdentity(authorization)
            Issue.record("Expired QR returned a session")
        } catch DeviceLoginError.expired { /* Expected retry path. */ }
    }

    @Test func foreignAuthorizationNeverSendsItsVerifierToAnotherServer() async throws {
        let client = api(replies: [])
        let other = try ServerConnection(apiURL: URL(string: "https://other-api.example.test")!,
                                          passkeyOrigin: URL(string: "https://other-keys.example.test")!)
        let authorization = try ClientDeviceAuthorization(
            data: deviceResponse(url: "https://other-keys.example.test/device?request=\(deviceRequestID)"),
            verifier: String(repeating: "v", count: 43), connection: other)
        await #expect(throws: ClientFailure(.invalidDeviceAuthorization)) { try await client.pollIdentity(authorization) }
        await client.cancel(authorization)
        #expect(DeviceURLProtocol.state.withLock { $0.requests.isEmpty })
    }
}
