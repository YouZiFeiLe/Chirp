import CryptoKit
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func loginUsesFreshPKCEAndStrictCallback() throws {
    let login = try ClientLoginRequest(connection: testServerConnection)
    let other = try ClientLoginRequest(connection: testServerConnection)
    #expect(login.verifier != other.verifier && login.state != other.state)
    let query = URLComponents(url: login.authorizationURL, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(login.authorizationURL.host == "keys.example.test")
    #expect(query.first(where: { $0.name == "code_challenge" })?.value == login.challenge)
    #expect(!login.authorizationURL.absoluteString.contains(login.verifier))
    let code = String(repeating: "c", count: 43)
    #expect(try login.code(from: URL(string: "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(login.state)")!) == code)
    for value in [
        "cn.youzifeile.chirp://other/callback?code=\(code)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/wrong?code=\(code)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(other.state)",
        "cn.youzifeile.chirp://auth/callback?code=\(code)&state=\(login.state)&state=\(login.state)",
        "cn.youzifeile.chirp://auth/callback?code=short&state=\(login.state)",
        "https://keys.example.test/?code=\(code)&state=\(login.state)",
    ] {
        #expect(throws: (any Error).self) { try login.code(from: URL(string: value)!) }
    }
}

@Test func loginSessionRejectsInvalidExpiryAndIdentity() throws {
    func data(expiry: Double, identity: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["member": ["id": "member_test", "display_name": "Oliver"], "credential": "chirp_" + String(repeating: "a", count: 43), "expires_at": expiry, "participant_identity": identity])
    }
    let valid = try ClientSession(data: data(expiry: Date().timeIntervalSince1970 + 72000, identity: "member_test.login_test"), connection: testServerConnection)
    #expect(valid.member.id == "member_test")
    for (expiry, identity) in [(Date().timeIntervalSince1970 - 1, "member_test.login_test"), (Date().timeIntervalSince1970 + 90000, "member_test.login_test"), (Date().timeIntervalSince1970 + 3600, "member_other.login_test")] {
        #expect(throws: (any Error).self) { try ClientSession(data: data(expiry: expiry, identity: identity), connection: testServerConnection) }
    }
}
