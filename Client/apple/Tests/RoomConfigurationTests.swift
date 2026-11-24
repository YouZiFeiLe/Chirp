import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

private func roomPayload(_ id: String) -> [String: Any] {
    ["room_id": id, "display_name": "周末大厅 😀 <朋友>", "key_protocol": VoiceRooms.keyProtocol,
     "is_default": id == "friends", "max_participants": 0, "participants": [], "media_status": "available", "password_required": false]
}

@Test func roomDescriptionsAreVerbatimWithALocalizedFallbackForOlderServers() throws {
    let chinese = AppLanguage.simplifiedChinese.locale, english = AppLanguage.english.locale
    let defaultText = "一个房间，几个朋友，随时聊聊。"
    func decode(description: Any?) throws -> RoomOverview {
        var room = roomPayload("friends")
        room["description"] = description
        let data = try JSONSerialization.data(withJSONObject: ["rooms": [room]])
        return try JSONDecoder().decode(RoomsResponse.self, from: data).validatedRooms()[0]
    }
    for value in [nil, NSNull(), "  \n"] as [Any?] {
        let room = try decode(description: value)
        #expect(room.displayDescription(in: chinese) == defaultText)
        #expect(room.displayDescription(in: english) == "A room, a few friends, a moment to talk.")
    }
    for text in [defaultText, "房间名称", "周五 8:00 🎵\n<朋友> %@ **歌单**"] {
        let room = try decode(description: text)
        #expect(room.displayDescription(in: chinese) == text)
        #expect(room.displayDescription(in: english) == text)
    }
}

@Test func dynamicRoomDirectoryRejectsRoutingPolicyAndCountConfusion() throws {
    func decode(_ rooms: [[String: Any]]) throws -> [RoomOverview] {
        try JSONDecoder().decode(RoomsResponse.self, from: JSONSerialization.data(withJSONObject: ["rooms": rooms])).validatedRooms(defaultRoomID: "friends")
    }
    let rooms = (["friends"] + (2...8).map { "room_\($0)" }).map(roomPayload)
    #expect(try decode(rooms).count == 8)
    var occupied = rooms
    occupied[0]["participants"] = (0..<32).map { ["id": "member_\($0)", "display_name": "朋友 \($0)"] }
    #expect(try decode(occupied)[0].participants?.count == 32)
    #expect(try decode(rooms)[1].displayName == "周末大厅 😀 <朋友>")
    for name in ["", "  ", " 含空白 ", "含\n换行", String(repeating: "字", count: 81)] {
        var changed = rooms; changed[0]["display_name"] = name
        #expect(throws: (any Error).self) { try decode(changed) }
    }
    for (field, value) in [("room_id", "../room"), ("key_protocol", "chirp-mls-reinit-v1"), ("media_status", "invented")] {
        var changed = rooms; changed[0][field] = value
        #expect(throws: (any Error).self) { try decode(changed) }
    }
    #expect(try decode(Array(rooms.prefix(1))).count == 1)
    #expect(throws: (any Error).self) { try decode([]) }
    #expect(throws: (any Error).self) { try decode(Array(rooms.dropFirst())) }
    #expect(throws: (any Error).self) { try decode(rooms + [rooms[0]]) }
    var duplicate = rooms; duplicate[1]["room_id"] = "friends"
    #expect(throws: (any Error).self) { try decode(duplicate) }
    var unavailable = rooms; unavailable[0]["media_status"] = "unavailable"; unavailable[0]["participants"] = NSNull()
    #expect(try decode(unavailable)[0].participants == nil)
}

@Test func joinResponseCannotChangeRoomEntryLoginOrSecurityPolicy() throws {
    let now = Int64(Date().timeIntervalSince1970)
    let login = try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "member": ["id": "member_test", "display_name": "Oliver"],
        "credential": "chirp_" + String(repeating: "a", count: 43),
        "expires_at": now + 3600, "participant_identity": "member_test.login_test"
    ]), connection: testServerConnection)
    let entry = "entry_" + String(repeating: "a", count: 32)
    let body: [String: Any] = [
        "livekit_url": "wss://rtc.example.com", "room_id": "room-2", "display_name": "朋友们",
        "entry_id": entry, "join_sequence": 4, "admission_expires_at": now + 30,
        "participant_identity": login.participantIdentity + "." + entry, "token": "synthetic",
        "key_protocol": VoiceRooms.keyProtocol, "media_transport": "udp", "e2ee_required": true
    ]
    func validate(_ body: [String: Any]) throws {
        let response = try JSONDecoder().decode(JoinResponse.self, from: JSONSerialization.data(withJSONObject: body))
        try response.validate(roomID: "room-2", sequence: 4, login: login)
    }
    try validate(body)
    let invalid: [(String, Any)] = [
        ("room_id", "friends"), ("entry_id", "entry_bad"), ("join_sequence", 3),
        ("participant_identity", "member_test.login_other." + entry),
        ("admission_expires_at", now - 1), ("admission_expires_at", now + 3601),
        ("key_protocol", "chirp-mls-reinit-v1"), ("media_transport", "tcp"), ("e2ee_required", false)
    ]
    for (field, value) in invalid {
        var changed = body; changed[field] = value
        #expect(throws: (any Error).self) { try validate(changed) }
    }
}
