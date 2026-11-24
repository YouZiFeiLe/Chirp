import Foundation
import Security

enum ServerAddress {
    static func validate(_ text: String, websocket: Bool = false) throws -> URL {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")),
              !host.isEmpty, !host.contains("*"), url.port.map({ (1...65535).contains($0) }) ?? true, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ClientFailure(.invalidServerAddress)
        }
        guard !["livekit.cloud", "livekit.run", "livekit.io"].contains(where: { host == $0 || host.hasSuffix("." + $0) }) else {
            throw ClientFailure(.hostedServerUnsupported)
        }
        let secure = websocket ? "wss" : "https"
        #if DEBUG
        let local = ["localhost", "127.0.0.1", "::1"].contains(host)
        if local && url.scheme == (websocket ? "ws" : "http") { return url }
        #endif
        guard url.scheme == secure else { throw ClientFailure(.insecureServerAddress) }
        return url
    }

    static func identityOrigin(_ url: URL) -> String {
        var value = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        value.host = url.host?.lowercased(); value.port = url.port ?? (url.scheme == "https" ? 443 : 80)
        value.path = ""; value.query = nil; value.fragment = nil
        return value.string!
    }

    static func normalized(_ url: URL) -> String {
        var value = url.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }

    static func baseURL(forUserInput text: String) throws -> URL {
        let address = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // A scheme ends in ":" before the first slash, while "host:port" ends in the port number.
        let authority = address.prefix { $0 != "/" }
        if authority.isEmpty || authority.hasSuffix(":") {
            return try baseURL(address)
        }
        return try baseURL("https://" + address)
    }

    static func baseURL(_ text: String) throws -> URL {
        let url = try validate(text)
        guard let host = url.host, !host.contains("*"),
              url.port.map({ (1...65535).contains($0) }) ?? true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClientFailure(.invalidServerAddress)
        }
        components.host = host.lowercased()
        if !components.path.hasSuffix("/") { components.path += "/" }
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        guard let result = components.url else { throw ClientFailure(.invalidServerAddress) }
        return result
    }

    static func sameOrigin(_ left: URL, _ right: URL) -> Bool {
        left.scheme == right.scheme && left.host?.lowercased() == right.host?.lowercased()
            && (left.port ?? (left.scheme == "https" ? 443 : 80)) == (right.port ?? (right.scheme == "https" ? 443 : 80))
    }

    static func origin(_ text: String) throws -> URL {
        let url = try validate(text)
        guard (url.path.isEmpty || url.path == "/"),
              let host = url.host, !host.contains("*"),
              url.port.map({ (1...65535).contains($0) }) ?? true,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClientFailure(.invalidServerAddress)
        }
        components.host = host.lowercased()
        components.path = ""
        if (components.scheme == "https" && components.port == 443) ||
            (components.scheme == "http" && components.port == 80) { components.port = nil }
        guard let origin = components.url else { throw ClientFailure(.invalidServerAddress) }
        return origin
    }
}

struct MemberInfo: Codable, Identifiable, Sendable {
    let id: String
    let displayName: String
    enum CodingKeys: String, CodingKey { case id; case displayName = "display_name" }
}

enum VoiceRooms {
    static let maxNameLength = 80

    static func validID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 64 && id.allSatisfy {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-")
        }
    }
    static let keyProtocol = "chirp-mls-authenticated-v5"
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name == name.trimmingCharacters(in: .whitespacesAndNewlines)
            && name.unicodeScalars.count <= maxNameLength
            && !name.unicodeScalars.contains { $0.properties.generalCategory == .control }
    }
}

struct RoomOverview: Decodable, Identifiable, Sendable {
    let roomID: String
    let displayName: String
    var description: String?
    let keyProtocol: String
    let maxParticipants: Int
    let participants: [MemberInfo]?
    let mediaStatus: String
    let passwordRequired: Bool
    var isDefault: Bool = false
    var id: String { roomID }
    var isAvailable: Bool { mediaStatus == "available" }
    var summary: LocalizedMessage { isAvailable ? "\(participants?.count ?? 0) 位成员" : "在线状态暂时未知" }
    func localizedDisplayName(in locale: Locale) -> String {
        mediaStatus == "loading" ? LocalizedMessage("正在读取房间…").localized(in: locale) : displayName
    }
    func displayDescription(in locale: Locale) -> String {
        guard let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return LocalizedMessage("一个房间，几个朋友，随时聊聊。").localized(in: locale)
        }
        return description
    }
    enum CodingKeys: String, CodingKey {
        case description, participants
        case roomID = "room_id", displayName = "display_name", keyProtocol = "key_protocol"
        case maxParticipants = "max_participants", mediaStatus = "media_status", passwordRequired = "password_required", isDefault = "is_default"
    }
    static func loading(id: String) -> RoomOverview {
        RoomOverview(roomID: id, displayName: "", keyProtocol: VoiceRooms.keyProtocol, maxParticipants: 0,
                     participants: nil, mediaStatus: "loading", passwordRequired: false)
    }

}

struct RoomsResponse: Decodable, Sendable {
    let rooms: [RoomOverview]
    func validatedRooms(defaultRoomID: String? = nil) throws -> [RoomOverview] {
        guard !rooms.isEmpty, Set(rooms.map(\.roomID)).count == rooms.count,
              rooms.filter(\.isDefault).count == 1, rooms.first?.isDefault == true,
              defaultRoomID == nil || rooms.first?.roomID == defaultRoomID,
              rooms.allSatisfy({ room in
                  VoiceRooms.validID(room.roomID) && VoiceRooms.validName(room.displayName) && room.keyProtocol == VoiceRooms.keyProtocol
                      && room.maxParticipants == 0 && ["available", "unavailable"].contains(room.mediaStatus)
                      && (room.isAvailable ? room.participants != nil : room.participants == nil)
                      && Set((room.participants ?? []).map(\.id)).count == (room.participants?.count ?? 0)
              }) else { throw ClientFailure(.invalidRoomList) }
        return rooms
    }

}

struct RoomAdmission: Sendable {
    let roomID: String
    let entryID: String
    let identity: String
}

struct RoomPreflight: Decodable, Sendable {
    let roomID: String
    let joinSequence: Int64
    let proof: String
    let expiresAt: Int64
    enum CodingKeys: String, CodingKey {
        case roomID = "room_id", joinSequence = "join_sequence", proof = "preflight_proof", expiresAt = "expires_at"
    }
    func validate(roomID requested: String, sequence: Int64, login: ClientSession) throws {
        guard roomID == requested, VoiceRooms.validID(roomID), joinSequence == sequence,
              expiresAt > Int64(Date().timeIntervalSince1970), expiresAt <= Int64(login.expiresAt.timeIntervalSince1970),
              !proof.isEmpty, proof.utf8.count <= 2048,
              proof.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" || $0 == ".") }),
              proof.split(separator: ".", omittingEmptySubsequences: false).count == 2 else {
            throw ClientFailure(.invalidPreflight)
        }
    }
}

struct JoinResponse: Decodable, Sendable {
    let livekitURL: String
    let roomID: String
    let displayName: String
    let entryID: String
    let joinSequence: Int64
    let admissionExpiresAt: Int64
    let participantIdentity: String
    let token: String
    let keyProtocol: String
    let mediaTransport: String
    let e2eeRequired: Bool
    var admission: RoomAdmission { RoomAdmission(roomID: roomID, entryID: entryID, identity: participantIdentity) }
    func matchesAdmission(roomID requestedRoom: String, sequence: Int64, login: ClientSession) -> Bool {
        roomID == requestedRoom && VoiceRooms.validID(roomID) && joinSequence == sequence
            && entryID.count == 38 && entryID.hasPrefix("entry_")
            && entryID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") })
            && participantIdentity == login.participantIdentity + "." + entryID
    }
    func validate(roomID requestedRoom: String, sequence: Int64, login: ClientSession) throws {
        guard matchesAdmission(roomID: requestedRoom, sequence: sequence, login: login), VoiceRooms.validName(displayName),
              admissionExpiresAt > Int64(Date().timeIntervalSince1970),
              admissionExpiresAt <= Int64(login.expiresAt.timeIntervalSince1970),
              e2eeRequired, mediaTransport == "udp", keyProtocol == VoiceRooms.keyProtocol else {
            throw ClientFailure(.invalidAdmission)
        }
    }
    enum CodingKeys: String, CodingKey {
        case token
        case livekitURL = "livekit_url", roomID = "room_id", displayName = "display_name", entryID = "entry_id"
        case joinSequence = "join_sequence", admissionExpiresAt = "admission_expires_at"
        case participantIdentity = "participant_identity", keyProtocol = "key_protocol"
        case mediaTransport = "media_transport", e2eeRequired = "e2ee_required"
    }
}
