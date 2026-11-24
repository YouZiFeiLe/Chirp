import Foundation

enum CallPhase: String, Codable, Sendable {
    case idle, authorizing, connecting, securing, verifying, active, recovering, leaving
}

struct CallMember: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let microphoneEnabled: Bool?
    let speaking: Bool
    let listening: Bool?
    var identityVerified = false

    var isSpeaking: Bool { speaking && microphoneEnabled == true }
}

/// Closed fields only: no credentials, identities, server addresses or user content.
struct CallDiagnostic: Codable, Sendable {
    enum Event: String, Codable, Sendable {
        case authorizationStarted, authorizationCancelled, authorizationRejected, admissionAccepted
        case mediaConnected, keysInstalled, activated, recoveryStarted, microphoneChanged
        case sessionValidated, mediaConnectStarted, groupStarted, verificationPending, mediaLeaseGranted
        case microphoneRequested, microphonePermissionGranted, firstRemoteDecryption
        case audioPresetChanged, leaving, cleanedUp, staleEventIgnored, failed
        case audioRouteChanged, audioInterrupted, audioResumed, audioResumeDeclined, audioServicesReset
        case listeningChanged, memberVolumeChanged, microphoneTestStarted, microphoneTestStopped, decryptionRecovery
    }
    struct Audio: Codable, Sendable {
        let microphoneMuted: Bool
        let listening: Bool
        let preset: AudioPreset
        let route: CallAudioRoute
    }
    let audio: Audio?
    let sequence: UInt64
    let elapsedMilliseconds: Int64
    let event: Event
    let phase: CallPhase
    let transportGeneration: UInt64
    let keyRevision: UInt64
    let failure: ClientErrorCode?
}

struct CallDiagnostics {
    private var generation: UInt64 = 0
    private var started = ContinuousClock.now
    private var sequence: UInt64 = 0

    mutating func record(_ event: CallDiagnostic.Event, phase: CallPhase, transport: UInt64 = 0, keys: UInt64 = 0,
                         failure: ClientErrorCode? = nil, audio: CallDiagnostic.Audio? = nil, into log: ClientLog) {
        let epoch = log.recordingGeneration
        guard epoch != 0 else { return }
        if epoch != generation { generation = epoch; started = .now; sequence = 0 }
        sequence &+= 1
        let duration = started.duration(to: .now).components
        let elapsed = duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
        let diagnostic = CallDiagnostic(audio: audio, sequence: sequence, elapsedMilliseconds: elapsed,
            event: event, phase: phase, transportGeneration: transport, keyRevision: keys, failure: failure)
        log.record(.call, "lifecycle", details: .lifecycle(diagnostic), generation: epoch)
    }
}

/// Revoked synchronously before any async teardown; also checked by SDK send queues.
final class CallMediaGate: @unchecked Sendable {
    private let lock = NSLock()
    private var valid = true
    var isValid: Bool { lock.withLock { valid } }
    func revoke() { lock.withLock { valid = false } }
}
