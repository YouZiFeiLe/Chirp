import ChirpMLS
import Foundation

struct DevicePairingRequest: Codable, Equatable, Sendable {
    var version = 1
    var origin: String
    var accountID: String
    var accountKey: String
    var deviceKey: String
    var nonce: String
    var expiresAt: Int64
    var commitment = ""
    var signature = ""

    var expirationDate: Date { Date(timeIntervalSince1970: TimeInterval(expiresAt)) }

    var context: String {
        V5Crypto.hash(V5Crypto.message("Chirp device pairing context v1", [String(version), origin, accountID, accountKey, deviceKey, nonce, String(expiresAt)]))
    }
    var message: Data { V5Crypto.message("Chirp device pairing request v1", [context, commitment]) }
    var digest: String { V5Crypto.hash(V5Crypto.record("Chirp device pairing digest v1", [message, Data(signature.utf8)])) }
    var code: String { get throws { "chirp-device-pair-v1:" + (try JSONEncoder().encode(self)).base64EncodedString() } }

    func validate(now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard version == 1, origin == ServerAddress.identityOrigin(try ServerAddress.origin(origin)),
              !accountID.isEmpty, accountID.utf8.count <= 128, !accountID.contains(where: { $0 == "\0" || $0 == "\r" || $0 == "\n" }),
              expiresAt > now, expiresAt <= now + 300, accountKey != deviceKey else { throw V5IdentityError.invalid }
        for value in [accountKey, deviceKey, nonce, commitment] { _ = try V5Crypto.bytes(value, count: 32) }
        try V5Crypto.verify(key: deviceKey, signature: signature, message: message)
    }

    static func parse(_ code: String) throws -> Self {
        let prefix = "chirp-device-pair-v1:"
        guard code.utf8.count <= 4096, code.hasPrefix(prefix), let data = Data(base64Encoded: String(code.dropFirst(prefix.count))),
              data.count <= 3072 else { throw DevicePairingError.invalidQR }
        let value = try JSONDecoder().decode(Self.self, from: data)
        try value.validate()
        return value
    }

    enum CodingKeys: String, CodingKey {
        case version, origin, accountID = "account_id", accountKey = "account_key", deviceKey = "device_key", nonce, expiresAt = "expires_at", commitment, signature
    }
}

struct DevicePairingAction: Codable, Equatable, Sendable {
    var requestID: String
    var action: String
    var issuer: V5Device
    var payload: String
    var nonce = V5Crypto.random().base64EncodedString()
    var createdAt = Int64(Date().timeIntervalSince1970)
    var signature = ""

    var message: Data {
        V5Crypto.message("Chirp device pairing action v1", [requestID, action, issuer.digest, V5Crypto.hash(Data(payload.utf8)), nonce, String(createdAt)])
    }
    func validate(request: DevicePairingRequest, expectedAction: String, now: Int64 = Int64(Date().timeIntervalSince1970)) throws {
        guard action == expectedAction, requestID == request.digest, payload.utf8.count <= 16384,
              createdAt > 0, createdAt <= now + 60, createdAt <= request.expiresAt, createdAt >= request.expiresAt - 360 else { throw V5IdentityError.invalid }
        _ = try V5Crypto.bytes(nonce, count: 32)
        let newActor = ["poll-new", "reveal", "new-confirm", "cancel-new"].contains(action)
        if !newActor {
            try issuer.validate(now: now)
            guard issuer.accountKey == request.accountKey, issuer.certificates.last?.canEnroll == true,
                  issuer.certificates.count < V5Crypto.maxChain, issuer.leafKey != request.deviceKey else { throw V5IdentityError.invalid }
        }
        try V5Crypto.verify(key: newActor ? request.deviceKey : issuer.leafKey, signature: signature, message: message)
    }
    enum CodingKeys: String, CodingKey { case requestID = "request_id", action, issuer, payload, nonce, createdAt = "created_at", signature }
}

struct DevicePairingApproval: Codable, Sendable {
    let device: V5Device
    func validate(request: DevicePairingRequest, issuer: V5Device) throws {
        try device.validate(); try issuer.validate()
        guard device.accountKey == request.accountKey, device.leafKey == request.deviceKey,
              device.certificates.count == issuer.certificates.count + 1,
              Array(device.certificates.dropLast()) == issuer.certificates else { throw V5IdentityError.wrongDevice }
    }
}

struct DevicePairingState: Codable, Sendable {
    let request: DevicePairingRequest
    var offer: DevicePairingAction?
    var reveal: DevicePairingAction?
    var newConfirmation: DevicePairingAction?
    var oldConfirmation: DevicePairingAction?
    var approval: DevicePairingAction?
    var cancelled = false

    func validate(expected: DevicePairingRequest) throws {
        guard request == expected else { throw V5IdentityError.changed }
        try request.validate()
        for (value, action) in [(offer, "offer"), (reveal, "reveal"), (newConfirmation, "new-confirm"), (oldConfirmation, "old-confirm"), (approval, "approve")] {
            guard let value else { continue }
            try value.validate(request: request, expectedAction: action)
            guard let offer, value.issuer == offer.issuer else { throw V5IdentityError.changed }
        }
        guard reveal == nil || offer != nil, newConfirmation == nil || reveal != nil,
              oldConfirmation == nil || reveal != nil,
              approval == nil || (newConfirmation != nil && oldConfirmation != nil) else { throw V5IdentityError.invalid }
    }
    enum CodingKeys: String, CodingKey {
        case request, offer, reveal, newConfirmation = "new_confirmation", oldConfirmation = "old_confirmation", approval, cancelled
    }
}

enum DevicePairingError: LocalizedError {
    case invalidQR, expired, codeMismatch, cancelled, scopeChanged, imageTooLarge, noQRCode, cameraUnavailable
    var errorDescription: String? {
        let message: LocalizedMessage = switch self {
        case .invalidQR: "这不是有效的 Chirp 设备授权二维码。"
        case .expired: "设备授权已过期，请重新登录并生成二维码。"
        case .codeMismatch: "安全码不一致，不能授权。请直接查看新设备上的本次安全码。"
        case .cancelled: "本次设备授权已取消。"
        case .scopeChanged: "账号或本机身份已变化，本次设备授权已停止。"
        case .imageTooLarge: "二维码图片过大，请选择不超过 8 MB、4096 × 4096 像素的图片。"
        case .noQRCode: "图片中需要有且只有一个 Chirp 设备授权二维码。"
        case .cameraUnavailable: "无法使用摄像头。请检查系统的摄像头权限。"
        }
        return message.localized(in: AppLanguage.load().locale)
    }
}
