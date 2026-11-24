import Foundation
import ChirpMLS

protocol CallRoomAPI: Sendable {
    func joinSequence(for login: ClientSession) async throws -> Int64
    func authorizeRoom(roomID: String, sequence: Int64, login: ClientSession, password: String?) async throws -> JoinResponse
    func freshMediaToken(_ admission: RoomAdmission) async throws -> String
    func leave(_ admission: RoomAdmission) async throws
    func close()
}

extension APIClient: CallRoomAPI {}

struct CallMediaParticipant: Sendable {
    let identity: String
    let microphoneEnabled: Bool
    let speaking: Bool
    let listening: Bool?
}

enum CallMediaEvent: Sendable {
    case connected, reconnecting, reconnected, disconnected
    case participants([CallMediaParticipant])
    case data(Data, sender: String?, encrypted: Bool)
    case audioStatus(LocalizedMessage)
    case trackDiagnostics([CallTrackDiagnostic])
    case failed(ClientFailure)
}

@MainActor
protocol CallEncryptedSender {
    func send(_ data: Data, destinations: [String]) async throws
}

@MainActor
protocol CallMedia: AnyObject {
    var supportsSmoothRotation: Bool { get }
    var isConnected: Bool { get }
    var hasMicrophone: Bool { get }
    func setVoiceActivation(_ control: VoiceActivationControl)
    func connect(url: URL, token: String) async throws
    func authorizeMedia(until deadline: ContinuousClock.Instant?, voiceKeyIndex: Int32?)
    func invalidate()
    func suspendSending()
    func stop() async
    func pause() async throws
    func installKeys(_ native: MLSClient, members: [MLSPeer]) async throws
    func prepareKeys(_ native: MLSClient, members: [MLSPeer], index: Int32) async throws
    func switchKeys(index: Int32) async throws
    func retireKeys(index: Int32) throws
    func activate(authorized: @escaping @MainActor () -> Bool) async throws
    func setMicrophone(enabled: Bool, authorized: @escaping @MainActor () -> Bool) async throws
    func applyAudioPreset(_ preset: AudioPreset, microphoneEnabled: Bool) async throws
    func setAudioSuspended(_ suspended: Bool) async throws
    func setOutputDeviceID(_ id: String?) throws
    func setPlayback(listening: Bool, volumes: [String: Double])
    func encryptedSender(deadline: ContinuousClock.Instant, loginExpiresAt: Date) throws -> any CallEncryptedSender
}

extension CallMedia {
    var supportsSmoothRotation: Bool { false }
    func authorizeMedia(until deadline: ContinuousClock.Instant?, voiceKeyIndex: Int32?) {}
    func prepareKeys(_ native: MLSClient, members: [MLSPeer], index: Int32) async throws { throw ClientFailure(.secureTransportMissing) }
    func switchKeys(index: Int32) async throws { throw ClientFailure(.secureTransportMissing) }
    func retireKeys(index: Int32) throws { throw ClientFailure(.secureTransportMissing) }
}

@MainActor
protocol CallGroupCoordinating: AnyObject {
    var maySend: Bool { get }
    var groupID: String? { get }
    var sendingDeadline: ContinuousClock.Instant? { get }
    func prepareConfiguration() async
    func start()
    func cancel()
    func stop() async
    func suspend() async throws
    func refresh() async throws
}

extension GroupSession: CallGroupCoordinating {}

@MainActor
struct CallGroupCallbacks {
    let pause: @MainActor @Sendable () async throws -> Void
    let install: @MainActor @Sendable (MLSClient, [MLSPeer]) async throws -> Void
    let ready: @MainActor @Sendable ([MLSPeer]) async throws -> Void
    let failed: @MainActor @Sendable (ClientFailure) async -> Void
    var prepare: (@MainActor @Sendable (MLSClient, [MLSPeer], Int32) async throws -> Void)? = nil
    var switchKeys: (@MainActor @Sendable (Int32) async throws -> Void)? = nil
    var retireKeys: (@MainActor @Sendable (Int32) async throws -> Void)? = nil
    var authorizeMedia: (@MainActor @Sendable (ContinuousClock.Instant?, Int32?) -> Void)? = nil
    var approveRoster: (@MainActor @Sendable ([MLSPeer]) throws -> String?)? = nil
    var authorizationDeadline: (@MainActor @Sendable () -> ContinuousClock.Instant?)? = nil
    var reconnected: (@MainActor @Sendable () -> Void)? = nil
    var roomInformation: (@MainActor @Sendable (RoomPublicInformation?) -> Void)? = nil
}

@MainActor
struct CallDependencies {
    var identity: DeviceIdentityStore? = nil
    // Dependency for isolated coordinators; the shipping app uses RoomIdentity.
    var authorizeIdentity: @MainActor () -> Bool = { false }
    var validateRoomIdentity: (ClientSession, String) async throws -> Void = { _, _ in }
    var prepare: () async throws -> Void
    var makeAPI: (ClientSession) -> any CallRoomAPI
    var makeMedia: (AudioPreset, @escaping @MainActor (CallMediaEvent) -> Void) throws -> any CallMedia
    var makeGroup: (ClientSession, RoomAdmission, CallGroupCallbacks) throws -> any CallGroupCoordinating
    var validateAudioPreset: (AudioPreset) async throws -> Void
    var makeAudio: () -> (any CallAudioHardware)? = { nil }
    var requestMicrophoneAccess: () async -> Bool = { true }
    var now: () -> ContinuousClock.Instant = { .now }
}
