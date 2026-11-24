import Foundation
import ChirpMLSNative

public struct MLSPeer: Codable, Equatable, Sendable {
    public let identity: String
    public let name: String
    public let publicKey: String
    public let keyPackage: String
    public var binding: V5EntryBinding?
    public var offer: V5RoundProof?
    public var ready: V5ReadyProof?
    public init(identity: String, name: String, publicKey: String, keyPackage: String, binding: V5EntryBinding? = nil, offer: V5RoundProof? = nil, ready: V5ReadyProof? = nil) {
        self.identity = identity; self.name = name; self.publicKey = publicKey; self.keyPackage = keyPackage
        self.binding = binding; self.offer = offer; self.ready = ready
    }
    enum CodingKeys: String, CodingKey { case identity, name, binding, offer, ready; case publicKey = "public_key", keyPackage = "key_package" }
}

public struct MLSWelcome: Sendable {
    public let welcome: String
    public let confirmation: String
}

public enum MLSError: LocalizedError {
    case failed(String)
    public var errorDescription: String? {
        switch self { case .failed(let detail): "安全群组验证失败：\(detail)" }
    }
}

// The Rust context serializes access through its own Mutex. Ownership remains
// with this reference so actor teardown never sends an unowned raw pointer.
private final class NativeHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(identity: String) throws {
        try Self.validateIdentity(identity)
        guard let pointer = identity.withCString({ chirp_mls_new($0) }) else { throw MLSError.failed("无法创建客户端身份") }
        self.pointer = pointer
    }
    deinit { chirp_mls_free(pointer) }

    static func validateIdentity(_ identity: String) throws {
        // withCString terminates at NUL. Validate before crossing either C
        // identity boundary so Swift and Rust always authorize the same bytes.
        guard !identity.isEmpty, identity.utf8.count <= 192,
              identity.utf8.allSatisfy({ $0 > 0 && $0 < 128 }) else {
            throw MLSError.failed("客户端身份无效")
        }
    }
}

public actor MLSClient {
    public nonisolated let identity: String
    private let handle: NativeHandle

    public init(identity: String) throws {
        self.identity = identity
        handle = try NativeHandle(identity: identity)
    }

    public func publicKey() throws -> String { try field("public_key", from: call(["operation": "identity"])) }
    public func keyPackage() throws -> String { try field("key_package", from: call(["operation": "key_package"])) }
    public func sign(_ proof: Data) throws -> String {
        try field("signature", from: call(["operation": "sign", "message": proof.base64EncodedString()]))
    }

    public func authorize(policy: V5RoomPolicy, trustedOwner: String, origin: String, roomID: String) throws {
        try policy.validate()
        guard policy.ownerKey == trustedOwner, policy.origin == origin, policy.roomID == roomID else { throw V5IdentityError.untrusted }
        _ = try call(["operation": "authorize", "policy": try JSONSerialization.jsonObject(with: JSONEncoder().encode(policy)), "trusted_owner": trustedOwner, "origin": origin, "room_id": roomID])
    }

    /// Called only after local identity, independent revocation state and exact
    /// admission bindings have been verified. Server snapshots are not approval.
    public func approve(groupID: String, members: [MLSPeer], authorizationHash: String) throws {
        _ = try V5Crypto.bytes(authorizationHash, count: 32)
        _ = try call(["operation": "approve", "group_id": groupID, "members": try publicMembers(members), "authorization_hash": authorizationHash])
    }

    public func create(groupID: String, members: [MLSPeer], keyEpoch: UInt64 = 0) throws -> MLSWelcome {
        let result = try call(["operation": "create", "group_id": groupID, "key_epoch": keyEpoch, "members": try publicMembers(members)])
        return MLSWelcome(welcome: try field("welcome", from: result), confirmation: try field("confirmation", from: result))
    }

    public func join(groupID: String, members: [MLSPeer], welcome: String, keyEpoch: UInt64 = 0) throws -> String {
        try field("confirmation", from: call(["operation": "join", "group_id": groupID, "key_epoch": keyEpoch, "members": try publicMembers(members), "welcome": welcome]))
    }

    public func keyLifetimeMilliseconds(staged: Bool = false) throws -> Int64 {
        let value = try field("milliseconds", from: call(["operation": staged ? "staged_lifetime" : "lifetime"]))
        guard let milliseconds = Int64(value), milliseconds > 0, milliseconds <= 120_000 else { throw V5IdentityError.expired }
        return milliseconds
    }

    public func senderKey(for identity: String, staged: Bool = false) throws -> Data {
        try NativeHandle.validateIdentity(identity)
        var data = Data(count: 32)
        let result = data.withUnsafeMutableBytes { bytes in
            identity.withCString {
                let output = bytes.bindMemory(to: UInt8.self).baseAddress
                return staged ? chirp_mls_staged_media_key(handle.pointer, $0, output) : chirp_mls_media_key(handle.pointer, $0, output)
            }
        }
        guard result == 0 else { data.resetBytes(in: 0..<data.count); throw MLSError.failed("发送者尚未取得有效密钥") }
        return data
    }

    public func security(_ parameters: [String: String]) throws -> Data {
        try JSONSerialization.data(withJSONObject: call(["operation": "security", "security": parameters]), options: [.sortedKeys])
    }

    public func clear() throws { _ = try call(["operation": "clear"]) }

    public func stagedKeyPackage() throws -> String { try field("key_package", from: call(["operation": "staged_key_package"])) }
    public func createStaged(groupID: String, members: [MLSPeer], keyEpoch: UInt64 = 1) throws -> MLSWelcome {
        let result = try call(["operation": "staged_create", "group_id": groupID, "key_epoch": keyEpoch, "members": try publicMembers(members)])
        return MLSWelcome(welcome: try field("welcome", from: result), confirmation: try field("confirmation", from: result))
    }
    public func joinStaged(groupID: String, members: [MLSPeer], welcome: String, keyEpoch: UInt64 = 1) throws -> String {
        try field("confirmation", from: call(["operation": "staged_join", "group_id": groupID, "key_epoch": keyEpoch, "members": try publicMembers(members), "welcome": welcome]))
    }
    public func activateStaged(groupID: String) throws { _ = try call(["operation": "activate_staged", "group_id": groupID]) }
    public func discardStaged() throws { _ = try call(["operation": "discard_staged"]) }

    private func publicMembers(_ members: [MLSPeer]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(members))
    }

    private func field(_ key: String, from response: [String: Any]) throws -> String {
        guard let value = response[key] as? String else { throw MLSError.failed("原生组件响应不完整") }
        return value
    }

    private func call(_ parameters: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: parameters, options: [.sortedKeys])
        let input = String(decoding: data, as: UTF8.self)
        guard let result = input.withCString({ chirp_mls_call(handle.pointer, $0) }) else { throw MLSError.failed("原生组件无法响应") }
        defer { chirp_mls_string_free(result) }
        let output = Data(bytes: result, count: strlen(result))
        guard let response = try JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw MLSError.failed("原生组件响应无效") }
        if let error = response["error"] as? String { throw MLSError.failed(error) }
        return response
    }
}
