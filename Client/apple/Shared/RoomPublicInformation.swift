import Foundation

/// Advisory display metadata. Never used to extend a key lifetime or media lease.
struct GroupRoomInformation: Codable, Equatable, Sendable {
    let serverTimeMS: Int64
    let rotationIntervalMS: Int64
    let keyEpoch: UInt64
    let memberCount: Int
    let updateReason: String
    var establishedAtMS: Int64?
    var lastRotationAtMS: Int64?
    var nextRotationAtMS: Int64?
    var rotationPhase: String?
    var rotationEpoch: UInt64?
    var confirmedMembers = 0
    var activatedMembers = 0

    enum CodingKeys: String, CodingKey {
        case serverTimeMS = "server_time_ms", rotationIntervalMS = "rotation_interval_ms", keyEpoch = "key_epoch"
        case memberCount = "member_count", updateReason = "update_reason", establishedAtMS = "established_at_ms"
        case lastRotationAtMS = "last_rotation_at_ms", nextRotationAtMS = "next_rotation_at_ms"
        case rotationPhase = "rotation_phase", rotationEpoch = "rotation_epoch"
        case confirmedMembers = "confirmed_members", activatedMembers = "activated_members"
    }

    var isValid: Bool {
        guard serverTimeMS > 0, serverTimeMS < 253_402_300_799_000, keyEpoch < UInt64.max,
              (1...86_400_000).contains(rotationIntervalMS), memberCount > 0,
              (0...memberCount).contains(confirmedMembers), (0...confirmedMembers).contains(activatedMembers),
              ["initial_connection", "members_changed", "scheduled_rotation", "connection_recovery"].contains(updateReason) else { return false }
        for value in [establishedAtMS, lastRotationAtMS].compactMap({ $0 }) {
            guard value > 0, value <= serverTimeMS else { return false }
        }
        if let lastRotationAtMS {
            guard keyEpoch > 0, let establishedAtMS, lastRotationAtMS >= establishedAtMS else { return false }
        }
        if let nextRotationAtMS {
            guard establishedAtMS != nil, nextRotationAtMS > 0,
                  nextRotationAtMS <= serverTimeMS + rotationIntervalMS else { return false }
        }
        if let rotationPhase {
            guard ["collecting", "welcoming", "confirming", "ready", "switching"].contains(rotationPhase),
                  keyEpoch < UInt64.max, rotationEpoch == keyEpoch + 1 else { return false }
        } else if rotationEpoch != nil || confirmedMembers != 0 || activatedMembers != 0 { return false }
        return true
    }

    var reason: LocalizedMessage {
        switch updateReason {
        case "initial_connection": "首次建立连接"
        case "members_changed": "房间成员变化"
        case "scheduled_rotation": "例行换钥"
        default: "重新建立连接"
        }
    }

    var progress: LocalizedMessage {
        switch rotationPhase {
        case "collecting", "welcoming": "正在准备新密钥"
        case "confirming", "ready": "等待全员确认"
        case "switching": "正在切换与确认"
        default: establishedAtMS == nil ? "等待建立安全连接" : "本轮已完成"
        }
    }
}

struct RoomPublicInformation: Equatable, Sendable {
    let groupID: String
    let information: GroupRoomInformation
    let requestStartedAt: ContinuousClock.Instant
    var unavailable = false

    func isFresh(at now: ContinuousClock.Instant = .now) -> Bool {
        !unavailable && now >= requestStartedAt && requestStartedAt.duration(to: now) < .seconds(6)
    }

    /// Request transit and sleep consume the estimate. Changing the wall clock
    /// cannot restart a countdown, and zero never implies successful rotation.
    func nextRotationSeconds(at now: ContinuousClock.Instant = .now) -> Int? {
        guard isFresh(at: now), let next = information.nextRotationAtMS else { return nil }
        let elapsed = requestStartedAt.duration(to: now)
        let remaining = Double(next - information.serverTimeMS) / 1_000 - Double(elapsed.components.seconds)
            - Double(elapsed.components.attoseconds) / 1e18
        return Int(max(0, ceil(remaining)))
    }

    func eventDate(_ milliseconds: Int64?) -> Date? {
        milliseconds.map { Date(timeIntervalSince1970: Double($0) / 1_000) }
    }
}
