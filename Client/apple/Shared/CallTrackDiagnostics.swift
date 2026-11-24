import Foundation

enum CallTrackEncryption: String, Codable, Sendable { case waiting, verified, missingKey, decryptionFailed, failed }
enum CallNetworkQuality: String, Codable, Sendable { case unknown, excellent, good, poor, lost }

struct CallTrackDiagnostic: Equatable, Sendable, Identifiable {
    let id: String
    let identity: String
    var muted: Bool
    var subscribed: Bool
    var encryption: CallTrackEncryption
    var quality: CallNetworkQuality
    // Time of the SDK's last E2EE .ok event, not a timestamp for every audio frame.
    var lastDecryption: ContinuousClock.Instant?
    var packetsReceived: UInt64?
    var packetsLost: Int64?
    var jitterMS: Double?
    var roundTripMS: Double?
    var subscriptionFailed = false

    func sameState(as other: Self) -> Bool {
        id == other.id && muted == other.muted && subscribed == other.subscribed && subscriptionFailed == other.subscriptionFailed
            && encryption == other.encryption && quality == other.quality
    }
}

enum CallMemberAudioStatus: Equatable {
    case noTransport, noTrack, muted, notSubscribed, subscriptionProblem, networkProblem, waiting, verified, decryptionProblem
    var title: LocalizedMessage {
        switch self {
        case .noTransport: "语音连接尚未建立"
        case .noTrack: "尚未发布音轨"
        case .muted: "对方已静音"
        case .notSubscribed: "音轨尚未订阅"
        case .subscriptionProblem: "音轨订阅失败"
        case .networkProblem: "网络连接丢失"
        case .waiting: "等待有效的加密音频"
        case .verified: "已验证音频解密"
        case .decryptionProblem: "音频解密暂时异常"
        }
    }
}

/// Explicit allowlist: never encode SDK statistics, identities, device names or URLs.
struct CallDiagnosticSample: Encodable, Sendable {
    struct Track: Encodable, Sendable {
        let number: Int
        let muted: Bool
        let subscribed: Bool
        let subscriptionFailed: Bool
        let encryption: CallTrackEncryption
        let quality: CallNetworkQuality
        let lastDecryptionEventAgeMS: Int?
        let packetsReceived: UInt64?
        let packetsLost: Int64?
        let jitterMS: Double?
        let roundTripMS: Double?
    }
    let schema = 1
    let phase: CallPhase
    let microphoneMuted: Bool
    let listening: Bool
    let audioInterrupted: Bool
    let route: CallAudioRoute
    let preset: AudioPreset
    let mediaLeaseValid: Bool
    let mediaLeaseRemainingMS: Int?
    let tracks: [Track]

    static func boundedMetric(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return min(value, 600_000)
    }
}
