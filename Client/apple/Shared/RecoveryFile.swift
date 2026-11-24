import ChirpMLS
import CryptoKit
import Foundation
#if os(iOS)
import UIKit
#endif

enum IdentitySetupError: LocalizedError {
    case invalid(LocalizedMessage)
    var errorDescription: String? { if case .invalid(let text) = self { text.localized(in: AppLanguage.load().locale) } else { "Identity setup failed" } }
}

struct RecoveryPayload: Codable, Sendable {
    var payloadVersion = 1
    var identityProtocol = "chirp-mls-authenticated-v5"
    var rootAlgorithm = "Ed25519"
    var rootSeed: String
    var rootPublicKey: String
    var serviceOrigin: String
    var accountID: String
    var username: String
    var createdAt: String
    var sourcePlatform: String
    enum CodingKeys: String, CodingKey {
        case payloadVersion = "payload_version", identityProtocol = "identity_protocol", rootAlgorithm = "root_algorithm"
        case rootSeed = "root_seed", rootPublicKey = "root_public_key", serviceOrigin = "service_origin", accountID = "account_id"
        case username, createdAt = "created_at", sourcePlatform = "source_platform"
    }
    func validate(origin: String, accountID: String, root: String?) throws {
        let timestamp = ISO8601DateFormatter()
        let plainDate = timestamp.date(from: createdAt)
        timestamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let parsedDate = plainDate ?? timestamp.date(from: createdAt)
        guard let url = URL(string: serviceOrigin), url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil, url.host != nil,
              ["https", "http"].contains(url.scheme ?? ""), ServerAddress.identityOrigin(url) == serviceOrigin,
              createdAt.utf8.count <= 64, parsedDate != nil, createdAt.hasSuffix("Z") || createdAt.hasSuffix("+00:00") else { throw V5IdentityError.invalid }

        guard payloadVersion == 1, identityProtocol == "chirp-mls-authenticated-v5", rootAlgorithm == "Ed25519",
              serviceOrigin == origin, self.accountID == accountID,
              root == nil || root == rootPublicKey,
              ["iOS", "macOS", "Windows", "Android"].contains(sourcePlatform),

              try Curve25519.Signing.PrivateKey(rawRepresentation: V5Crypto.bytes(rootSeed, count: 32)).publicKey.rawRepresentation.base64EncodedString() == rootPublicKey else {
            throw IdentitySetupError.invalid("恢复文件的服务器、账号或根身份不匹配。请使用此账号的文件。")
        }
    }
}

enum RecoveryFile {
    static func validatePassword(_ password: String, confirmation: String) throws {
        guard password.unicodeScalars.count >= 16, password.utf8.count <= 1024,
              Array(password.utf8) == Array(confirmation.utf8) else {
            throw IdentitySetupError.invalid("密码至少需要 16 个 Unicode 字符，最多 1024 字节；两次输入必须完全相同，空格也会保留。")
        }
    }
    static func encrypt(_ payload: RecoveryPayload, password: String, confirmation: String) async throws -> Data {
        try validatePassword(password, confirmation: confirmation)
        let native = try MLSClient(identity: "recovery-file")
        let data = try await ClientLog.shared.measure(.crypto, "recoveryEncrypt") {
            try await native.security(["action": "encrypt", "payload": String(decoding: JSONEncoder().encode(payload), as: UTF8.self), "password": password])
        }
        struct Result: Decodable { let file: Data }
        return try JSONDecoder().decode(Result.self, from: data).file
    }
    static func decrypt(_ file: Data, password: String) async throws -> RecoveryPayload {
        guard file.count <= 54 + 65536 + 16 else { throw IdentitySetupError.invalid("恢复文件过大。") }
        let native = try MLSClient(identity: "recovery-file")
        let data: Data
        do {
            data = try await ClientLog.shared.measure(.crypto, "recoveryDecrypt") {
                try await native.security(["action": "decrypt", "file": file.base64EncodedString(), "password": password])
            }
        } catch is MLSError {
            throw IdentitySetupError.invalid("无法解锁恢复文件。请检查密码是否正确，或重新选择完整的恢复文件。")
        }
        struct Result: Decodable { let payload: String }
        let payload = try JSONDecoder().decode(RecoveryPayload.self, from: Data(JSONDecoder().decode(Result.self, from: data).payload.utf8))
        try payload.validate(origin: payload.serviceOrigin, accountID: payload.accountID, root: payload.rootPublicKey)
        return payload
    }
    @MainActor static var deviceName: String {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
        #else
        "Mac"
        #endif
    }
    static var platform: String {
        #if os(iOS)
        "iOS"
        #else
        "macOS"
        #endif
    }
    static func filename(username: String, now: Date = Date()) -> String {
        let safe = username.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX"); date.calendar = Calendar(identifier: .gregorian); date.dateFormat = "yyyy-MM-dd"
        return "\(safe)_\(date.string(from: now))_\(platform).chirpkey"
    }
}

// Monotonic, foreground-only elapsed time. The UI must also call the same gate
// on submission; keyboard and accessibility actions cannot bypass it.
struct BackupConfirmationClock {
    private var accumulated: Duration = .zero
    private var visibleSince: ContinuousClock.Instant?
    mutating func setVisible(_ visible: Bool, now: ContinuousClock.Instant = .now) {
        if let start = visibleSince { accumulated += start.duration(to: now) }
        visibleSince = visible ? now : nil
    }
    func remaining(now: ContinuousClock.Instant = .now) -> Int {
        let elapsed = accumulated + (visibleSince.map { $0.duration(to: now) } ?? .zero)
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        return max(0, Int(ceil(5 - seconds)))
    }
}

struct PendingIdentitySetup: Codable {
    var origin: String
    var accountID: String
    var rootKey: String
    var device: V5Device
    var file: Data
    var exported = false
    var confirmedDigest: String?
    var submissionStarted = false
    var digest: String { V5Crypto.hash(file) }
}

@MainActor
final class PendingIdentityStorage {
    let directory: URL
    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ChirpIdentitySetup", isDirectory: true)
    }
    private func url(_ scope: String) -> URL { directory.appendingPathComponent(SHA256.hash(data: Data(scope.utf8)).map { String(format: "%02x", $0) }.joined() + ".json") }
    func load(_ scope: String) throws -> PendingIdentitySetup? {
        let url = url(scope); guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 256 * 1024 else { throw V5IdentityError.invalid }
        return try JSONDecoder().decode(PendingIdentitySetup.self, from: Data(contentsOf: url))
    }
    func save(_ record: PendingIdentitySetup, scope: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var directory = directory; var values = URLResourceValues(); values.isExcludedFromBackup = true; try directory.setResourceValues(values)
        let data = try JSONEncoder().encode(record)
        #if os(iOS)
        try data.write(to: url(scope), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url(scope), options: .atomic)
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url(scope).path)
        let handle = try FileHandle(forWritingTo: url(scope)); try handle.synchronize(); try handle.close()
        guard try Data(contentsOf: url(scope)) == data else { throw IdentitySetupError.invalid("无法可靠保存待完成设置。") }
    }
    func remove(_ scope: String) throws { let path = url(scope); if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) } }
    func clear() throws { if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) } }
}
