import Foundation
import ChirpMLS

final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum APIError: LocalizedError, ClientFailureProviding {
    case unauthorized, disabled
    case roomAccess(ClientFailure)
    var needsRoomPassword: Bool {
        if case let .roomAccess(failure) = self {
            return ["ROOM_PASSWORD_REQUIRED", "ROOM_PASSWORD_INCORRECT", "ROOM_PASSWORD_CHANGED", "ROOM_PREFLIGHT_EXPIRED"].contains(failure.code)
        }
        return false
    }
    var clientFailure: ClientFailure {
        switch self {
        case .unauthorized: ClientFailure(.unauthorized)
        case .disabled: ClientFailure(.memberDisabled)
        case let .roomAccess(failure): failure
        }
    }
    var errorDescription: String? { clientFailure.errorDescription }
}

struct APIClient: Sendable {
    let baseURL: URL
    let credential: String
    private let session: HTTPDataSession
    private let uploadSession: HTTPDataSession

    init(baseURL: URL, credential: String, configuration: URLSessionConfiguration? = nil) {
        self.baseURL = baseURL
        self.credential = credential
        let configuration = configuration ?? URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        self.session = HTTPDataSession(configuration: configuration)
        // URLSession copies its configuration at creation. Give binary uploads
        // their own deadlines while retaining the ordinary API time limits.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        self.uploadSession = HTTPDataSession(configuration: configuration)
    }

    func me() async throws -> MemberInfo { try await request("v1/me") }
    func profile() async throws -> MemberProfile {
        let profile: MemberProfile = try await request("v1/me")
        return try profile.validated()
    }
    func profiles() async throws -> [MemberProfile] {
        let response: MemberProfilesResponse = try await request("v1/members")
        return try response.validatedMembers()
    }
    func rename(_ name: String) async throws -> MemberProfile {
        struct Rename: Encodable { let display_name: String }
        let profile: MemberProfile = try await request("v1/me", method: "PATCH", body: JSONEncoder().encode(Rename(display_name: name)))
        return try profile.validated()
    }
    func setAvatar(_ data: Data) async throws -> MemberProfile {
        guard !data.isEmpty, data.count < AvatarImage.maxBytes else { throw ClientFailure(.avatarTooLarge) }
        let profile: MemberProfile = try await request("v1/me/avatar", method: "PUT", body: data, contentType: "image/png")
        return try profile.validated()
    }
    func deleteAvatar() async throws -> MemberProfile {
        let profile: MemberProfile = try await request("v1/me/avatar", method: "DELETE")
        return try profile.validated()
    }
    func avatar(memberID: String, revision: String) async throws -> Data {
        let (data, response) = try await send("v1/members/\(memberID)/avatar/\(revision)", accept: "image/png")
        guard response.value(forHTTPHeaderField: "Content-Type") == "image/png", data.count < AvatarImage.maxBytes else {
            throw ClientFailure(.avatarInvalid)
        }
        return data
    }
    func identityBlacklist() async throws -> [BlacklistRecord] { try await request("v1/identity/blacklist") }
    func identityDevices() async throws -> [RegisteredIdentityDevice] { try await request("v1/identity/devices") }
    func renameIdentityDevice(_ key: String, name: String) async throws {
        struct Body: Encodable { let name: String }; _ = try await send("v1/identity/devices/\(Self.routeKey(key))", method: "PATCH", body: JSONEncoder().encode(Body(name: name)))
    }
    func revokeIdentityDevice(_ key: String) async throws { _ = try await send("v1/identity/devices/\(Self.routeKey(key))", method: "DELETE") }
    func socialEvents(after version: Int64) async throws -> [SocialIdentityEvent] { try await request("v1/identity/social/\(version)") }
    func appendSocial(_ event: SocialIdentityEvent) async throws { _ = try await send("v1/identity/social", method: "POST", body: JSONEncoder().encode(event)) }
    func identitySignals(after sequence: Int64) async throws -> [RoutedIdentitySignal] { try await request("v1/identity/signals/\(sequence)") }
    func sendIdentitySignal(_ signal: IdentitySignal) async throws { _ = try await send("v1/identity/signals", method: "POST", body: JSONEncoder().encode(signal)) }
    private static func routeKey(_ key: String) -> String { key.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    func rooms() async throws -> RoomsResponse { try await request("v1/rooms") }
    func roomIdentityPolicy(roomID: String) async throws -> V5RoomPolicy { try await request("v1/rooms/\(roomID)/identity-policy") }
    func publishRoomIdentityPolicy(_ policy: V5RoomPolicy) async throws -> V5RoomPolicy {
        try await request("v1/rooms/\(policy.roomID)/identity-policy", method: "PUT", body: JSONEncoder().encode(policy))
    }
    func state() async throws -> ClientStateSnapshot {
        let (data, _) = try await send("v1/state")
        guard data.count <= 2 * 1_024 * 1_024 else { throw ClientFailure(.invalidResponse) }
        return try JSONDecoder().decode(ClientStateSnapshot.self, from: data)
    }
    func close() { session.close(); uploadSession.close() }
    func joinSequence(for login: ClientSession) async throws -> Int64 {
        struct State: Decodable { let member: MemberInfo; let participant_identity: String; let join_sequence: Int64 }
        let state: State = try await request("v1/session")
        guard state.member.id == login.member.id, state.participant_identity == login.participantIdentity else { throw APIError.unauthorized }
        guard state.join_sequence >= 0, state.join_sequence < Int64.max else { throw ClientFailure(.invalidJoinSequence) }
        return state.join_sequence
    }
    func preflight(roomID: String, sequence: Int64, password: String?) async throws -> RoomPreflight {
        struct Check: Encodable { let join_sequence: Int64; let password: String? }
        return try await request("v1/rooms/\(roomID)/preflight", body: JSONEncoder().encode(Check(join_sequence: sequence, password: password)))
    }
    func join(roomID: String, sequence: Int64, proof: String) async throws -> JoinResponse {
        struct Join: Encodable { let join_sequence: Int64; let preflight_proof: String }
        return try await request("v1/rooms/\(roomID)/join", body: JSONEncoder().encode(Join(join_sequence: sequence, preflight_proof: proof)))
    }

    // No call teardown happens here. Only a fully validated admission may be
    // handed to CallController for a switch; preflight and admission errors throw.
    func authorizeRoom(roomID: String, sequence: Int64, login: ClientSession, password: String?) async throws -> JoinResponse {
        let check = try await preflight(roomID: roomID, sequence: sequence, password: password)
        try Task.checkCancellation()
        try check.validate(roomID: roomID, sequence: sequence, login: login)
        let response = try await join(roomID: roomID, sequence: sequence, proof: check.proof)
        do {
            try response.validate(roomID: roomID, sequence: sequence, login: login)
            _ = try ServerAddress.validate(response.livekitURL, websocket: true)
            try Task.checkCancellation()
            return response
        } catch {
            // Cleanup is independent of the canceled caller, and never uses an
            // untrusted response to revoke another room/identity's admission.
            if response.matchesAdmission(roomID: roomID, sequence: sequence, login: login) {
                await Task.detached { try? await leave(response.admission) }.value
            }
            throw error
        }
    }
    func freshMediaToken(_ admission: RoomAdmission) async throws -> String {
        struct Body: Encodable { let entry_id: String }
        struct Token: Decodable { let room_id: String; let entry_id: String; let participant_identity: String; let token: String; let expires_at: String }
        let value: Token = try await request("v1/rooms/\(admission.roomID)/media-token", body: JSONEncoder().encode(Body(entry_id: admission.entryID)))
        guard value.room_id == admission.roomID, value.entry_id == admission.entryID, value.participant_identity == admission.identity,
              let expires = ISO8601DateFormatter().date(from: value.expires_at), expires > Date(), !value.token.isEmpty else { throw ClientFailure(.invalidAdmission) }
        return value.token
    }
    func leave(_ admission: RoomAdmission) async throws {
        struct Leave: Encodable { let entry_id: String }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/rooms/\(admission.roomID)/leave"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Leave(entry_id: admission.entryID))
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw ClientFailure(.leaveFailed) }
    }

    func logout() async throws {
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/logout"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw APIError.unauthorized }
    }

    private func request<T: Decodable>(_ path: String, method: String? = nil, body: Data? = nil, contentType: String = "application/json", operation: StaticString = #function) async throws -> T {
        let (data, _) = try await send(path, method: method, body: body, contentType: contentType, operation: operation)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func send(_ path: String, method: String? = nil, body: Data? = nil,
                      contentType: String = "application/json", accept: String = "application/json", operation: StaticString = #function) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method ?? (body == nil ? "GET" : "POST")
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        let isUpload = path == "v1/me/avatar" && method == "PUT"
        if isUpload { request.timeoutInterval = 60 }
        request.httpBody = body
        let limit = accept == "image/png" ? AvatarImage.maxBytes - 1 : 2 * 1_024 * 1_024
        let (data, response) = try await (isUpload ? uploadSession : session).data(for: request, maxBytes: limit, operation: operation)
        guard let response = response as? HTTPURLResponse else { throw ClientFailure(.invalidResponse) }
        if response.statusCode == 401 { throw APIError.unauthorized }
        guard (200..<300).contains(response.statusCode) else {
            let failure = ClientFailure.response(data: data, status: response.statusCode,
                                                 retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            if response.statusCode == 403 && failure.code == "MEMBER_DISABLED" { throw APIError.disabled }
            if failure.code.hasPrefix("ROOM_") { throw APIError.roomAccess(failure) }
            throw failure
        }
        return (data, response)
    }
}
