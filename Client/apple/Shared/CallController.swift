import Combine
import Foundation
import ChirpMLS

@MainActor
private final class ActiveCall {
    let login: ClientSession
    let response: JoinResponse
    var admission: RoomAdmission { response.admission }
    var media: (any CallMedia)?
    var group: (any CallGroupCoordinating)?
    var connectTask: Task<Void, Never>?
    var microphoneTask: Task<Void, Never>?
    var recoveryTask: Task<Void, Never>?
    var presetTask: Task<Void, Error>?
    var transportGeneration: UInt64 = 0
    var installedTransport: UInt64?
    var installedGroupID: String?
    var keyRevision: UInt64 = 0
    var keysReady = false
    var reconnecting = false
    var mediaInstanceID = UUID()
    var roster: [MLSPeer] = []
    var presence = RoomPresenceTracker()
    var participants: [CallMediaParticipant] = []
    var audioInterrupted = false
    var audioGeneration: UInt64 = 0
    var audioResumeID: UUID?
    var audioResumeTask: Task<Void, Never>?
    var decryptionIssues: [String: (since: ContinuousClock.Instant, packets: UInt64)] = [:]
    var decryptionAttempts = 0
    var lastDecryptionRecovery: ContinuousClock.Instant?
    var lastLogSample: ContinuousClock.Instant?
    var lastLogGeneration: UInt64 = 0
    var observedRemoteDecryption = false

    init(login: ClientSession, response: JoinResponse) { self.login = login; self.response = response }
}

/// App-owned coordinator. It has no dependency on LiveKit or a SwiftUI view lifetime.
@MainActor
final class CallController: ObservableObject {
    @Published private(set) var phase: CallPhase = .idle
    @Published private(set) var roomDisplayName = "公开大厅"
    @Published private(set) var preparingRoomID: String?
    @Published private(set) var status: LocalizedMessage = "尚未加入"
    @Published private(set) var encryptionStatus: LocalizedMessage = "尚未建立安全群组"
    @Published private(set) var members: [CallMember] = []
    @Published private(set) var errorMessage: ClientFailure?
    @Published private(set) var isMuted = true
    @Published private(set) var isChangingMicrophone = false
    @Published private(set) var audioPreset: AudioPreset
    @Published private(set) var audioProcessingStatus: LocalizedMessage = "麦克风开启后确认音频预设"
    @Published private(set) var isChangingAudioPreset = false
    @Published private(set) var isListening = true
    @Published private(set) var memberVolumes: [String: Double] = [:]
    @Published private(set) var trackDiagnostics: [CallTrackDiagnostic] = []
    @Published private(set) var roomPublicInformation: RoomPublicInformation?
    @Published private(set) var chat = RoomChat()
    private let log: ClientLog
    private var diagnostics = CallDiagnostics()
    let attachments = RoomAttachmentController()
    let audio: CallAudioController
    let voiceActivation: VoiceActivationController
    private(set) var clientSession: ClientSession?
    private let dependencies: CallDependencies
    private let defaults: UserDefaults
    private var current: ActiveCall?
    var roomIdentity: RoomIdentity? {
        didSet {
            roomIdentity?.onStop = { [weak self] failure in self?.leave(); self?.errorMessage = failure }
            roomIdentity?.onMute = { [weak self] in self?.muteForIdentityTransition() }
            roomIdentity?.onChange = { [weak self] in self?.updateIdentityStatus() }
        }
    }
    private var leaving: Task<Void, Never>?
    private var cleanupID: UUID?
    private var preparation: Task<Void, Error>?
    private var preparationID: UUID?
    private var lastJoinSequence: Int64 = 0
    private var profileNames: [String: String] = [:]
    private var presetChangeID: UUID?
    private var audioPresetTask: Task<Void, Error>?
    private var chatSendTask: Task<Void, Never>?
    private var chatSendID: UUID?

    var currentRoomID: String? { current?.admission.roomID }
    var hasPendingWork: Bool { current != nil || preparationID != nil || cleanupID != nil || presetChangeID != nil || audio.hasPendingWork }
    var hasSession: Bool { current != nil }
    var isBusy: Bool { [.authorizing, .connecting, .securing, .leaving].contains(phase) }
    var isConnected: Bool { phase == .active && current.map { maySend($0) } == true }
    var canSendAttachment: Bool { identityAllowsSending && isConnected && chat.isReady }
    var canSendChat: Bool { identityAllowsSending && isConnected && chat.canSend }
    var canChangeAudioPreset: Bool {
        !isBusy && preparingRoomID == nil && !isChangingMicrophone && !isChangingAudioPreset && !audio.hasPendingWork && (current == nil || isConnected)
    }

    init(dependencies: CallDependencies, defaults: UserDefaults = .standard, log: ClientLog = .shared) {
        self.log = log
        self.dependencies = dependencies
        self.defaults = defaults
        audioPreset = AudioPreset.load(from: defaults)
        let voiceActivation = VoiceActivationController(defaults: defaults)
        self.voiceActivation = voiceActivation
        let hardware = dependencies.makeAudio()
        hardware?.setVoiceActivation(voiceActivation.control)
        audio = CallAudioController(hardware: hardware)
        audioProcessingStatus = "已选：\(audioPreset.title)；麦克风开启后确认"
        audio.onSystemEvent = { [weak self] in self?.handleAudioEvent($0) }
        audio.onDiagnostic = { [weak self] in self?.record($0) }
    }

    func resetLocalSettings() async {
        guard current == nil else { return }
        audioPreset = .defaultPreset; voiceActivation.resetLocalSettings(); await audio.resetLocalSettings()
        isMuted = true; isListening = true; memberVolumes = [:]; profileNames = [:]; errorMessage = nil; diagnostics = CallDiagnostics()
    }
    func setClientSession(_ login: ClientSession?) {
        guard clientSession?.credential != login?.credential else { return }
        // Cleanup captures the OLD server and credential before replacing the login.
        leave()
        clientSession = login
        lastJoinSequence = 0
        roomDisplayName = "公开大厅"
    }

    private func owns(_ call: ActiveCall) -> Bool { current === call }
    private func maySend(_ call: ActiveCall, allowRebuilding: Bool = false) -> Bool {
        owns(call) && (identityAllowsSending || (allowRebuilding && roomIdentity?.social.voiceAllowed == true && roomIdentity?.trust == .rebuilding)) && !call.reconnecting && !call.audioInterrupted && call.keysReady && call.media?.isConnected == true
            && call.group?.maySend == true && call.login.expiresAt > Date()
            && call.installedTransport == call.transportGeneration && call.installedGroupID == call.group?.groupID
    }
    private func require(_ call: ActiveCall) throws {
        try Task.checkCancellation()
        guard owns(call) else { throw CancellationError() }
    }
    private func record(_ event: CallDiagnostic.Event, call: ActiveCall? = nil, failure: ClientFailure? = nil) {
        let call = call ?? current
        diagnostics.record(event, phase: phase, transport: call?.transportGeneration ?? 0, keys: call?.keyRevision ?? 0,
            failure: failure.map { ClientErrorCode(rawValue: $0.code) ?? .unknownServerError },
            audio: .init(microphoneMuted: isMuted, listening: isListening, preset: audioPreset, route: audio.devices.route), into: log)
    }
    private func transition(_ next: CallPhase, message: LocalizedMessage) {
        phase = next; status = message
        updateAttachmentPolicy()
    }

    // Preflight rejection leaves the old call intact. The owned task also cleans
    // a committed admission if its caller disappears or cancellation arrives late.
    func startJoin(room target: RoomOverview, password: String? = nil) async throws {
        log.record(.room, "join", outcome: .started)
        guard roomIdentity.map({ $0.social.voiceAllowed }) ?? dependencies.authorizeIdentity() else { throw ClientFailure(.authorizationStale) }
        guard !isBusy, preparationID == nil, !isChangingAudioPreset, !isChangingMicrophone else { throw ClientFailure(.callBusy) }
        if currentRoomID == target.roomID { return }
        guard let login = clientSession, login.expiresAt > Date() else { throw APIError.unauthorized }
        let id = UUID()
        preparationID = id; preparingRoomID = target.roomID
        if current == nil { transition(.authorizing, message: "正在加入房间") }
        record(.authorizationStarted)
        let task = Task { @MainActor [self] in
            try await audio.prepareForCall()
            try Task.checkCancellation()
            try await dependencies.prepare()
            try Task.checkCancellation()
            let api = dependencies.makeAPI(login)
            defer { api.close() }
            try await dependencies.validateRoomIdentity(login, target.roomID)
            let serverSequence = try await api.joinSequence(for: login)
            try Task.checkCancellation()
            guard preparationID == id, clientSession?.credential == login.credential else { throw CancellationError() }
            record(.sessionValidated)
            guard serverSequence < Int64.max, lastJoinSequence < Int64.max else { throw ClientFailure(.joinSequenceExhausted) }
            lastJoinSequence = max(serverSequence, lastJoinSequence) + 1
            let sequence = lastJoinSequence
            let response = try await api.authorizeRoom(roomID: target.roomID, sequence: sequence, login: login, password: password)
            do {
                try response.validate(roomID: target.roomID, sequence: sequence, login: login)
                _ = try ServerAddress.validate(response.livekitURL, websocket: true)
                try Task.checkCancellation()
                guard preparationID == id, clientSession?.credential == login.credential else { throw CancellationError() }
            } catch {
                if response.matchesAdmission(roomID: target.roomID, sequence: sequence, login: login) {
                    await release(response.admission, login: login)
                }
                throw error
            }
            if current != nil { detachCurrentCall() }
            let cleanup = leaving
            let call = ActiveCall(login: login, response: response)
            current = call; isMuted = true; errorMessage = nil
            roomIdentity?.begin(login: login, admission: response.admission)
            memberVolumes = [:]; trackDiagnostics = []
            roomDisplayName = response.displayName
            transition(.connecting, message: cleanup == nil ? "正在加入房间" : "正在离开旧房间")
            record(.admissionAccepted)
            call.connectTask = Task { @MainActor [self] in
                await cleanup?.value
                guard !Task.isCancelled, owns(call) else { return }
                await connect(call)
            }
        }
        preparation = task
        defer {
            if preparationID == id {
                preparationID = nil; preparingRoomID = nil; preparation = nil
                if current == nil && cleanupID == nil { transition(.idle, message: "尚未加入") }
            }
        }
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        } catch {
            record(error is CancellationError ? .authorizationCancelled : .authorizationRejected)
            guard !Task.isCancelled, preparationID == id, clientSession?.credential == login.credential else { throw CancellationError() }
            throw error
        }
    }

    private func makeMedia(_ call: ActiveCall) throws -> any CallMedia {
        let mediaID = UUID(); call.mediaInstanceID = mediaID
        let media = try dependencies.makeMedia(audioPreset) { [weak self, weak call] event in
            guard let self, let call, call.mediaInstanceID == mediaID else { return }
            self.receive(event, from: call)
        }
        media.setVoiceActivation(voiceActivation.control)
        try media.setOutputDeviceID(audio.devices.outputID == "system" ? nil : audio.devices.outputID)
        media.setPlayback(listening: isListening, volumes: memberVolumes)
        return media
    }
    private func connect(_ call: ActiveCall) async {
        do {
            try require(call)
            try await dependencies.validateAudioPreset(audioPreset)
            try require(call)
            let media = try makeMedia(call)
            call.media = media
            if call.audioInterrupted { try await media.setAudioSuspended(true); try require(call) }
            chat.begin(call.admission)
            let entryID = call.admission.entryID
            attachments.begin(login: call.login, admission: call.admission, authorize: { [weak self, weak call] in
                guard let self, let call else { throw CancellationError() }
                try await self.waitForAttachmentAuthorization(call)
            }, audience: { [weak self, weak call] in
                guard let self, let call, self.maySend(call), let groupID = self.chat.groupID else { throw ClientFailure(.chatNotReady) }
                return AttachmentAudience(groupID: groupID, identities: call.roster.map(\.identity))
            }, announce: { [weak self, weak call] descriptor, groupID in
                guard let self, let call, self.owns(call), self.chat.admission?.entryID == entryID else { throw CancellationError() }
                try await self.sendAttachmentDescriptor(descriptor, expectedGroupID: groupID, call: call)
            })
            var callbacks = CallGroupCallbacks(pause: { [weak self, weak call] in
                guard let self, let call else { throw CancellationError() }
                try await self.pause(call)
            }, install: { [weak self, weak call] native, members in
                guard let self, let call else { throw CancellationError() }
                try await self.install(native, members: members, call: call)
            }, ready: { [weak self, weak call] _ in
                guard let self, let call else { throw CancellationError() }
                try await self.activate(call)
            }, failed: { [weak self, weak call] failure in
                guard let self, let call else { return }
                self.fail(failure, call: call)
            })
            callbacks.authorizeMedia = { [weak self, weak call] deadline, voiceKeyIndex in
                guard let self, let call, self.owns(call) else { return }
                call.media?.authorizeMedia(until: deadline, voiceKeyIndex: voiceKeyIndex)
            }
            callbacks.roomInformation = { [weak self, weak call] information in
                guard let self, let call, self.owns(call) else { return }
                if let information {
                    if let previous = self.roomPublicInformation, previous.groupID == information.groupID,
                       previous.requestStartedAt > information.requestStartedAt { return }
                    self.roomPublicInformation = information
                } else {
                    self.roomPublicInformation?.unavailable = true
                }
            }
            callbacks.approveRoster = { [weak self, weak call] peers in
                guard let self, let call, self.owns(call), let identity = self.roomIdentity else { return nil }
                call.roster = peers
                let approval = try identity.approveRoster(peers)
                self.updateMembers(call)
                return approval
            }
            callbacks.authorizationDeadline = { [weak self] in self?.roomIdentity?.social.sendingDeadline }
            callbacks.reconnected = { [weak self, weak call] in
                guard let self, let call, self.owns(call), let roomIdentity = self.roomIdentity else { return }
                try? roomIdentity.updateRoster(call.roster, reconnected: true)
                Task { await roomIdentity.social.refresh() }
            }
            if media.supportsSmoothRotation {
                callbacks.prepare = { [weak self, weak call] native, members, index in
                    guard let self, let call else { throw CancellationError() }
                    try self.require(call)
                    try await call.media?.prepareKeys(native, members: members, index: index)
                }
                callbacks.switchKeys = { [weak self, weak call] index in
                    guard let self, let call else { throw CancellationError() }
                    try self.require(call)
                    self.pauseChat()
                    try await call.media?.switchKeys(index: index)
                    try self.require(call)
                    guard self.maySend(call) else { throw CancellationError() }
                    self.chat.activate()
                    call.keyRevision &+= 1; self.record(.keysInstalled)
                }
                callbacks.retireKeys = { [weak self, weak call] index in
                    guard let self, let call else { throw CancellationError() }
                    try self.require(call)
                    try call.media?.retireKeys(index: index)
                }
            }
            let group = try dependencies.makeGroup(call.login, call.admission, callbacks)
            async let configuration: Void = group.prepareConfiguration()
            status = "正在建立语音连接"; encryptionStatus = "端到端加密已配置，等待音频验证"
            record(.mediaConnectStarted)
            try await media.connect(url: ServerAddress.validate(call.response.livekitURL, websocket: true), token: call.response.token)
            try require(call)
            transition(.securing, message: "正在建立安全群组")
            encryptionStatus = "安全初始化中，麦克风尚未发送"
            await configuration
            try require(call)
            call.group = group
            if call.reconnecting || call.audioInterrupted {
                try await group.suspend()
                try require(call)
            }
            record(.groupStarted)
            group.start()
        } catch {
            if owns(call) { fail(ClientFailure.capture(error, fallback: .voiceConnectionFailed), call: call) }
        }
    }

    func leave() {
        let pending = preparation
        preparationID = nil; preparingRoomID = nil; preparation = nil
        pending?.cancel()
        detachCurrentCall(authorization: pending, audioCleanup: audio.cancelTest())
    }

    func shutdown() async {
        leave()
        await leaving?.value
        try? await audio.prepareForCall()
    }

    private func detachCurrentCall(authorization: Task<Void, Error>? = nil, audioCleanup: Task<Void, Never>? = nil) {
        let call = current
        guard call != nil || authorization != nil || audioPresetTask != nil || audioCleanup != nil else { return }
        audio.stopRoomSounds()
        roomIdentity?.end()
        current = nil
        // Revoke data queues and attachment leases before the first await.
        call?.media?.invalidate(); call?.keysReady = false; call?.group?.cancel()
        call?.connectTask?.cancel(); call?.microphoneTask?.cancel(); call?.recoveryTask?.cancel(); call?.presetTask?.cancel()
        call?.audioResumeTask?.cancel()
        let pendingPreset = audioPresetTask
        pendingPreset?.cancel(); audioPresetTask = nil
        let pendingChat = chatSendTask
        presetChangeID = nil; isChangingMicrophone = false; isChangingAudioPreset = false
        attachments.end(); pauseChat(); chat.end(); members = []
        trackDiagnostics = []; memberVolumes = [:]; roomPublicInformation = nil
        encryptionStatus = "未连接"
        audioProcessingStatus = "已选：\(audioPreset.title)；麦克风开启后确认"
        let previous = leaving, id = UUID()
        cleanupID = id
        transition(.leaving, message: "正在离开")
        record(.leaving, call: call)
        leaving = Task { @MainActor [self] in
            await previous?.value
            await audioCleanup?.value
            await call?.media?.stop()
            _ = try? await authorization?.value
            await call?.connectTask?.value
            await call?.microphoneTask?.value
            await call?.recoveryTask?.value
            await call?.audioResumeTask?.value
            _ = try? await call?.presetTask?.value
            _ = try? await pendingPreset?.value
            await pendingChat?.value
            await call?.group?.stop()
            if let call { await release(call.admission, login: call.login) }
            guard cleanupID == id else { return }
            cleanupID = nil; leaving = nil
            if current == nil {
                transition(preparationID == nil ? .idle : .authorizing, message: preparationID == nil ? "已离开" : "正在加入房间")
                record(.cleanedUp, call: call)
            }
        }
    }

    private func release(_ admission: RoomAdmission, login: ClientSession) async {
        let api = dependencies.makeAPI(login)
        defer { api.close() }
        // The cleanup task is independent of a cancelled UI or admission task.
        await Task.detached { try? await api.leave(admission) }.value
    }

    private func pause(_ call: ActiveCall) async throws {
        try require(call)
        let pendingMicrophone = call.microphoneTask
        pendingMicrophone?.cancel()
        call.keysReady = false; pauseChat()
        transition(phase == .securing ? .securing : .recovering, message: "正在更新安全连接")
        encryptionStatus = "正在更新群组密钥"
        updateIdentityStatus()
        try await call.media?.pause()
        await pendingMicrophone?.value
        try require(call)
    }

    private func install(_ native: MLSClient, members: [MLSPeer], call: ActiveCall) async throws {
        try require(call)
        guard let groupID = call.group?.groupID else { throw CancellationError() }
        try roomIdentity?.updateRoster(members)
        guard let media = call.media else { throw CancellationError() }
        let transport = call.transportGeneration
        try await media.installKeys(native, members: members)
        try require(call)
        guard call.group?.groupID == groupID else { throw CancellationError() }
        call.installedGroupID = groupID; call.installedTransport = transport; call.keyRevision &+= 1
        call.roster = members
        call.decryptionIssues = [:]
        let named = members.map { peer in
            MLSPeer(identity: peer.identity, name: displayName(peer), publicKey: peer.publicKey, keyPackage: peer.keyPackage, binding: peer.binding, offer: peer.offer, ready: peer.ready)
        }
        chat.install(groupID: groupID, members: named)
        if members.allSatisfy({ $0.binding == nil }) { chat.updateDisplayNames(profileNames) }
        updateMembers(call); record(.keysInstalled)
    }

    private func activate(_ call: ActiveCall) async throws {
        try require(call)
        guard call.group?.maySend == true else { throw CancellationError() }
        record(.mediaLeaseGranted)
        try roomIdentity?.keysReady()
        guard let media = call.media else { throw CancellationError() }
        guard !call.audioInterrupted else { return }
        call.keysReady = call.installedTransport == call.transportGeneration && call.installedGroupID == call.group?.groupID
        guard call.keysReady, !call.reconnecting, media.isConnected else { return }
        let epoch = call.transportGeneration, groupID = call.group?.groupID
        let authorized: @MainActor () -> Bool = { [weak self, weak call] in
            guard let self, let call else { return false }
            return self.maySend(call, allowRebuilding: true) && call.transportGeneration == epoch && call.group?.groupID == groupID
        }
        do {
            try await media.activate(authorized: authorized)
            try require(call)
            try await media.setMicrophone(enabled: !isMuted, authorized: { [weak self] in authorized() && self?.isMuted == false })
        } catch is CancellationError {
            try require(call)
            if call.audioInterrupted { return }
            // Muting while the device starts is a new user intent, not a failed
            // group. The adapter has already muted the interrupted publication.
            guard authorized(), isMuted else { throw CancellationError() }
            try await media.setMicrophone(enabled: false, authorized: authorized)
        }
        try require(call)
        guard authorized() else { throw CancellationError() }
        transition(.active, message: "已加入语音")
        encryptionStatus = "安全群组已就绪，等待音频验证"
        chat.activate(); updateMembers(call); record(.activated)
        let sounds = call.presence.confirm(Set(call.roster.map(\.identity)), localIdentity: call.admission.identity)
        if isListening { for sound in sounds { audio.playRoomSound(sound) } }
    }

    private func receive(_ event: CallMediaEvent, from call: ActiveCall) {
        guard owns(call) else { record(.staleEventIgnored); return }
        switch event {
        case .connected: record(.mediaConnected)
        case .reconnecting:
            guard !call.reconnecting else { return }
            audio.stopRoomSounds(); call.presence.resynchronize()
            call.transportGeneration &+= 1; call.reconnecting = true; call.installedTransport = nil
            call.participants = []
            updateMembers(call)
            recoverTransport(call, finished: false)
        case .reconnected:
            if let roomIdentity { try? roomIdentity.updateRoster(call.roster, reconnected: true); Task { await roomIdentity.social.refresh() } }
            guard call.reconnecting else { return }
            call.reconnecting = false
            recoverTransport(call, finished: true)
        case .disconnected: fail(ClientFailure(.voiceDisconnected), call: call)
        case let .participants(participants):
            guard !call.reconnecting else { return }
            call.participants = participants
            updateMembers(call)
        case let .data(data, sender, encrypted):
            guard isConnected, chat.groupID == call.group?.groupID else { return }
            chat.receive(data, sender: sender, encrypted: encrypted, onAttachment: { [attachments] in attachments.receive($0) })
        case let .audioStatus(message): if !isChangingAudioPreset && !isChangingMicrophone { audioProcessingStatus = message }
        case let .trackDiagnostics(tracks):
            let previous = trackDiagnostics
            trackDiagnostics = tracks.filter { track in call.roster.contains { $0.identity == track.identity } }
            if !call.observedRemoteDecryption, trackDiagnostics.contains(where: { $0.subscribed && $0.encryption == .verified && $0.lastDecryption != nil }) {
                call.observedRemoteDecryption = true; record(.firstRemoteDecryption)
            }
            updateAttachmentPolicy()
            let now = ContinuousClock.now
            let generation = log.recordingGeneration
            if generation != 0 {
                let due = call.lastLogSample.map { $0.duration(to: now) >= .seconds(5) } ?? true
                if due || generation != call.lastLogGeneration || !previous.elementsEqual(trackDiagnostics, by: { $0.sameState(as: $1) }) {
                    call.lastLogGeneration = generation
                    call.lastLogSample = now
                    log.record(.call, "trackSample", details: .sample(diagnosticSample()), generation: generation)
                }
            }
            updateEncryptionSummary(call)
            recoverPersistentDecryptionFailure(call)
        case let .failed(failure): fail(failure, call: call)
        }
    }

    private func recoverTransport(_ call: ActiveCall, finished: Bool) {
        call.media?.suspendSending()
        call.keysReady = false; pauseChat()
        transition(.recovering, message: "正在恢复语音"); record(.recoveryStarted)
        let previous = call.recoveryTask
        call.recoveryTask = Task { @MainActor [weak self, weak call] in
            await previous?.value
            guard let self, let call, owns(call), !Task.isCancelled else { return }
            do {
                if finished { try await call.group?.refresh() }
                else { try await call.group?.suspend() }
            } catch {
                if !(error is CancellationError) { fail(ClientFailure(.secureConnectionRecoveryFailed), call: call) }
            }
        }
    }

    private func fail(_ failure: ClientFailure, call: ActiveCall) {
        guard owns(call) else { return }
        errorMessage = failure; record(.failed, failure: failure)
        // A failure in the old call cannot cancel a new room's password preflight.
        detachCurrentCall()
    }

    private var identityAllowsSending: Bool { roomIdentity.map { $0.social.voiceAllowed && ($0.trust == .solo || $0.trust == .trusted) } ?? dependencies.authorizeIdentity() }
    private func updateIdentityStatus() {
        guard current != nil, [.securing, .verifying, .active, .recovering].contains(phase), let roomIdentity else { return }
        if roomIdentity.trust == .pending {
            if phase != .verifying { transition(.verifying, message: "等待身份核验"); record(.verificationPending) }
            if encryptionStatus != "存在未核验设备，语音、文字和附件均已暂停。" {
                encryptionStatus = "存在未核验设备，语音、文字和附件均已暂停。"
            }
        } else if phase == .verifying {
            transition(.securing, message: "正在建立安全群组")
            encryptionStatus = "正在更新群组密钥"
        }
    }
    private func muteForIdentityTransition() {
        isMuted = true
        guard let call = current else { return }; call.media?.suspendSending(); pauseChat(); call.microphoneTask?.cancel()
        Task { try? await call.media?.setMicrophone(enabled: false, authorized: { true }) }
    }
    func toggleMute() {
        if isMuted && !identityAllowsSending { return }
        guard let call = current, !isChangingMicrophone, !isChangingAudioPreset,
              isConnected || !isMuted else { return }
        let enabled = isMuted, epoch = call.transportGeneration, groupID = call.group?.groupID
        // Remain muted until permission is granted. A rekey or reconnect while
        // the system alert is open must not inherit an unauthorized unmute.
        if !enabled { isMuted = true }
        if enabled { record(.microphoneRequested) }
        isChangingMicrophone = true
        call.microphoneTask = Task { @MainActor [weak self, weak call] in
            guard let self, let call else { return }
            defer { if owns(call) { isChangingMicrophone = false; call.microphoneTask = nil } }
            do {
                if enabled {
                    let allowed = await dependencies.requestMicrophoneAccess()
                    try require(call)
                    guard call.transportGeneration == epoch, call.group?.groupID == groupID,
                          maySend(call), isMuted else { throw CancellationError() }
                    guard allowed else {
                        isMuted = true
                        errorMessage = ClientFailure(.microphonePermissionRequired)
                        return
                    }
                    record(.microphonePermissionGranted)
                    isMuted = false
                    errorMessage = nil
                }
                try await call.media?.setMicrophone(enabled: enabled, authorized: { [weak self, weak call] in
                    guard let self, let call else { return false }
                    return self.maySend(call) && !self.isMuted && call.transportGeneration == epoch && call.group?.groupID == groupID
                })
                try require(call)
                guard call.transportGeneration == epoch, call.group?.groupID == groupID else { return }
                audioProcessingStatus = isMuted ? "已选：\(audioPreset.title)；麦克风已静音" : "已生效：\(audioPreset.title)"
                record(.microphoneChanged)
            } catch {
                guard owns(call), !(error is CancellationError), call.transportGeneration == epoch,
                      call.group?.groupID == groupID else { return }
                if enabled && !maySend(call) { return }
                isMuted = true; fail(ClientFailure(.microphoneUpdateFailed), call: call)
            }
        }
    }

    func changeAudioPreset(to preset: AudioPreset) async throws {
        guard preset != audioPreset else { return }
        guard canChangeAudioPreset else { throw ClientFailure(.audioPresetBusy) }
        let id = UUID(), call = current, previous = audioPreset
        presetChangeID = id; isChangingAudioPreset = true
        let task = Task { @MainActor [self] in
            try await dependencies.validateAudioPreset(preset)
            try Task.checkCancellation()
            guard presetChangeID == id, current === call else { throw CancellationError() }
            do {
                if let media = call?.media {
                    audioProcessingStatus = "正在应用：\(preset.title)"
                    try await media.applyAudioPreset(preset, microphoneEnabled: !isMuted)
                }
                try Task.checkCancellation()
                guard presetChangeID == id, current === call else { throw CancellationError() }
                audioPreset = preset; preset.save(to: defaults)
                audioProcessingStatus = call?.media?.hasMicrophone == true && !isMuted
                    ? "已生效：\(preset.title)" : "已保存：\(preset.title)；麦克风开启后确认"
                record(.audioPresetChanged)
            } catch {
                if let call, owns(call), let media = call.media, !(error is CancellationError) {
                    do {
                        try await media.applyAudioPreset(previous, microphoneEnabled: !isMuted)
                        if owns(call) { audioProcessingStatus = "切换未成功，仍使用：\(previous.title)" }
                    } catch { fail(ClientFailure(.audioPresetRecoveryFailed), call: call) }
                }
                throw error
            }
        }
        call?.presetTask = task
        audioPresetTask = task
        defer { if presetChangeID == id { presetChangeID = nil; isChangingAudioPreset = false; call?.presetTask = nil; audioPresetTask = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func reportJoinError(_ error: Error) {
        log.record(.room, "join", outcome: .failed, failure: ClientFailure.capture(error))
        if !(error is CancellationError) { errorMessage = ClientFailure.capture(error, fallback: .voiceConnectionFailed) }
    }
    func updateRoomNames(_ rooms: [RoomOverview]) {
        if let room = rooms.first(where: { $0.roomID == currentRoomID }) { roomDisplayName = room.displayName }
    }
    func updateProfileNames(_ names: [String: String]) {
        profileNames = names
        refreshVerifiedNames()
    }
    func refreshVerifiedNames() {
        guard let call = current else { return }
        let names = Dictionary(call.roster.map { (MemberProfile.memberID(for: $0.identity), displayName($0)) }, uniquingKeysWith: { first, _ in first })
        chat.updateDisplayNames(names)
        updateMembers(call)
    }
    private func displayName(_ peer: MLSPeer) -> String {
        if let call = current, peer.identity == call.admission.identity {
            return profileNames[call.login.member.id] ?? call.login.member.displayName
        }
        guard let binding = peer.binding else { return profileNames[MemberProfile.memberID(for: peer.identity)] ?? peer.name }
        if let friend = roomIdentity?.social.friends.first(where: { $0.accountID == MemberProfile.memberID(for: peer.identity) && $0.accountKey == binding.device.accountKey }) { return friend.name }
        if let name = dependencies.identity?.displayName(for: binding.device.accountKey) { return name }
        // Nicknames are labels. Device trust is shown separately and never
        // inferred from a server-supplied name or avatar.
        return profileNames[MemberProfile.memberID(for: peer.identity)] ?? peer.name
    }
    private func updateMembers(_ call: ActiveCall) {
        guard owns(call) else { return }
        let updated = call.roster.map { peer in
            let participant = call.participants.first { $0.identity == peer.identity }
            let isLocal = peer.identity == call.admission.identity
            return CallMember(id: peer.identity, name: displayName(peer),
                microphoneEnabled: participant?.microphoneEnabled, speaking: participant?.speaking == true,
                listening: isLocal ? isListening : participant?.listening,
                identityVerified: isLocal || (peer.binding.map { roomIdentity?.social.trusts(accountID: MemberProfile.memberID(for: peer.identity), device: $0.device) ?? true } ?? false))
        }.sorted { $0.name < $1.name }
        if members != updated { members = updated }
    }

    func showsChat(in roomID: String) -> Bool { currentRoomID == roomID && hasSession && chat.isVisible }
    func setChatDraft(_ text: String, entryID: String?) {
        guard hasSession, let entryID else { return }; chat.setDraft(text, entryID: entryID)
    }
    func restoreFailedChat(_ id: UUID, entryID: String) {
        guard hasSession, current?.admission.entryID == entryID else { return }
        chat.restoreFailed(id, entryID: entryID)
    }
    private func updateAttachmentPolicy() {
        attachments.updatePolicy(.forCall(phase: phase, tracks: trackDiagnostics))
    }
    private func pauseChat() {
        chatSendTask?.cancel(); chatSendTask = nil; chatSendID = nil; chat.pause()
    }
    func sendChat() {
        guard canSendChat, let call = current, let deadline = call.group?.sendingDeadline else { return }
        do {
            guard let sender = try call.media?.encryptedSender(deadline: deadline, loginExpiresAt: call.login.expiresAt) else { return }
            let (envelope, payload) = try chat.prepare()
            let destinations = call.roster.map(\.identity)
            chatSendID = envelope.id
            chatSendTask = Task { @MainActor [weak self, weak call] in
                var bytes = payload
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                do {
                    try await sender.send(bytes, destinations: destinations)
                    guard let self, let call, owns(call), chatSendID == envelope.id else { return }
                    chat.finish(envelope.id, succeeded: maySend(call) && chat.isReady && chat.groupID == envelope.groupID)
                    chatSendID = nil; chatSendTask = nil
                } catch {
                    guard let self, let call, owns(call), chatSendID == envelope.id else { return }
                    chat.finish(envelope.id, succeeded: false); chatSendID = nil; chatSendTask = nil
                }
            }
        } catch { chat.preparationFailed() }
    }
    private func waitForAttachmentAuthorization(_ call: ActiveCall) async throws {
        while true {
            try require(call)
            guard call.login.expiresAt > Date() else { throw CancellationError() }
            if canSendAttachment { return }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
    private func sendAttachmentDescriptor(_ descriptor: AttachmentDescriptor, expectedGroupID: String, call: ActiveCall) async throws {
        while chat.pendingID != nil {
            try require(call)
            guard canSendAttachment, chat.groupID == expectedGroupID else { throw ClientFailure(.chatNotReady) }
            try await Task.sleep(for: .milliseconds(50))
        }
        try require(call)
        guard canSendAttachment, chat.groupID == expectedGroupID, let deadline = call.group?.sendingDeadline,
              let sender = try call.media?.encryptedSender(deadline: deadline, loginExpiresAt: call.login.expiresAt) else { throw ClientFailure(.chatNotReady) }
        let (envelope, payload) = try chat.prepareAttachment(descriptor)
        let destinations = call.roster.map(\.identity)
        var bytes = payload
        defer { bytes.resetBytes(in: 0..<bytes.count) }
        do {
            for start in stride(from: 0, to: destinations.count, by: 8) {
                try await sender.send(bytes, destinations: Array(destinations[start..<min(start + 8, destinations.count)]))
            }
            try require(call)
            guard maySend(call), chat.isReady, chat.groupID == envelope.groupID,
                  chat.pendingID == envelope.id else { throw CancellationError() }
            chat.finish(envelope.id, succeeded: true)
        } catch {
            if owns(call) { chat.finish(envelope.id, succeeded: false) }
            throw error
        }
    }
}

extension CallController {
    var canStartMicrophoneTest: Bool {
        current == nil && preparationID == nil && cleanupID == nil && !isChangingAudioPreset && audio.isAvailable
    }
    var canResumeAudio: Bool { current?.audioInterrupted == true && current?.audioResumeID == nil }

    func startMicrophoneTest(owner: UUID? = nil) async throws {
        guard canStartMicrophoneTest else { throw ClientFailure(.audioControlBusy) }
        try await audio.startTest(preset: audioPreset, owner: owner)
    }

    #if os(macOS)
    func toggleListening() {
        guard let call = current else { return }
        isListening.toggle()
        if !isListening { audio.stopRoomSounds() }
        call.media?.setPlayback(listening: isListening, volumes: memberVolumes)
        updateMembers(call)
        record(.listeningChanged)
    }
    #endif

    func canAdjustVolume(for identity: String) -> Bool {
        guard let call = current else { return false }
        return identity != call.admission.identity && call.roster.contains { $0.identity == identity }
    }

    func setMemberVolume(_ volume: Double, for identity: String) {
        guard canAdjustVolume(for: identity), volume.isFinite else { return }
        memberVolumes[identity] = min(2, max(0, volume))
        current?.media?.setPlayback(listening: isListening, volumes: memberVolumes)
    }

    func recordVolumeChange() { record(.memberVolumeChanged) }

    func audioStatus(for identity: String) -> CallMemberAudioStatus {
        guard let call = current, call.participants.contains(where: { $0.identity == identity }) else { return .noTransport }
        let tracks = trackDiagnostics.filter { $0.identity == identity }
        guard !tracks.isEmpty else { return .noTrack }
        let audible = tracks.filter { !$0.muted }
        guard !audible.isEmpty else { return .muted }
        if audible.contains(where: { $0.quality == .lost }) { return .networkProblem }
        if audible.contains(where: { $0.subscriptionFailed }) { return .subscriptionProblem }
        guard audible.allSatisfy(\.subscribed) else { return .notSubscribed }
        if audible.contains(where: { [.missingKey, .decryptionFailed, .failed].contains($0.encryption) }) { return .decryptionProblem }
        return audible.allSatisfy { $0.encryption == .verified && $0.subscribed } ? .verified : .waiting
    }

    private func updateEncryptionSummary(_ call: ActiveCall) {
        guard owns(call), call.keysReady else { return }
        let audible = trackDiagnostics.filter { !$0.muted && $0.subscribed }
        let count = audible.filter { [.missingKey, .decryptionFailed, .failed].contains($0.encryption) }.count
        if count > 0 { encryptionStatus = "有 \(count) 个音轨等待恢复解密" }
        else if !audible.isEmpty && audible.allSatisfy({ $0.encryption == .verified }) { encryptionStatus = "已验证所有活跃音轨的解密" }
        else { encryptionStatus = "等待有效的加密音频" }
    }

    private func handleAudioEvent(_ event: CallAudioSystemEvent) {
        switch event {
        case .routeChanged:
            audio.stopRoomSounds()
            record(.audioRouteChanged)
            if let call = current {
                do { try call.media?.setOutputDeviceID(audio.devices.outputID == "system" ? nil : audio.devices.outputID) }
                catch { fail(ClientFailure(.audioDeviceChangeFailed), call: call); return }
            }
            if let call = current, phase == .active, !call.audioInterrupted { queueAudioRecovery(call, resume: false) }
        case .interrupted:
            record(.audioInterrupted)
            guard let call = current else { return }
            audio.stopRoomSounds(); call.presence.resynchronize()
            call.media?.suspendSending()
            call.presetTask?.cancel()
            call.audioGeneration &+= 1; call.audioResumeTask?.cancel(); call.audioResumeID = nil
            call.audioInterrupted = true; call.keysReady = false; pauseChat()
            transition(.recovering, message: "系统音频已中断")
            let previous = call.recoveryTask
            call.recoveryTask = Task { @MainActor [weak self, weak call] in
                await previous?.value
                guard let self, let call, owns(call), !Task.isCancelled else { return }
                do { try await call.media?.setAudioSuspended(true) }
                catch { if !(error is CancellationError) { fail(ClientFailure(.voiceDisconnected), call: call) } }
            }
        case .resumeRecommended: resumeAudio()
        case .resumeDeclined:
            record(.audioResumeDeclined)
            if current?.audioInterrupted == true { status = "系统尚未建议恢复，请手动恢复音频" }
        case .servicesReset:
            record(.audioServicesReset)
            if let call = current { fail(ClientFailure(.audioServicesReset), call: call) }
        }
    }

    func resumeAudio() {
        guard let call = current, call.audioInterrupted, call.audioResumeID == nil else { return }
        queueAudioRecovery(call, resume: true)
    }

    private func queueAudioRecovery(_ call: ActiveCall, resume: Bool) {
        call.media?.suspendSending()
        call.keysReady = false; pauseChat()
        transition(.recovering, message: "正在恢复音频与安全连接")
        let previous = call.recoveryTask
        let pendingPreset = call.presetTask
        pendingPreset?.cancel()
        let generation = call.audioGeneration, resumeID = resume ? UUID() : nil
        if resume { call.audioResumeID = resumeID }
        let task = Task { @MainActor [weak self, weak call] in
            await previous?.value
            _ = try? await pendingPreset?.value
            guard let self, let call, owns(call), !Task.isCancelled else { return }
            defer { if resume, call.audioResumeID == resumeID { call.audioResumeID = nil; call.audioResumeTask = nil } }
            guard call.audioGeneration == generation, resume || !call.audioInterrupted else { return }
            do {
                if resume {
                    try await call.media?.setAudioSuspended(false)
                    try require(call)
                    guard call.audioGeneration == generation else { return }
                    call.audioInterrupted = false; record(.audioResumed)
                }
                try await call.group?.refresh()
            } catch {
                if !(error is CancellationError) { fail(ClientFailure(.secureConnectionRecoveryFailed), call: call) }
            }
        }
        call.recoveryTask = task
        if resume { call.audioResumeTask = task }
    }

    private func recoverPersistentDecryptionFailure(_ call: ActiveCall) {
        guard isConnected else { return }
        let now = dependencies.now()
        let bad = trackDiagnostics.filter {
            !$0.muted && $0.subscribed && [.missingKey, .decryptionFailed].contains($0.encryption)
        }
        let ids = Set(bad.map(\.id))
        call.decryptionIssues = call.decryptionIssues.filter { ids.contains($0.key) }
        for track in bad {
            guard let packets = track.packetsReceived, packets > 0 else { continue }
            guard let issue = call.decryptionIssues[track.id] else {
                call.decryptionIssues[track.id] = (now, packets); continue
            }
            // Silence, no track and late old-round packets alone never trigger recovery.
            guard packets > issue.packets, issue.since.duration(to: now) >= .seconds(5) else { continue }
            if let last = call.lastDecryptionRecovery, last.duration(to: now) >= .seconds(60) { call.decryptionAttempts = 0 }
            guard call.decryptionAttempts < 2 else { fail(ClientFailure(.audioDecryptionRecoveryFailed), call: call); return }
            call.decryptionAttempts += 1; call.lastDecryptionRecovery = now; call.decryptionIssues = [:]
            record(.decryptionRecovery)
            queueAudioRecovery(call, resume: false)
            return
        }
    }

    private func diagnosticSample() -> CallDiagnosticSample {
        let now = ContinuousClock.now
        func milliseconds(_ duration: Duration) -> Int {
            let parts = duration.components
            return Int(max(0, min(86_400_000, parts.seconds * 1_000 + parts.attoseconds / 1_000_000_000_000_000)))
        }
        let tracks = trackDiagnostics.sorted { $0.id < $1.id }.enumerated().map { index, track in
            CallDiagnosticSample.Track(number: index + 1, muted: track.muted, subscribed: track.subscribed, subscriptionFailed: track.subscriptionFailed,
                encryption: track.encryption, quality: track.quality,
                lastDecryptionEventAgeMS: track.lastDecryption.map { milliseconds($0.duration(to: now)) },
                packetsReceived: track.packetsReceived, packetsLost: track.packetsLost,
                jitterMS: CallDiagnosticSample.boundedMetric(track.jitterMS), roundTripMS: CallDiagnosticSample.boundedMetric(track.roundTripMS))
        }
        return CallDiagnosticSample(phase: phase, microphoneMuted: isMuted, listening: isListening,
            audioInterrupted: current?.audioInterrupted == true, route: audio.devices.route, preset: audioPreset,
            mediaLeaseValid: current?.group?.maySend == true,
            mediaLeaseRemainingMS: current?.group?.sendingDeadline.map { milliseconds(now.duration(to: $0)) },
            tracks: tracks)
    }
}
