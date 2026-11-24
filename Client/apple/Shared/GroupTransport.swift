import Foundation
import CryptoKit
import ChirpMLS

struct GroupConfiguration: Decodable, Sendable {
    let roomID: String
    let protocolName: String
    let serverID: String
    let heartbeatMS: Int
    let leaseRefreshMS: Int
    let maxLeaseMS: Int
    var smoothRotation: Bool?
    var identityPolicy: V5RoomPolicy?
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", protocolName = "protocol", serverID = "server_id", heartbeatMS = "heartbeat_ms", maxLeaseMS = "max_lease_ms", leaseRefreshMS = "lease_refresh_ms", smoothRotation = "smooth_rotation", identityPolicy = "identity_policy"
    }
}

struct GroupSnapshot: Decodable, Sendable {
    let roomID: String
    let protocolName: String
    let serverID: String
    let sessionID: String
    let generation: UInt64
    let phase: String
    let leader: String
    let members: [MLSPeer]
    let welcome: String
    let confirmation: String
    let revision: UInt64
    let suspended: Bool
    var keyEpoch: UInt64?
    var rotationRevision: UInt64?
    var rotation: GroupRotation?
    var identityPolicy: V5RoomPolicy?
    var groupID: String { "\(roomID)/\(serverID)/\(sessionID)/\(generation)" }
    var roomInformation: GroupRoomInformation?
    var requestStartedAt: ContinuousClock.Instant?
    enum CodingKeys: String, CodingKey {
        case generation, phase, leader, members, welcome, confirmation
        case roomID = "room_id", protocolName = "protocol", serverID = "server_id", sessionID = "session_id", revision, suspended
        case keyEpoch = "key_epoch", rotationRevision = "rotation_revision", rotation
        case identityPolicy = "identity_policy"
        case roomInformation = "room_information"
    }
}

struct GroupRotation: Decodable, Sendable {
    let epoch: UInt64
    let phase: String
    let members: [MLSPeer]
    let welcome: String
    let confirmation: String
    func groupID(in snapshot: GroupSnapshot) -> String { "\(snapshot.groupID)/key/\(epoch)" }
    var keyIndex: Int32 { Int32(epoch % 2) }
}

struct GroupRequest: Encodable {
    var roomID: String
    var entryID: String
    var serverID: String
    var sessionID = ""
    var generation: UInt64 = 0
    var operation: String
    var keyPackage: String?
    var welcome: String?
    var confirmation: String?
    var revision: UInt64?
    var smoothRotation: Bool?
    var keyEpoch: UInt64?
    var binding: V5EntryBinding?
    var offer: V5RoundProof?
    var ready: V5ReadyProof?
    var logOperation: StaticString {
        switch operation {
        case "join": "groupJoin"
        case "leave": "groupLeave"
        case "refresh": "groupRefresh"
        case "snapshot": "groupSnapshot"
        case "heartbeat": "groupHeartbeat"
        case "lease": "mediaLease"
        case "watch": "groupEvents"
        case "package": "groupKeyPackage"
        case "publish": "groupPublish"
        case "ack": "groupAcknowledge"
        case "rotation_package": "rotationPackage"
        case "rotation_publish": "rotationPublish"
        case "rotation_ack": "rotationAcknowledge"
        case "rotation_activate": "rotationActivate"
        default: "groupAction"
        }
    }

    enum CodingKeys: String, CodingKey {
        case generation, operation, welcome, confirmation, revision, binding, offer, ready
        case roomID = "room_id", entryID = "entry_id", serverID = "server_id", sessionID = "session_id", keyPackage = "key_package"
        case smoothRotation = "smooth_rotation", keyEpoch = "key_epoch"
    }
}

enum GroupRequestError: LocalizedError, ClientFailureProviding {
    case conflict(String), unavailable, throttled(Int)
    var clientFailure: ClientFailure {
        switch self {
        case .conflict: ClientFailure(.groupStateChanged)
        case .unavailable: ClientFailure(.groupUnavailable)
        case let .throttled(seconds): ClientFailure(.groupRequestRejected, retryAfter: seconds)
        }
    }
    var errorDescription: String? { clientFailure.errorDescription }
}

struct GroupTransport: Sendable {
    let baseURL: URL
    let credential: String
    let identity: String
    let admission: RoomAdmission
    let native: MLSClient
    let publicKey: String
    private let session: HTTPDataSession

    init(baseURL: URL, login: ClientSession, admission: RoomAdmission, native: MLSClient, publicKey: String) {
        self.baseURL = baseURL; credential = login.credential; identity = admission.identity; self.admission = admission
        self.native = native; self.publicKey = publicKey
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 2
        configuration.timeoutIntervalForResource = 3
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        session = HTTPDataSession(configuration: configuration)
    }

    func configuration() async throws -> GroupConfiguration {
        var request = URLRequest(url: baseURL.appendingPathComponent("rooms/\(admission.roomID)/config"))
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return try JSONDecoder().decode(GroupConfiguration.self, from: await response(request))
    }

    func snapshot(_ action: GroupRequest) async throws -> GroupSnapshot {
        let request = try await signedRequest(action, endpoint: "action")
        let started = ContinuousClock.now
        var result = try JSONDecoder().decode(GroupSnapshot.self, from: await response(request, operation: action.logOperation))
        result.requestStartedAt = started
        return result
    }

    func pulse(_ action: GroupRequest) async throws -> (GroupPulse, ContinuousClock.Instant) {
        let request = try await signedRequest(action, endpoint: "action")
        let started = ContinuousClock.now
        return (try JSONDecoder().decode(GroupPulse.self, from: await response(request, operation: action.logOperation)), started)
    }

    func events(_ action: GroupRequest) async throws -> HTTPEventConnection {
        var request = try await signedRequest(action, endpoint: "events")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15
        try Task.checkCancellation()
        return HTTPEventConnection(request: request, operation: action.logOperation)
    }

    private func signedRequest(_ action: GroupRequest, endpoint: String) async throws -> URLRequest {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(action)
        let timestamp = String(Int64(Date().timeIntervalSince1970)), nonce = UUID().uuidString
        let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
        let proof = Data("Chirp group request v5\n\(identity)\nPOST\n/v1/group/rooms/\(admission.roomID)/\(endpoint)\n\(timestamp)\n\(nonce)\n\(hash)".utf8)
        var request = URLRequest(url: baseURL.appendingPathComponent("rooms/\(admission.roomID)/\(endpoint)"))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(timestamp, forHTTPHeaderField: "X-Chirp-Time")
        request.setValue(nonce, forHTTPHeaderField: "X-Chirp-Nonce")
        request.setValue(publicKey, forHTTPHeaderField: "X-Chirp-Key")
        request.setValue(try await native.sign(proof), forHTTPHeaderField: "X-Chirp-Signature")
        return request
    }

    func close() { session.close() }

    private func response(_ request: URLRequest, operation: StaticString = #function) async throws -> Data {
        let (data, result) = try await session.data(for: request, maxBytes: 256 * 1024, operation: operation)
        guard let response = result as? HTTPURLResponse, data.count <= 256 * 1024 else { throw ClientFailure(.invalidGroupResponse) }
        if response.statusCode == 401 { throw APIError.unauthorized }
        if response.statusCode == 403 { throw ClientFailure(.groupIdentityInvalid) }
        if response.statusCode == 409 {
            struct Failure: Decodable { struct Detail: Decodable { let code: String }; let error: Detail }
            let code = (try? JSONDecoder().decode(Failure.self, from: data).error.code) ?? "GROUP_CONFLICT"
            throw GroupRequestError.conflict(code)
        }
        if response.statusCode >= 500 { throw GroupRequestError.unavailable }
        if response.statusCode == 429 {
            throw GroupRequestError.throttled(min(3, max(1, Int(response.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1)))
        }
        guard response.statusCode == 200 else { throw ClientFailure(.groupRequestRejected) }
        return data
    }
}


struct GroupPulse: Decodable, Sendable {
    let roomID: String
    let protocolName: String
    let serverID: String
    let sessionID: String
    let generation: UInt64
    let revision: UInt64
    let phase: String
    let suspended: Bool
    let leaseMS: Int
    var keyEpoch: UInt64?
    var rotationRevision: UInt64?
    var roomInformation: GroupRoomInformation?
    var groupID: String { "\(roomID)/\(serverID)/\(sessionID)/\(generation)" }
    enum CodingKeys: String, CodingKey {
        case generation, revision, phase, suspended
        case roomID = "room_id", protocolName = "protocol", serverID = "server_id", sessionID = "session_id", leaseMS = "lease_ms"
        case keyEpoch = "key_epoch", rotationRevision = "rotation_revision"
        case roomInformation = "room_information"
    }

    func validate(expected: GroupSnapshot, grantingLease: Bool, expectedKeyEpoch: UInt64 = 0) throws {
        guard roomID == expected.roomID, protocolName == VoiceRooms.keyProtocol, serverID == expected.serverID,
              sessionID == expected.sessionID, generation >= expected.generation, revision >= expected.revision,
              generation == expected.generation || revision > expected.revision,
              (0...3_000).contains(leaseMS), ["collecting", "welcoming", "confirming", "ready"].contains(phase),
              phase == "ready" || leaseMS == 0, !suspended || leaseMS == 0 else { throw ClientFailure(.invalidGroupResponse) }
        if grantingLease {
            guard groupID == expected.groupID, revision == expected.revision, phase == "ready", !suspended, leaseMS > 0,
                  (keyEpoch ?? 0) == expectedKeyEpoch else {
                throw ClientFailure(.invalidMediaLease)
            }
        } else if leaseMS != 0 { throw ClientFailure(.invalidMediaLease) }
    }
}
