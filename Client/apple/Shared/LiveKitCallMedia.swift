import AVFoundation
import Foundation
import LiveKit
import ChirpMLS

/// One adapter owns one Room, its audio lifetime and all native key providers.
@MainActor
final class LiveKitCallMedia: NSObject, CallMedia, RoomDelegate {
    private nonisolated static let listeningAttribute = "chirp.listening"
    private let room: Room
    private let event: @MainActor (CallMediaEvent) -> Void
    private var preset: AudioPreset
    private var closed = false
    private var mediaReady = false
    private var keyLifetime: UInt64 = 0
    var supportsSmoothRotation: Bool { true }
    private var identities = Set<String>()
    private var gate = CallMediaGate()
    private let contentGate = MediaContentGate()
    private var pendingProvider: BaseKeyProvider?
    private var stagedDeadline: ContinuousClock.Instant?
    private var microphoneRequested = false
    private var monitor: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var playback: RoomAudioPlayback?
    private var outputDeviceID: String?
    private var captureProcessor: CaptureAudioProcessor?
    private var voiceActivation = VoiceActivationControl()
    private var changingAudio = false
    private var audioSuspended = false
    private var listening = true
    private var needsListeningUpdate = true
    private var listeningUpdate: Task<Void, Never>?
    private var volumes: [String: Double] = [:]
    private var mixing: Task<Void, Never>?
    private var encryption: [String: (state: CallTrackEncryption, lastSuccess: ContinuousClock.Instant?)] = [:]
    private var failedSubscriptions = Set<String>()

    var isConnected: Bool { !closed && room.connectionState == .connected }
    var hasMicrophone: Bool {
        room.localParticipant.trackPublications.values.contains { $0.source == .microphone }
    }

    func setVoiceActivation(_ control: VoiceActivationControl) { voiceActivation = control }

    init(preset: AudioPreset, event: @escaping @MainActor (CallMediaEvent) -> Void) {
        self.preset = preset; self.event = event
        room = Room(roomOptions: RoomOptions(defaultAudioCaptureOptions: preset.captureOptions,
            encryptionOptions: EncryptionOptions(keyProvider: Self.emptyKeyProvider(contentGate)), reportRemoteTrackStatistics: true))
        super.init()
        room.add(delegate: self)
    }

    func connect(url: URL, token: String) async throws {
        try check()
        configureCaptureProcessing(preset)
        if !audioSuspended { try startPlaybackIfNeeded() }
        do {
            try await room.connect(url: url.absoluteString, token: token,
                connectOptions: ConnectOptions(autoSubscribe: false, enableMicrophone: false))
            try check()
            startMonitor()
        } catch {
            await room.disconnect()
            CaptureAudioProcessor.remove(captureProcessor); captureProcessor = nil
            self.playback?.stop(); self.playback = nil
            throw error
        }
    }

    func authorizeMedia(until deadline: ContinuousClock.Instant?, voiceKeyIndex: Int32?) {
        if deadline == nil { contentGate.revoke(); return }
        guard contentGate.authorize(until: deadline) else {
            gate.revoke(); event(.failed(ClientFailure(.invalidMediaLease))); return
        }
        if let voiceKeyIndex {
            (pendingProvider ?? room.e2eeManager?.keyProvider)?.chirpAuthorizeVoiceKeyIndex(voiceKeyIndex)
        }
    }

    func invalidate() {
        collectVoiceTiming()
        keyLifetime &+= 1
        contentGate.revoke()
        pendingProvider = nil
        closed = true; mediaReady = false; identities = []
        captureProcessor?.resetGate()
        gate.revoke(); monitor?.cancel(); monitor = nil
        listeningUpdate?.cancel()
        mixing?.cancel(); encryption = [:]; failedSubscriptions = []
    }

    func suspendSending() { mediaReady = false; gate.revoke(); contentGate.revoke() }

    func stop() async {
        if let stopping { await stopping.value; return }
        invalidate()
        let task = Task { @MainActor [self] in
            if let manager = room.e2eeManager { await manager.chirpReplaceKeyProvider(Self.emptyKeyProvider(contentGate)) }
            await mixing?.value
            _ = try? await room.localParticipant.setMicrophone(enabled: false)
            await room.disconnect()
            CaptureAudioProcessor.remove(captureProcessor); captureProcessor = nil
            playback?.stop(); playback = nil
            room.remove(delegate: self)
        }
        stopping = task
        await task.value
    }

    func pause() async throws {
        try check()
        keyLifetime &+= 1
        mediaReady = false; gate.revoke(); contentGate.revoke()
        pendingProvider = nil; stagedDeadline = nil
        captureProcessor?.resetGate()
        // Retire cryptographic sending before any device/signaling operation
        // that can fail or wait. Muting alone cannot be the security boundary.
        guard let manager = room.e2eeManager else {
            // Cleanup can pause an adapter before it has connected. There are
            // no transport keys to retire until LiveKit creates a connection.
            guard room.connectionState == .disconnected, !hasMicrophone else { throw ClientFailure(.secureConnectionNotReady) }
            return
        }
        collectVoiceTiming()
        await manager.chirpReplaceKeyProvider(Self.emptyKeyProvider(contentGate))
        try check()
        _ = try await room.localParticipant.setMicrophone(enabled: false)
    }

    func installKeys(_ native: MLSClient, members: [MLSPeer]) async throws {
        try check()
        keyLifetime &+= 1
        let lifetime = keyLifetime
        contentGate.revoke()
        pendingProvider = nil
        encryption = [:]
        let started = ContinuousClock.now
        let hardDeadline = started.advanced(by: .milliseconds(try await native.keyLifetimeMilliseconds()))
        let provider = Self.emptyKeyProvider(contentGate)
        defer { if pendingProvider !== provider { provider.chirpRetireKeys() } }
        for member in members {
            var key = try await native.senderKey(for: member.identity)
            defer { key.resetBytes(in: 0..<key.count) }
            try check()
            guard keyLifetime == lifetime else { throw CancellationError() }
            provider.setKey(keyData: key, participantId: member.identity, index: 0)
        }
        guard room.e2eeManager != nil, hardDeadline > .now else { throw ClientFailure(.secureConnectionNotReady) }
        // The SDK retains existing subscriptions through rekey. Keep the new
        // provider off their receivers until the first verified lease arrives.
        pendingProvider = provider
        gate.revoke(); gate = CallMediaGate()
        identities = Set(members.map(\.identity))
        contentGate.install(keyDeadline: hardDeadline) { provider.chirpRetireKeys() }
    }

    func activate(authorized: @escaping @MainActor () -> Bool) async throws {
        try check()
        let lifetime = keyLifetime
        guard authorized(), contentGate.permitsReceiving(), isConnected, !audioSuspended,
              let manager = room.e2eeManager else { throw CancellationError() }
        if let provider = pendingProvider {
            collectVoiceTiming()
            await manager.chirpReplaceKeyProvider(provider)
            guard !closed, !Task.isCancelled, lifetime == keyLifetime, pendingProvider === provider, authorized(),
                  contentGate.permitsReceiving() else { provider.chirpRetireKeys(); throw CancellationError() }
            pendingProvider = nil
        }
        mediaReady = true
        for participant in room.remoteParticipants.values {
            for publication in participant.trackPublications.values {
                if let publication = publication as? RemoteTrackPublication { try await subscribe(publication, from: participant) }
            }
        }
        try check()
        guard authorized() else { throw CancellationError() }
        for publication in room.localParticipant.trackPublications.values where publication.kind == .audio {
            guard publication.encryptionType == .gcm else { throw ClientFailure(.localTrackUnencrypted) }
        }
        publishParticipants()
    }

    func prepareKeys(_ native: MLSClient, members: [MLSPeer], index: Int32) async throws {
        try check()
        guard mediaReady, let manager = room.e2eeManager, Set(members.map(\.identity)) == identities else { throw CancellationError() }
        let lifetime = keyLifetime, provider = manager.keyProvider
        let started = ContinuousClock.now
        let deadline = started.advanced(by: .milliseconds(try await native.keyLifetimeMilliseconds(staged: true)))
        var keys: [String: Data] = [:]
        defer { for identity in Array(keys.keys) { keys[identity]?.resetBytes(in: 0..<32) } }
        for member in members { keys[member.identity] = try await native.senderKey(for: member.identity, staged: true) }
        try check()
        guard mediaReady, keyLifetime == lifetime, manager.chirpStageKeys(keys, index: index, using: provider) else { throw CancellationError() }
        stagedDeadline = deadline
    }

    func switchKeys(index: Int32) async throws {
        try check()
        guard mediaReady, let manager = room.e2eeManager else { throw CancellationError() }
        let lifetime = keyLifetime, provider = manager.keyProvider
        let previousIndex = provider.getCurrentKeyIndex()
        let receiveDeadline = min(contentGate.leaseDeadline ?? .now, ContinuousClock.now.advanced(by: .seconds(1)))
        // Close queued data authorization before the RTC executor changes the
        // shared provider's sending index. Capture/playout do not use this gate.
        gate.revoke()
        guard await manager.chirpActivateKeyIndex(index, using: provider) else { throw CancellationError() }
        try check()
        guard mediaReady, keyLifetime == lifetime else { throw CancellationError() }
        // Queued data messages retain the old gate and cannot silently migrate
        // across the cutover. RTP cryptors and microphone state remain intact.
        provider.chirpExpireKeyIndex(previousIndex, at: receiveDeadline)
        gate = CallMediaGate()
        guard let stagedDeadline, stagedDeadline > .now else { throw V5IdentityError.expired }
        contentGate.install(keyDeadline: stagedDeadline) { provider.chirpRetireKeys() }
        contentGate.microphone(microphoneRequested)
        self.stagedDeadline = nil
    }

    func retireKeys(index: Int32) throws {
        try check()
        guard mediaReady, let manager = room.e2eeManager,
              manager.chirpRetireKeyIndex(index, using: manager.keyProvider) else { throw CancellationError() }
    }

    func setMicrophone(enabled: Bool, authorized: @escaping @MainActor () -> Bool) async throws {
        try check()
        if !enabled {
            microphoneRequested = false
            contentGate.microphone(false)
            captureProcessor?.resetGate()
            _ = try await room.localParticipant.setMicrophone(enabled: false)
            publishParticipants()
            return
        }
        guard mediaReady, !audioSuspended, authorized() else { throw ClientFailure(.secureConnectionNotReady) }
        microphoneRequested = true
        contentGate.microphone(true)
        changingAudio = true
        defer { changingAudio = false }
        configureCaptureProcessing(preset)
        captureProcessor?.resetGate()
        let publication: LocalTrackPublication
        if let existing = room.localParticipant.trackPublications.values.first(where: { $0.source == .microphone }) as? LocalTrackPublication {
            publication = existing
        } else {
            let track = await LocalAudioTrack.createTrack(options: preset.captureOptions)
            try check()
            guard authorized() else { throw CancellationError() }
            try await track.mute()
            publication = try await room.localParticipant.publish(audioTrack: track)
        }
        do {
            try check()
            guard publication.encryptionType == .gcm, let manager = room.e2eeManager,
                  let identity = room.localParticipant.identity,
                  await manager.chirpPrepareLocalTrack(publication, identity: identity),
                  let track = publication.track as? LocalAudioTrack else {
                throw ClientFailure(.microphoneEncryptorNotReady)
            }
            try await AudioPresetRuntime.apply(preset, to: track)
            try check()
            guard mediaReady, authorized() else { throw CancellationError() }
            try await publication.unmute()
            try check()
            guard mediaReady, authorized() else { throw CancellationError() }
            try await AudioPresetRuntime.waitUntilApplied(preset)
            try check()
            guard mediaReady, authorized() else { throw CancellationError() }
            emit(.audioStatus("已生效：\(preset.title)"))
            publishParticipants()
        } catch {
            try? await publication.mute()
            throw error
        }
    }

    func applyAudioPreset(_ next: AudioPreset, microphoneEnabled: Bool) async throws {
        try check()
        changingAudio = true
        defer { changingAudio = false }
        if let track = room.localParticipant.trackPublications.values
            .first(where: { $0.source == .microphone })?.track as? LocalAudioTrack {
            try await AudioPresetRuntime.apply(next, to: track)
            try check()
            configureCaptureProcessing(next)
            captureProcessor?.resetGate()
            if microphoneEnabled { try await AudioPresetRuntime.waitUntilApplied(next) }
        } else {
            configureCaptureProcessing(next)
        }
        try check()
        preset = next
    }

    private func configureCaptureProcessing(_ preset: AudioPreset) {
        captureProcessor = CaptureAudioProcessor.configure(for: preset, voiceActivation: voiceActivation, reusing: captureProcessor, authorization: contentGate) { [weak self] failure in
            self?.emit(.failed(failure))
        }
    }

    func encryptedSender(deadline: ContinuousClock.Instant, loginExpiresAt: Date) throws -> any CallEncryptedSender {
        try check()
        guard mediaReady, isConnected, let manager = room.e2eeManager,
              manager.dataChannelEncryptionType == .gcm, gate.isValid else { throw ClientFailure(.chatNotReady) }
        return LiveKitEncryptedSender(room: room, provider: manager.keyProvider, gate: gate,
            deadline: deadline, loginExpiresAt: loginExpiresAt)
    }

    func setAudioSuspended(_ suspended: Bool) async throws {
        try check()
        if suspended {
            audioSuspended = true; playback?.suspend()
            suspendSending()
            if isConnected { try await pause() }
        } else {
            #if os(iOS)
            try AVAudioSession.sharedInstance().setActive(true)
            #endif
            try startPlaybackIfNeeded()
            try playback?.resume()
            audioSuspended = false
        }
    }

    private func startPlaybackIfNeeded() throws {
        guard playback == nil else { return }
        let playback = RoomAudioPlayback()
        try playback.setOutputDeviceID(outputDeviceID)
        try playback.start {
            let requirement = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)
            return { try? requirement.release() }
        }
        self.playback = playback
    }

    func setOutputDeviceID(_ id: String?) throws {
        guard !closed else { return }
        outputDeviceID = id
        try playback?.setOutputDeviceID(id)
    }

    func setPlayback(listening: Bool, volumes: [String: Double]) {
        guard !closed else { return }
        if self.listening != listening {
            self.listening = listening
            needsListeningUpdate = true
            publishListeningIfNeeded()
        }
        self.volumes = volumes
        applyPlayback()
    }

    private func publishListeningIfNeeded() {
        guard needsListeningUpdate, listeningUpdate == nil, isConnected,
              room.localParticipant.permissions.canUpdateMetadata else { return }
        listeningUpdate = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { listeningUpdate = nil }
            // A toggle or reconnect during a send queues the latest value behind it.
            while needsListeningUpdate, isConnected, !Task.isCancelled {
                needsListeningUpdate = false
                do {
                    try await room.localParticipant.set(attributes: [Self.listeningAttribute: String(listening)])
                } catch {
                    needsListeningUpdate = true
                    return  // The room monitor retries while connected.
                }
            }
        }
    }

    private func applyPlayback() {
        guard !closed else { return }
        mixing?.cancel()
        let tracks = room.remoteParticipants.values.flatMap { participant -> [(RemoteAudioTrack, Double)] in
            guard let identity = participant.identity?.stringValue else { return [] }
            let volume = listening ? volumes[identity] ?? 1 : 0
            return participant.trackPublications.values.compactMap { publication in
                guard let track = publication.track as? RemoteAudioTrack else { return nil }
                return (track, volume)
            }
        }
        mixing = Task { @MainActor in
            guard !Task.isCancelled else { return }
            try? await CallAudioQueue.perform { for (track, volume) in tracks { track.volume = volume } }
        }
    }

    private func publishTrackDiagnostics() {
        guard !closed else { return }
        var tracks: [CallTrackDiagnostic] = []
        for participant in room.remoteParticipants.values {
            guard let identity = participant.identity?.stringValue, identities.contains(identity) else { continue }
            let quality: CallNetworkQuality
            switch participant.connectionQuality {
            case .excellent: quality = .excellent
            case .good: quality = .good
            case .poor: quality = .poor
            case .lost: quality = .lost
            default: quality = .unknown
            }
            for publication in participant.trackPublications.values where publication.source == .microphone && publication.kind == .audio {
                let id = publication.sid.stringValue, state = encryption[id]
                let stats = publication.track?.statistics, inbound = stats?.inboundRtpStream.first
                let pair = stats?.iceCandidatePair.first { $0.id == stats?.transportStats?.selectedCandidatePairId }
                tracks.append(CallTrackDiagnostic(id: id, identity: identity, muted: publication.isMuted,
                    subscribed: publication.isSubscribed, encryption: state?.state ?? .waiting, quality: quality,
                    lastDecryption: state?.lastSuccess, packetsReceived: inbound?.packetsReceived,
                    packetsLost: inbound?.packetsLost, jitterMS: inbound?.jitter.map { $0 * 1_000 },
                    roundTripMS: pair?.currentRoundTripTime.map { $0 * 1_000 }, subscriptionFailed: failedSubscriptions.contains(id)))
            }
        }
        let ids = Set(tracks.map(\.id)); encryption = encryption.filter { ids.contains($0.key) }
        failedSubscriptions.formIntersection(ids)
        emit(.trackDiagnostics(tracks))
    }

    private func check() throws {
        try Task.checkCancellation()
        guard !closed else { throw CancellationError() }
    }

    private func emit(_ value: CallMediaEvent) { if !closed { event(value) } }

    private static func emptyKeyProvider(_ gate: MediaContentGate) -> BaseKeyProvider {
        let provider = BaseKeyProvider(chirpAudioAuthorization: { [weak gate] in gate?.permitsReceiving() == true })
        _ = provider.chirpTakeVoiceDecryptionTiming(generation: ClientLog.shared.recordingGeneration)
        return provider
    }

    private func subscribe(_ publication: RemoteTrackPublication, from participant: RemoteParticipant) async throws {
        guard !closed, mediaReady, publication.kind == .audio, publication.source == .microphone,
              let identity = participant.identity, identities.contains(identity.stringValue),
              room.remoteParticipants[identity] === participant, participant.trackPublications[publication.sid] === publication else { return }
        guard publication.encryptionType == .gcm else { throw ClientFailure(.remoteTrackUnencrypted) }
        try await publication.set(subscribed: true)
    }

    private func publishParticipants() {
        guard isConnected else { return }
        let participants: [Participant] = [room.localParticipant] + Array(room.remoteParticipants.values)
        emit(.participants(participants.compactMap { participant in
            guard let identity = participant.identity?.stringValue else { return nil }
            return CallMediaParticipant(identity: identity, microphoneEnabled: participant.isMicrophoneEnabled(),
                speaking: participant.isSpeaking, listening: participant.attributes[Self.listeningAttribute].flatMap(Bool.init))
        }))
    }

    private func collectVoiceTiming() {
        let generation = ClientLog.shared.recordingGeneration
        if let sample = room.e2eeManager?.keyProvider.chirpTakeVoiceDecryptionTiming(generation: generation) {
            ClientLog.shared.record(.crypto, "voiceDecrypt", details: .decryption(frames: sample.frames,
                totalNS: sample.totalNS, maxNS: sample.maxNS), generation: generation)
        }
    }

    private func startMonitor() {
        monitor?.cancel()
        monitor = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !closed else { return }
                do { try playback?.ensurePlaying() }
                catch { emit(.failed(ClientFailure(.voiceDisconnected))); return }
                publishListeningIfNeeded()
                collectVoiceTiming()
                publishTrackDiagnostics()
                if !changingAudio, isConnected, mediaReady, room.localParticipant.isMicrophoneEnabled() {
                    let selected = preset
                    let observation = await AudioPresetRuntime.observation()
                    if !closed, !changingAudio, selected == preset,
                       room.localParticipant.isMicrophoneEnabled() {
                        emit(.audioStatus(observation.matches(selected) ? "已生效：\(selected.title)" : "尚未确认预设生效；可离开房间后重新加入"))
                    }
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor [weak self] in
            guard let self, self.room === room, !closed else { return }
            if connectionState == .connected {
                needsListeningUpdate = true
                publishListeningIfNeeded()
                emit(.connected); publishParticipants()
            }
        }
    }
    nonisolated func room(_ room: Room, didDisconnectWithError error: LiveKitError?) {
        Task { @MainActor [weak self] in self?.emit(.disconnected) }
    }
    nonisolated func room(_ room: Room, didStartReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            mediaReady = false; gate.revoke(); contentGate.revoke(); emit(.reconnecting)
        }
    }
    nonisolated func room(_ room: Room, didCompleteReconnectWithMode reconnectMode: ReconnectMode) {
        Task { @MainActor [weak self] in self?.emit(.reconnected); self?.publishParticipants() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didPublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            do { try await subscribe(publication, from: participant); publishParticipants() }
            catch { emit(.failed(ClientFailure.capture(error, fallback: .voiceConnectionFailed))) }
        }
    }
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.publishParticipants() }
    }
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        Task { @MainActor [weak self] in self?.publishParticipants(); self?.publishTrackDiagnostics() }
    }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateAttributes attributes: [String: String]) {
        guard attributes[Self.listeningAttribute] != nil else { return }
        Task { @MainActor [weak self] in self?.publishParticipants() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnpublishTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.publishParticipants(); self?.publishTrackDiagnostics() }
    }
    nonisolated func room(_ room: Room, didUpdateSpeakingParticipants participants: [Participant]) {
        Task { @MainActor [weak self] in self?.publishParticipants() }
    }
    nonisolated func room(_ room: Room, participant: Participant, trackPublication: TrackPublication, didUpdateIsMuted isMuted: Bool) {
        Task { @MainActor [weak self] in self?.publishParticipants(); self?.publishTrackDiagnostics() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in
            self?.failedSubscriptions.remove(publication.sid.stringValue)
            self?.applyPlayback(); self?.publishTrackDiagnostics()
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didFailToSubscribeTrackWithSid trackSid: Track.Sid, error: LiveKitError) {
        Task { @MainActor [weak self] in
            self?.failedSubscriptions.insert(trackSid.stringValue)
            self?.publishTrackDiagnostics()
        }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didUnsubscribeTrack publication: RemoteTrackPublication) {
        Task { @MainActor [weak self] in self?.publishTrackDiagnostics() }
    }
    nonisolated func room(_ room: Room, participant: Participant, didUpdateConnectionQuality quality: ConnectionQuality) {
        Task { @MainActor [weak self] in self?.publishTrackDiagnostics() }
    }
    nonisolated func room(_ room: Room, participant: RemoteParticipant?, didReceiveData data: Data, forTopic topic: String, encryptionType: EncryptionType) {
        guard topic == RoomChat.topic, data.count <= RoomChat.maxPacketBytes else { return }
        let sender = participant?.identity?.stringValue
        Task { @MainActor [weak self] in self?.emit(.data(data, sender: sender, encrypted: encryptionType == .gcm)) }
    }
    nonisolated func room(_ room: Room, trackPublication: TrackPublication, didUpdateE2EEState state: E2EEState) {
        Task { @MainActor [weak self] in
            guard let self, !closed else { return }
            let id = trackPublication.sid.stringValue
            var stateValue = encryption[id] ?? (.waiting, nil)
            switch state {
            case .ok: stateValue = (.verified, .now)
            case .new, .key_ratcheted: stateValue.state = .waiting
            case .missing_key: stateValue.state = .missingKey
            case .decryption_failed: stateValue.state = .decryptionFailed
            case .encryption_failed, .internal_error: emit(.failed(ClientFailure(.audioEncryptionFailed)))
            @unknown default: emit(.failed(ClientFailure(.audioEncryptionUnknown)))
            }
            if trackPublication is RemoteTrackPublication { encryption[id] = stateValue; publishTrackDiagnostics() }
        }
    }
}

@MainActor
private struct LiveKitEncryptedSender: CallEncryptedSender {
    let room: Room
    let provider: BaseKeyProvider
    let gate: CallMediaGate
    let deadline: ContinuousClock.Instant
    let loginExpiresAt: Date

    func send(_ data: Data, destinations: [String]) async throws {
        let gate = gate, deadline = deadline, expiry = loginExpiresAt
        try await room.localParticipant.chirpPublishEncrypted(data: data, topic: RoomChat.topic,
            destinations: destinations.map { Participant.Identity(from: $0) }, keyProvider: provider,
            authorization: { gate.isValid && deadline > .now && expiry > Date() })
    }
}

extension CallDependencies {
    static var liveKit: CallDependencies {
        liveKit(identity: DeviceIdentityStore(persistence: KeychainIdentityPersistence()))
    }

    static func liveKit(identity: DeviceIdentityStore) -> CallDependencies {
        return CallDependencies(identity: identity, validateRoomIdentity: { login, roomID in
            let device = try identity.requireDevice()
            guard login.deviceIdentity == device else { throw V5IdentityError.wrongDevice }
            try V5RoomPolicy.mutual(origin: ServerAddress.identityOrigin(login.connection.passkeyOrigin), roomID: roomID).allows(device)
        }, prepare: {
            guard Room.chirpNoExternalICEServers, Room.chirpLocalMicrophoneIntent else { throw ClientFailure(.secureTransportMissing) }
            try Task.checkCancellation()
        }, makeAPI: { APIClient(baseURL: $0.connection.apiURL, credential: $0.credential) },
        makeMedia: { LiveKitCallMedia(preset: $0, event: $1) },
        makeGroup: { login, admission, callbacks in
            try GroupSession(baseURL: login.connection.endpoints.groupBaseURL, login: login, admission: admission,
                identity: identity,
                onPause: callbacks.pause, onInstall: callbacks.install, onReady: callbacks.ready, onFailure: callbacks.failed,
                onPrepare: callbacks.prepare, onSwitch: callbacks.switchKeys, onRetire: callbacks.retireKeys, onReconnect: callbacks.reconnected,
                approveRoster: callbacks.approveRoster, authorizationDeadline: callbacks.authorizationDeadline, authorizeMedia: callbacks.authorizeMedia,
                onRoomInformation: callbacks.roomInformation)
        }, validateAudioPreset: { try await AudioPresetRuntime.validate($0) }, makeAudio: { LiveKitAudioHardware() },
        requestMicrophoneAccess: { await MicrophoneAuthorization.request() })
    }
}

extension CallController {
    convenience init() { self.init(dependencies: .liveKit) }
}

extension ApplicationSession {
    convenience init() { self.init(dependencies: .liveKit, loginVault: KeychainLoginVault()) }
}
