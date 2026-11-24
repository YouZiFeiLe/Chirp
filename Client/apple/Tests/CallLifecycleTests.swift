import ChirpMLS
import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif
#if !SWIFT_PACKAGE
import SwiftUI
#endif

@MainActor
private final class CallGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private(set) var entered = false
    // Deliberately ignores cancellation, like an SDK completion already in flight.
    func wait() async {
        entered = true
        if open { return }
        await withCheckedContinuation { continuations.append($0) }
    }
    func release() {
        open = true
        let pending = continuations; continuations = []
        for continuation in pending { continuation.resume() }
    }
}

@MainActor
private func eventually(_ predicate: () -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while !predicate() {
        guard ContinuousClock.now < deadline else { throw NSError(domain: "CallLifecycle condition timed out", code: 1) }
        await Task.yield()
    }
}

private func callLogin(_ marker: String = "a") throws -> ClientSession {
    try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "member": ["id": "member_test", "display_name": "Member"],
        "credential": "chirp_" + String(repeating: marker, count: 43),
        "participant_identity": "member_test.login_" + marker,
        "expires_at": Int(Date().timeIntervalSince1970) + 3600,
    ]), connection: testServerConnection)
}

@MainActor
private final class CallFixture {
    struct Cleanup {
        let room: String
        let entry: String
        let credential: String
    }
    var authorizing: CallGate?
    var preparing: CallGate?
    var validating: CallGate?
    var rejectedRoom: String?
    var nextConnectGate: CallGate?
    var nextInstallGate: CallGate?
    var medias: [TestCallMedia] = []
    var groups: [TestCallGroup] = []
    var committed: [JoinResponse] = []
    var cleanups: [Cleanup] = []
    var sequence: Int64 = 0
    var apiCount = 0
    var call: CallController!
    let hardware: TestCallAudioHardware?
    var extraPeers: [MLSPeer] = []
    var registeredFixture: V5TestIdentity?
    var now = ContinuousClock.now
    var createdMediaWhileTesting = false
    var microphoneAccessAllowed = true
    var microphoneAccessGate: CallGate?
    var microphoneAccessRequests = 0
    var smoothRotation = false
    var mediaTokenRequests = 0

    init(hardware: TestCallAudioHardware? = nil, defaults: UserDefaults = .standard, log: ClientLog = .shared) {
        self.hardware = hardware
        call = CallController(dependencies: dependencies(), defaults: defaults, log: log)
    }
    func dependencies() -> CallDependencies {
        CallDependencies(authorizeIdentity: { true }, prepare: { [self] in await preparing?.wait() }, makeAPI: { [self] in
            apiCount += 1
            return TestCallAPI(fixture: self, login: $0)
        }, makeMedia: { [self] _, event in
            if hardware?.recording == true || hardware?.isTestPlaying == true { createdMediaWhileTesting = true }
            let media = TestCallMedia(event: event)
            media.supportsSmoothRotation = smoothRotation
            media.connectGate = nextConnectGate; nextConnectGate = nil
            media.installGate = nextInstallGate; nextInstallGate = nil
            medias.append(media)
            return media
        }, makeGroup: { [self] _, admission, callbacks in
            let group = try TestCallGroup(admission: admission, callbacks: callbacks)
            group.extraPeers = extraPeers
            group.registeredFixture = registeredFixture
            groups.append(group)
            return group
        }, validateAudioPreset: { [self] _ in await validating?.wait() }, makeAudio: { [self] in hardware },
        requestMicrophoneAccess: { [self] in
            microphoneAccessRequests += 1
            await microphoneAccessGate?.wait()
            return microphoneAccessAllowed
        }, now: { [self] in now })
    }
    func start(_ room: String = "friends") async throws {
        if call.clientSession == nil { call.setClientSession(try callLogin()) }
        try await call.startJoin(room: .loading(id: room))
    }
    func active(_ room: String = "friends") async throws {
        try await start(room)
        try await eventually { self.call.phase == .active && self.call.currentRoomID == room }
    }
}

@MainActor
private final class TestCallAPI: CallRoomAPI {
    let fixture: CallFixture
    let login: ClientSession
    init(fixture: CallFixture, login: ClientSession) { self.fixture = fixture; self.login = login }
    func joinSequence(for login: ClientSession) async throws -> Int64 { fixture.sequence }
    func freshMediaToken(_ admission: RoomAdmission) async throws -> String {
        fixture.mediaTokenRequests += 1
        return "synthetic-fresh-token"
    }
    func authorizeRoom(roomID: String, sequence: Int64, login: ClientSession, password: String?) async throws -> JoinResponse {
        if fixture.rejectedRoom == roomID { throw APIError.roomAccess(ClientFailure(.roomPasswordIncorrect)) }
        fixture.sequence = sequence
        let entry = "entry_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let response = JoinResponse(livekitURL: "wss://rtc.example.com", roomID: roomID, displayName: "Room " + roomID,
            entryID: entry, joinSequence: sequence, admissionExpiresAt: Int64(Date().timeIntervalSince1970) + 30,
            participantIdentity: login.participantIdentity + "." + entry, token: "synthetic-token",
            keyProtocol: VoiceRooms.keyProtocol, mediaTransport: "udp", e2eeRequired: true)
        fixture.committed.append(response)
        await fixture.authorizing?.wait()
        return response
    }
    func leave(_ admission: RoomAdmission) async throws {
        fixture.cleanups.append(.init(room: admission.roomID, entry: admission.entryID, credential: login.credential))
    }
    nonisolated func close() {}
}

@MainActor
private final class TestCallMedia: CallMedia {
    var supportsSmoothRotation = false
    var preparedRotations = 0
    var switchedRotations = 0
    let event: @MainActor (CallMediaEvent) -> Void
    var connectCount = 0
    var connectGate: CallGate?
    var installGate: CallGate?
    var microphoneGate: CallGate?
    var presetGate: CallGate?
    var rejectedPreset: AudioPreset?
    var presetApplications: [AudioPreset] = []
    var presetMicrophoneStates: [Bool] = []
    var stopGate: CallGate?
    var isConnected = false
    var hasMicrophone = false
    var microphoneEnabled = false
    var microphoneChanges: [Bool] = []
    var invalidated = false
    var stopped = false
    var stopCount = 0
    var installations = 0
    var activations = 0
    var verifyNativeKeys = false
    var senderKeys: [String: Data] = [:]
    var gate = CallMediaGate()
    var listening = true
    var volumes: [String: Double] = [:]
    var audioSuspended = false
    var outputDeviceID: String?
    var resumeGate: CallGate?
    var voiceActivation: VoiceActivationControl?
    func setVoiceActivation(_ control: VoiceActivationControl) { voiceActivation = control }
    init(event: @escaping @MainActor (CallMediaEvent) -> Void) { self.event = event }
    func connect(url: URL, token: String) async throws {
        connectCount += 1
        await connectGate?.wait()
        guard !invalidated, !Task.isCancelled else { throw CancellationError() }
        isConnected = true; event(.connected)
    }
    func invalidate() { invalidated = true; gate.revoke(); microphoneEnabled = false; isConnected = false; senderKeys = [:] }
    func suspendSending() { gate.revoke() }
    func stop() async {
        guard !stopped else { return }
        stopped = true; stopCount += 1; invalidate()
        await stopGate?.wait()
    }
    func pause() async throws { gate.revoke(); microphoneEnabled = false }
    func installKeys(_ native: MLSClient, members: [MLSPeer]) async throws {
        installations += 1
        await installGate?.wait()
        guard !invalidated, !Task.isCancelled else { throw CancellationError() }
        if verifyNativeKeys {
            for member in members { senderKeys[member.identity] = try await native.senderKey(for: member.identity) }
        }
        gate.revoke(); gate = CallMediaGate()
    }
    func activate(authorized: @escaping @MainActor () -> Bool) async throws {
        guard !invalidated, authorized() else { throw CancellationError() }
        activations += 1
    }
    func prepareKeys(_ native: MLSClient, members: [MLSPeer], index: Int32) async throws { preparedRotations += 1 }
    func switchKeys(index: Int32) async throws { switchedRotations += 1; gate.revoke(); gate = CallMediaGate() }
    func retireKeys(index: Int32) throws {}
    func setMicrophone(enabled: Bool, authorized: @escaping @MainActor () -> Bool) async throws {
        if enabled { await microphoneGate?.wait() }
        guard !invalidated, !Task.isCancelled, !enabled || authorized() else { throw CancellationError() }
        microphoneChanges.append(enabled)
        hasMicrophone = true; microphoneEnabled = enabled
    }
    func setAudioSuspended(_ suspended: Bool) async throws {
        if !suspended { await resumeGate?.wait() }
        guard !invalidated, !Task.isCancelled else { throw CancellationError() }
        audioSuspended = suspended
        if suspended { try await pause() }
    }
    func setOutputDeviceID(_ id: String?) { outputDeviceID = id }
    func setPlayback(listening: Bool, volumes: [String: Double]) { self.listening = listening; self.volumes = volumes }
    func applyAudioPreset(_ preset: AudioPreset, microphoneEnabled: Bool) async throws {
        presetApplications.append(preset); presetMicrophoneStates.append(microphoneEnabled)
        await presetGate?.wait()
        if preset == rejectedPreset { throw ClientFailure(.audioPresetUnconfirmed) }
    }
    func encryptedSender(deadline: ContinuousClock.Instant, loginExpiresAt: Date) throws -> any CallEncryptedSender {
        TestEncryptedSender(gate: gate)
    }
    func emit(_ value: CallMediaEvent) {
        if case .reconnecting = value { isConnected = false }
        if case .reconnected = value { isConnected = true }
        // Deliberately delivers callbacks even after invalidation.
        event(value)
    }
}

@MainActor
private struct TestEncryptedSender: CallEncryptedSender {
    let gate: CallMediaGate
    func send(_ data: Data, destinations: [String]) async throws {
        guard gate.isValid else { throw CancellationError() }
    }
}

@MainActor
private final class TestCallGroup: CallGroupCoordinating {
    let admission: RoomAdmission
    let callbacks: CallGroupCallbacks
    let native: MLSClient
    var groupID: String?
    var maySend = false
    var sendingDeadline: ContinuousClock.Instant? { maySend ? .now.advanced(by: .seconds(3)) : nil }
    var round: UInt64 = 0
    var refreshCount = 0
    var suspendCount = 0
    var stopped = false
    var task: Task<Void, Never>?
    private(set) var configurationPrepared = false
    var extraPeers: [MLSPeer] = []
    var registeredFixture: V5TestIdentity?
    init(admission: RoomAdmission, callbacks: CallGroupCallbacks) throws {
        self.admission = admission; self.callbacks = callbacks
        native = try MLSClient(identity: admission.identity)
    }
    func prepareConfiguration() async { configurationPrepared = true }
    func start() {
        task = Task { @MainActor in
            do { try await completeRound() }
            catch { if !stopped && !(error is CancellationError) { await callbacks.failed(ClientFailure(.groupCryptoFailed)) } }
        }
    }
    func cancel() { stopped = true; maySend = false; task?.cancel() }
    func stop() async { cancel(); await task?.value }
    func refresh() async throws {
        refreshCount += 1; maySend = false
        try await callbacks.pause()
    }
    func suspend() async throws {
        suspendCount += 1; maySend = false
        try await callbacks.pause()
    }
    func completeRound() async throws {
        maySend = false
        try await callbacks.pause()
        try Task.checkCancellation()
        guard !stopped else { throw CancellationError() }
        round += 1; groupID = admission.roomID + "/fixture/session/" + String(round)
        let peer: MLSPeer
        if let fixture = registeredFixture {
            let policy = V5RoomPolicy.mutual(origin: ServerAddress.identityOrigin(testServerConnection.passkeyOrigin), roomID: admission.roomID)
            peer = MLSPeer(identity: admission.identity, name: "Member", publicKey: fixture.device.leafKey, keyPackage: "", binding: try fixture.binding(policy: policy, identity: admission.identity, mlsKey: fixture.device.leafKey))
        } else { peer = MLSPeer(identity: admission.identity, name: "Member", publicKey: "synthetic", keyPackage: "synthetic") }
        if registeredFixture != nil, try callbacks.approveRoster?([peer] + extraPeers) == nil { return }
        try await callbacks.install(native, [peer] + extraPeers)
        guard !stopped else { throw CancellationError() }
        maySend = true
        try await callbacks.ready([peer] + extraPeers)
    }
}

@MainActor
private final class TestCallAudioHardware: CallAudioHardware {
    func acquireSettingsSession() throws -> () -> Void { {} }
    var onEvent: (@MainActor @Sendable (CallAudioEvent) -> Void)?
    var isTestPlaying = false
    var recording = false
    var testPreset: AudioPreset?
    var startGate: CallGate?
    var finishGate: CallGate?
    var changeGate: CallGate?
    var stopFailures = 0
    var finishes = 0
    var device = CallAudioSnapshot()
    var roomSounds: [RoomPresenceSound] = []
    var soundStops = 0
    var voiceActivation: VoiceActivationControl?
    func setVoiceActivation(_ control: VoiceActivationControl) { voiceActivation = control }
    func refresh() async { onEvent?(.devices(device)) }
    func selectInput(_ id: String) async throws { await changeGate?.wait(); device.inputID = id }
    func selectOutput(_ id: String) async throws { device.outputID = id }
    func preferOutput(_ output: CallAudioOutput) async throws {}
    func playRoomSound(_ sound: RoomPresenceSound) { roomSounds.append(sound) }
    func stopRoomSounds() { soundStops += 1 }
    func startTest(preset: AudioPreset) async throws {
        await startGate?.wait()
        // Intentionally commits a late device start even if the task was cancelled.
        recording = true; testPreset = preset
    }
    func finishTest(playSample: Bool) async throws {
        finishes += 1
        await finishGate?.wait()
        if stopFailures > 0 { stopFailures -= 1; throw ClientFailure(.microphoneTestFailed) }
        recording = false; isTestPlaying = playSample && !Task.isCancelled
    }
    func send(_ event: CallAudioSystemEvent) { onEvent?(.system(event)) }
}

private func diagnosticPeer(_ identity: String) -> MLSPeer {
    .init(identity: identity, name: "Private Name " + identity, publicKey: "synthetic", keyPackage: "synthetic")
}

private func diagnosticTrack(_ identity: String, id: String = "private-track", encryption: CallTrackEncryption = .verified,
                             muted: Bool = false, packets: UInt64 = 1) -> CallTrackDiagnostic {
    .init(id: id, identity: identity, muted: muted, subscribed: true, encryption: encryption, quality: .good,
        lastDecryption: encryption == .verified ? .now : nil, packetsReceived: packets, packetsLost: 0, jitterMS: 5, roundTripMS: 20)
}

@Suite(.serialized) @MainActor
struct CallLifecycleTests {
    @Test(arguments: [true, false])
    func smoothKeyCutoverPreservesMicrophoneIntentAndDoesNotReactivateAudio(muted: Bool) async throws {
        let fixture = CallFixture()
        fixture.smoothRotation = true
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        if !muted {
            fixture.call.toggleMute()
            try await eventually { !fixture.call.isChangingMicrophone && media.microphoneEnabled }
        }
        let changes = media.microphoneChanges, activations = media.activations, installations = media.installations
        let prepare = try #require(group.callbacks.prepare)
        let switching = try #require(group.callbacks.switchKeys)
        let retire = try #require(group.callbacks.retireKeys)
        try await prepare(group.native, [], 1)
        try await switching(1)
        try await retire(0)
        #expect(fixture.call.phase == .active && fixture.call.chat.isReady)
        #expect(fixture.call.isMuted == muted && media.microphoneEnabled == !muted)
        #expect(media.microphoneChanges == changes && media.activations == activations && media.installations == installations)
        #expect(media.preparedRotations == 1 && media.switchedRotations == 1)
        await fixture.call.shutdown()
    }
    @Test func listeningOutputIsSelectedBeforeConnectingAndFollowsDeviceChangesWhileMuted() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        hardware.device.outputID = "usb-test"
        await fixture.call.audio.refresh()
        fixture.nextConnectGate = gate
        try await fixture.start()
        try await eventually { gate.entered }
        let media = try #require(fixture.medias.first)
        #expect(media.outputDeviceID == "usb-test" && !media.microphoneEnabled)
        gate.release()
        try await eventually { fixture.call.phase == .active }
        let group = try #require(fixture.groups.first)
        for (index, id) in ["headphones-test", "system"].enumerated() {
            try await fixture.call.audio.selectOutput(id)
            hardware.send(.routeChanged)
            #expect(media.outputDeviceID == (id == "system" ? nil : id))
            try await eventually { group.refreshCount == index + 1 }
            try await group.completeRound()
            #expect(fixture.call.isMuted && !media.microphoneEnabled && fixture.microphoneAccessRequests == 0)
        }
        await fixture.call.shutdown()
    }

    @Test func allPresetsShareLiveVoiceActivationSettingsAcrossTestsAndCalls() async throws {
        let suite = "ChirpVoiceActivationLifecycle.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware, defaults: defaults)
        fixture.call.voiceActivation.setEnabled(true)
        fixture.call.voiceActivation.setThreshold(-53)
        let control = fixture.call.voiceActivation.control
        #expect(hardware.voiceActivation === control)
        for preset in AudioPreset.allCases {
            try await fixture.call.changeAudioPreset(to: preset)
            try await fixture.call.startMicrophoneTest()
            #expect(hardware.testPreset == preset && hardware.voiceActivation?.settings.enabled == true)
            await fixture.call.audio.cancelTest()?.value
        }
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        #expect(media.voiceActivation === control && fixture.call.isMuted)
        fixture.call.voiceActivation.setThreshold(-40)
        for preset in AudioPreset.allCases {
            try await fixture.call.changeAudioPreset(to: preset)
            #expect(media.voiceActivation?.settings == VoiceActivationSettings(enabled: true, thresholdDBFS: -40))
            #expect(fixture.call.isMuted && !media.microphoneEnabled)
        }
        fixture.call.voiceActivation.setEnabled(false)
        #expect(media.voiceActivation?.settings.enabled == false && fixture.call.isMuted)
        await fixture.call.shutdown()
    }

    @Test func roomPresenceWaitsForConfirmedMembershipAndIgnoresMediaAndProfileUpdates() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        fixture.extraPeers = [diagnosticPeer("existing-a"), diagnosticPeer("existing-b")]
        fixture.nextInstallGate = gate
        try await fixture.start()
        try await eventually { gate.entered }
        #expect(hardware.roomSounds.isEmpty)
        gate.release()
        try await eventually { fixture.call.phase == .active }
        #expect(hardware.roomSounds == [.joined] && fixture.call.isMuted)
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        media.emit(.participants([.init(identity: "existing-a", microphoneEnabled: true, speaking: true, listening: nil)]))
        fixture.call.updateProfileNames(["existing-a": "New name"])
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined])

        let installing = CallGate()
        media.installGate = installing
        group.extraPeers.append(diagnosticPeer("new-peer"))
        let update = Task { try await group.completeRound() }
        try await eventually { installing.entered }
        #expect(hardware.roomSounds == [.joined])
        installing.release(); try await update.value
        #expect(hardware.roomSounds == [.joined, .joined])
        group.extraPeers.removeAll { $0.identity == "existing-a" }
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined, .joined, .left])
        await fixture.call.shutdown()
        #expect(hardware.roomSounds == [.joined, .joined, .left] && hardware.soundStops > 0)
    }

    @Test func reconnectAndAudioInterruptionDoNotReplayRoomPresenceHistory() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        fixture.extraPeers = [diagnosticPeer("before-reconnect")]
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        media.emit(.reconnecting)
        try await eventually { group.suspendCount == 1 }
        media.emit(.reconnected)
        try await eventually { group.refreshCount == 1 }
        group.extraPeers = [diagnosticPeer("after-reconnect")]
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined] && hardware.soundStops > 0)
        group.extraPeers.append(diagnosticPeer("new-peer"))
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined, .joined])

        hardware.send(.interrupted)
        try await eventually { media.audioSuspended }
        hardware.send(.resumeRecommended)
        try await eventually { group.refreshCount == 2 }
        group.extraPeers = []
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined, .joined] && fixture.call.isConnected)
        await fixture.call.shutdown()
    }

    #if os(macOS)
    @Test func stoppingListeningSilencesPresenceWithoutReplayingItWhenListeningResumes() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        let group = try #require(fixture.groups.first)
        fixture.call.toggleListening()
        let stops = hardware.soundStops
        #expect(stops > 0)
        group.extraPeers = [diagnosticPeer("joined-while-deafened")]
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined])
        fixture.call.toggleListening()
        #expect(hardware.roomSounds == [.joined])
        group.extraPeers = []
        try await group.completeRound()
        #expect(hardware.roomSounds == [.joined, .left] && fixture.call.isMuted)
        await fixture.call.shutdown()
    }
    #endif

    @Test func switchingRoomsClearsPresenceAndRetiredCallbacksCannotAnnounceInTheNewRoom() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        let oldGroup = try #require(fixture.groups.first)
        fixture.rejectedRoom = "rejected"
        let stops = hardware.soundStops
        await #expect(throws: APIError.self) { try await fixture.start("rejected") }
        #expect(hardware.soundStops == stops && hardware.roomSounds == [.joined])
        try await fixture.active("room-next")
        #expect(hardware.roomSounds == [.joined, .joined] && hardware.soundStops > stops)
        await #expect(throws: CancellationError.self) { try await oldGroup.callbacks.ready([]) }
        #expect(hardware.roomSounds == [.joined, .joined])
        await fixture.call.shutdown()
    }

    @Test(arguments: [true, false])
    func appleOnlyCanBeSelectedDuringACallWithoutChangingMuteIntent(muted: Bool) async throws {
        let suite = "ChirpAudioPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CallFixture(defaults: defaults)
        try await fixture.call.changeAudioPreset(to: .apple)
        try await fixture.active()
        if !muted {
            fixture.call.toggleMute()
            try await eventually { !fixture.call.isChangingMicrophone }
        }
        let media = try #require(fixture.medias.first)
        try await fixture.call.changeAudioPreset(to: .appleOnly)
        #expect(fixture.call.audioPreset == .appleOnly && AudioPreset.load(from: defaults) == .appleOnly)
        #expect(fixture.call.isMuted == muted && media.microphoneEnabled == !muted)
        #expect(media.presetApplications.last == .appleOnly && media.presetMicrophoneStates.last == !muted)
        try await fixture.call.changeAudioPreset(to: .apple)
        #expect(fixture.call.audioPreset == .apple && fixture.call.isMuted == muted)
        #expect(media.presetApplications == [.appleOnly, .apple])
        await fixture.call.shutdown()
    }

    @Test func aFailedAppleOnlyTransitionRestoresThePreviousPreset() async throws {
        let suite = "ChirpAudioPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fixture = CallFixture(defaults: defaults)
        try await fixture.call.changeAudioPreset(to: .apple)
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        media.rejectedPreset = .appleOnly
        await #expect(throws: ClientFailure(.audioPresetUnconfirmed)) {
            try await fixture.call.changeAudioPreset(to: .appleOnly)
        }
        #expect(fixture.call.isConnected && fixture.call.audioPreset == .apple && AudioPreset.load(from: defaults) == .apple)
        #expect(media.presetApplications == [.appleOnly, .apple])
        await fixture.call.shutdown()
    }

    @Test func microphoneTestsUseTheSavedAppleOnlyPresetAndStopOnAudioFailure() async throws {
        let suite = "ChirpAudioPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware, defaults: defaults)
        try await fixture.call.changeAudioPreset(to: .appleOnly)
        try await fixture.call.startMicrophoneTest()
        #expect(hardware.testPreset == .appleOnly && hardware.recording)
        hardware.onEvent?(.failed(ClientFailure(.noiseProcessingFailed)))
        try await eventually { fixture.call.audio.testPhase == .idle }
        #expect(!hardware.recording && fixture.call.audio.error == ClientFailure(.noiseProcessingFailed))
        await fixture.call.shutdown()
    }

    @Test func cancellationAfterAdmissionReleasesItWithoutStartingMedia() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.authorizing = gate
        let joining = Task { try await fixture.start() }
        try await eventually { gate.entered }
        #expect(fixture.committed.count == 1 && fixture.call.phase == .authorizing)
        fixture.call.leave()
        let shutdown = Task { await fixture.call.shutdown() }
        #expect(fixture.call.phase == .leaving)
        gate.release()
        _ = try? await joining.value; await shutdown.value
        #expect(fixture.medias.isEmpty)
        #expect(fixture.cleanups.count == 1)
        #expect(fixture.cleanups.first?.entry == fixture.committed.first?.entryID)
        #expect(fixture.call.phase == .idle && !fixture.call.hasPendingWork)
    }

    @Test func callerCancellationAlsoCleansLateServerCommit() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.authorizing = gate
        let joining = Task { try await fixture.start() }
        try await eventually { gate.entered }
        joining.cancel(); gate.release()
        await #expect(throws: CancellationError.self) { try await joining.value }
        #expect(fixture.cleanups.count == 1 && fixture.medias.isEmpty)
        #expect(fixture.call.phase == .idle && fixture.call.preparingRoomID == nil)
    }

    @Test func cancelDuringPreparationNeverAuthorizesARoom() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.preparing = gate
        let joining = Task { try await fixture.start() }
        try await eventually { gate.entered }
        fixture.call.leave(); gate.release()
        _ = try? await joining.value; await fixture.call.shutdown()
        #expect(fixture.apiCount == 0 && fixture.committed.isEmpty && fixture.medias.isEmpty)
    }

    @Test func listeningDoesNotRequestMicrophoneAndDenialPreservesTheCall() async throws {
        let logs = try ClientLogFixture(enabled: true)
        let fixture = CallFixture(log: logs.log)
        fixture.microphoneAccessAllowed = false
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        #expect(fixture.call.isMuted && fixture.microphoneAccessRequests == 0)
        fixture.call.toggleMute()
        try await eventually { !fixture.call.isChangingMicrophone }
        #expect(fixture.microphoneAccessRequests == 1)
        #expect(fixture.call.isMuted && !media.microphoneEnabled)
        #expect(fixture.call.phase == .active && media.stopCount == 0 && fixture.cleanups.isEmpty)
        #expect(fixture.call.errorMessage?.code == ClientErrorCode.microphonePermissionRequired.rawValue)
        #expect((try await logs.callEvents()).last?.event == .microphoneRequested)
        fixture.microphoneAccessAllowed = true
        fixture.call.toggleMute()
        try await eventually { !fixture.call.isChangingMicrophone }
        #expect(media.microphoneEnabled && fixture.call.errorMessage == nil)
        #expect((try await logs.callEvents()).suffix(3).map(\.event) == [.microphoneRequested, .microphonePermissionGranted, .microphoneChanged])
        fixture.call.toggleMute()
        try await eventually { !fixture.call.isChangingMicrophone }
        #expect(fixture.microphoneAccessRequests == 2 && !media.microphoneEnabled)
        await fixture.call.shutdown()
    }

    @Test func lateMicrophonePermissionCannotOpenARetiredCall() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.microphoneAccessGate = gate
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        fixture.call.toggleMute()
        try await eventually { gate.entered }
        fixture.call.leave()
        gate.release()
        await fixture.call.shutdown()
        #expect(!media.microphoneEnabled && media.stopped)
        #expect(fixture.call.phase == .idle && !fixture.call.hasPendingWork)
    }

    @Test func rekeyWhilePermissionIsPendingKeepsTheMicrophoneMuted() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.microphoneAccessGate = gate
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        fixture.call.toggleMute()
        try await eventually { gate.entered }
        #expect(fixture.call.isMuted && !media.microphoneEnabled)
        let rekey = Task { try await group.completeRound() }
        try await eventually { fixture.call.phase == .recovering }
        gate.release()
        try await rekey.value
        #expect(fixture.call.phase == .active && fixture.call.isMuted && !media.microphoneEnabled)
        await fixture.call.shutdown()
    }

    @Test func wrongPasswordPreservesOldCallAndDraft() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        fixture.call.setChatDraft("keep this draft", entryID: fixture.call.chat.admission?.entryID)
        fixture.rejectedRoom = "room-other"
        await #expect(throws: APIError.self) { try await fixture.start("room-other") }
        #expect(fixture.call.phase == .active && fixture.call.currentRoomID == "friends")
        #expect(fixture.call.chat.draft == "keep this draft" && media.stopCount == 0)
        #expect(fixture.cleanups.isEmpty)
        await fixture.call.shutdown()
    }

    @Test func oldCallFailureCannotCancelTheNextRoomsAdmission() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let old = try #require(fixture.medias.first), gate = CallGate()
        fixture.authorizing = gate
        let joining = Task { try await fixture.start("room-next") }
        try await eventually { gate.entered }
        old.emit(.disconnected)
        #expect(fixture.call.preparingRoomID == "room-next")
        gate.release(); try await joining.value
        try await eventually { fixture.call.phase == .active }
        #expect(fixture.call.currentRoomID == "room-next" && fixture.call.errorMessage == nil)
        #expect(old.stopCount == 1 && fixture.cleanups.count == 1)
        await fixture.call.shutdown()
    }

    @Test func switchingWaitsForOldCleanupBeforeCreatingAnotherMediaOwner() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let old = try #require(fixture.medias.first), gate = CallGate()
        old.stopGate = gate
        try await fixture.start("room-next")
        try await eventually { gate.entered }
        #expect(old.invalidated && fixture.medias.count == 1)
        #expect(fixture.call.phase == .connecting && fixture.call.currentRoomID == "room-next")
        gate.release()
        try await eventually { fixture.call.phase == .active }
        #expect(fixture.medias.count == 2 && old.stopCount == 1)
        #expect(fixture.cleanups.count == 1 && fixture.cleanups.first?.room == "friends")
        await fixture.call.shutdown()
    }

    @Test func leaveDuringConnectDrainsTheUncancellableCompletion() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.nextConnectGate = gate
        try await fixture.start()
        try await eventually { gate.entered && fixture.groups.first?.configurationPrepared == true }
        let group = try #require(fixture.groups.first)
        #expect(group.task == nil && !group.maySend)
        fixture.call.leave(); fixture.call.leave()
        let shutdown = Task { await fixture.call.shutdown() }
        try await eventually { fixture.medias.first?.stopCount == 1 }
        #expect(fixture.call.phase == .leaving)
        gate.release(); await shutdown.value
        #expect(fixture.call.phase == .idle && group.task == nil && group.round == 0)
        #expect(fixture.medias.first?.stopCount == 1 && fixture.cleanups.count == 1)
        try await fixture.active("room-next")
        #expect(fixture.call.currentRoomID == "room-next")
        await fixture.call.shutdown()
    }

    @Test func admissionOwnsSessionBeforeMediaCreationAndCanBeCancelled() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.validating = gate
        try await fixture.start()
        try await eventually { gate.entered }
        #expect(fixture.call.hasSession && fixture.call.currentRoomID == "friends")
        #expect(fixture.medias.isEmpty && !fixture.call.isConnected)
        fixture.call.leave()
        #expect(!fixture.call.hasSession && fixture.call.currentRoomID == nil)
        gate.release()
        await fixture.call.shutdown()
        #expect(fixture.call.phase == .idle && !fixture.call.hasPendingWork)
        #expect(fixture.medias.isEmpty && fixture.cleanups.count == 1)
    }

    @Test func retiredMediaAndGroupCallbacksCannotOverwriteNewCall() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let oldMedia = try #require(fixture.medias.first), oldGroup = try #require(fixture.groups.first)
        try await fixture.active("room-next")
        oldMedia.emit(.disconnected)
        oldMedia.emit(.failed(ClientFailure(.audioEncryptionFailed)))
        oldMedia.emit(.participants([.init(identity: "retired", microphoneEnabled: true, speaking: true, listening: nil)]))
        await oldGroup.callbacks.failed(ClientFailure(.groupLeaseExpired))
        await #expect(throws: CancellationError.self) { try await oldGroup.callbacks.ready([]) }
        #expect(fixture.call.phase == .active && fixture.call.currentRoomID == "room-next")
        #expect(fixture.call.errorMessage == nil && !fixture.call.members.contains { $0.id == "retired" })
        await fixture.call.shutdown()
    }

    @Test func reconnectCanBeMutedAndNewKeysKeepThatIntent() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        fixture.call.toggleMute()
        try await eventually { media.microphoneEnabled && !fixture.call.isChangingMicrophone }
        let oldDataGate = media.gate
        media.emit(.reconnecting)
        try await eventually { group.suspendCount == 1 && group.refreshCount == 0 }
        #expect(fixture.call.phase == .recovering && !fixture.call.isConnected && !oldDataGate.isValid)
        fixture.call.toggleMute()
        try await eventually { fixture.call.isMuted && !fixture.call.isChangingMicrophone }
        media.emit(.reconnected)
        try await eventually { group.suspendCount == 1 && group.refreshCount == 1 }
        try await group.completeRound()
        #expect(fixture.call.phase == .active && fixture.call.isMuted && !media.microphoneEnabled)
        #expect(media.installations == 2)
        await fixture.call.shutdown()
    }

    @Test func duplicateTransportCallbacksSuspendImmediatelyAndCoalesceOneRekey() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        let oldGate = media.gate
        media.emit(.reconnecting); media.emit(.reconnecting)
        #expect(!oldGate.isValid && fixture.call.phase == .recovering)
        try await eventually { group.suspendCount == 1 }
        #expect(group.refreshCount == 0)
        media.emit(.reconnected); media.emit(.reconnected)
        try await eventually { group.refreshCount == 1 }
        for _ in 0..<20 { await Task.yield() }
        #expect(group.suspendCount == 1 && group.refreshCount == 1)
        try await group.completeRound()
        #expect(fixture.call.phase == .active && media.installations == 2)
        await fixture.call.shutdown()
    }

    @Test func leavingDuringKeyInstallationCannotReactivateMedia() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.nextInstallGate = gate
        try await fixture.start()
        try await eventually { gate.entered }
        let media = try #require(fixture.medias.first)
        fixture.call.leave()
        let shutdown = Task { await fixture.call.shutdown() }
        #expect(media.invalidated && !media.gate.isValid)
        gate.release(); await shutdown.value
        #expect(media.activations == 0 && !media.microphoneEnabled)
        #expect(fixture.call.phase == .idle && fixture.cleanups.count == 1)
    }

    @Test func lateMicrophoneCompletionIsDrainedAndCannotReopenCapture() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), gate = CallGate()
        media.microphoneGate = gate
        fixture.call.toggleMute()
        try await eventually { gate.entered }
        fixture.call.leave()
        let shutdown = Task { await fixture.call.shutdown() }
        gate.release(); await shutdown.value
        #expect(!media.microphoneEnabled && fixture.call.phase == .idle)
        try await fixture.active("room-next")
        #expect(fixture.call.isMuted && !fixture.call.isChangingMicrophone)
        #expect(fixture.call.errorMessage == nil)
        await fixture.call.shutdown()
    }

    @Test func rekeyDrainsPendingUnmuteBeforeActivatingTheNextRound() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first), gate = CallGate()
        media.microphoneGate = gate
        fixture.call.toggleMute()
        try await eventually { gate.entered }
        let rekey = Task { try await group.completeRound() }
        try await eventually { fixture.call.phase == .recovering }
        #expect(!media.microphoneEnabled && media.installations == 1)
        gate.release(); try await rekey.value
        #expect(fixture.call.phase == .active && fixture.call.errorMessage == nil)
        #expect(!fixture.call.isMuted && media.microphoneEnabled && media.installations == 2)
        await fixture.call.shutdown()
    }

    @Test func mutingDuringRecoveryActivationDoesNotFailTheCall() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first), gate = CallGate()
        fixture.call.toggleMute()
        try await eventually { media.microphoneEnabled && !fixture.call.isChangingMicrophone }
        media.microphoneGate = gate
        let rekey = Task { try await group.completeRound() }
        try await eventually { gate.entered }
        #expect(fixture.call.phase == .recovering && !fixture.call.isMuted)
        fixture.call.toggleMute()
        try await eventually { fixture.call.isMuted && !fixture.call.isChangingMicrophone }
        gate.release(); try await rekey.value
        #expect(fixture.call.phase == .active && fixture.call.errorMessage == nil && !media.microphoneEnabled)
        await fixture.call.shutdown()
    }

    @Test func keysInstallingAcrossAReconnectCannotAuthorizeTheNewTransport() async throws {
        let fixture = CallFixture(), gate = CallGate()
        fixture.nextInstallGate = gate
        try await fixture.start()
        try await eventually { gate.entered }
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        media.emit(.reconnecting); media.emit(.reconnected)
        try await eventually { group.suspendCount == 1 && group.refreshCount == 1 }
        gate.release()
        await group.task?.value
        #expect(!fixture.call.isConnected && media.activations == 0 && !media.microphoneEnabled)
        try await group.completeRound()
        #expect(fixture.call.phase == .active && media.activations == 1 && media.installations == 2)
        await fixture.call.shutdown()
    }

    @Test func leavingDrainsPresetChangesWithoutSavingALateCompletion() async throws {
        let fixture = CallFixture()
        try await fixture.active()
        let media = try #require(fixture.medias.first), gate = CallGate()
        let previous = fixture.call.audioPreset, saved = UserDefaults.standard.string(forKey: AudioPreset.preferenceKey)
        let next: AudioPreset = previous == .apple ? .webRTC : .apple
        media.presetGate = gate
        let changing = Task { try await fixture.call.changeAudioPreset(to: next) }
        try await eventually { gate.entered }
        fixture.call.leave()
        let shutdown = Task { await fixture.call.shutdown() }
        #expect(fixture.call.phase == .leaving && !fixture.call.isChangingAudioPreset)
        gate.release()
        await #expect(throws: CancellationError.self) { try await changing.value }
        await shutdown.value
        #expect(fixture.call.audioPreset == previous)
        #expect(UserDefaults.standard.string(forKey: AudioPreset.preferenceKey) == saved)
        try await fixture.active("room-next")
        #expect(fixture.call.audioPreset == previous && !fixture.call.isChangingAudioPreset)
        await fixture.call.shutdown()
    }

    @Test func idlePresetValidationIsAlsoCancelledAndDrainedOnShutdown() async throws {
        let fixture = CallFixture(), gate = CallGate()
        let previous = fixture.call.audioPreset
        fixture.validating = gate
        let changing = Task { try await fixture.call.changeAudioPreset(to: previous == .apple ? .webRTC : .apple) }
        try await eventually { gate.entered }
        #expect(fixture.call.hasPendingWork && fixture.call.phase == .idle)
        let shutdown = Task { await fixture.call.shutdown() }
        try await eventually { fixture.call.phase == .leaving }
        gate.release()
        await #expect(throws: CancellationError.self) { try await changing.value }
        await shutdown.value
        #expect(!fixture.call.hasPendingWork && fixture.call.audioPreset == previous && fixture.apiCount == 0)
    }

    @Test func loginReplacementCleansUsingTheOriginalCredential() async throws {
        let fixture = CallFixture(), first = try callLogin("a"), next = try callLogin("b")
        fixture.call.setClientSession(first)
        try await fixture.active()
        fixture.call.setClientSession(next)
        try await eventually { fixture.call.phase == .idle }
        #expect(fixture.cleanups.count == 1 && fixture.cleanups.first?.credential == first.credential)
        #expect(fixture.call.clientSession?.credential == next.credential && fixture.call.chat.messages.isEmpty)
        try await fixture.active("room-next")
        await fixture.call.shutdown()
        #expect(fixture.cleanups.last?.credential == next.credential)
    }

    @Test func applicationLoginChangesSynchronouslyReachTheSharedCall() async throws {
        let fixture = CallFixture()
        let application = ApplicationSession(dependencies: fixture.dependencies())
        let windowOne = application.call, windowTwo = application.call
        application.login.accept(try callLogin("a"))
        application.login.accept(try callLogin("b"))
        #expect(windowOne === windowTwo)
        #expect(windowOne.clientSession?.credential == application.login.session?.credential)
        application.login.clear()
        #expect(windowOne.clientSession == nil && windowTwo.clientSession == nil)
        await application.call.shutdown()
        #expect(fixture.apiCount == 0)
    }

    @Test func windowClientsOperateTheSameAppOwnedCall() async throws {
        let fixture = CallFixture(), application = ApplicationSession(dependencies: fixture.dependencies())
        var firstWindow: CallController? = application.call
        let secondWindow = application.call
        firstWindow?.setClientSession(try callLogin())
        try await firstWindow?.startJoin(room: .loading(id: "friends"))
        try await eventually { secondWindow.phase == .active }
        secondWindow.toggleMute()
        try await eventually { !secondWindow.isChangingMicrophone }
        #expect(firstWindow?.isMuted == false && fixture.medias.count == 1)
        firstWindow = nil
        #expect(application.call.phase == .active && fixture.medias.first?.stopCount == 0)
        secondWindow.leave()
        await application.call.shutdown()
        #expect(secondWindow.phase == .idle && fixture.cleanups.count == 1)
    }

    @Test func enabledDiagnosticsKeepTheEntireLifecycleAcrossBatches() async throws {
        let logs = try ClientLogFixture(enabled: true)
        var diagnostics = CallDiagnostics()
        for index in 0..<200 {
            diagnostics.record(.staleEventIgnored, phase: .recovering, transport: UInt64(index), into: logs.log)
        }
        let events = try await logs.callEvents()
        #expect(events.map(\.sequence) == (1...200).map(UInt64.init))
        #expect(events.allSatisfy { $0.event == .staleEventIgnored && $0.phase == .recovering })
    }
}

@Suite(.serialized) @MainActor
struct CallAudioLifecycleTests {
    @Test func outputSelectionFollowsTheActualRouteAndExternalChanges() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        hardware.device.supportsReceiver = true
        hardware.device.route = .receiver
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.output == .receiver)
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == .speaker)
        // A request is not evidence that iOS actually changed the route.
        try await fixture.call.audio.preferOutput(.speaker)
        #expect(fixture.call.audio.output == .receiver)
        hardware.device.route = .speaker
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.output == .speaker)
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == .receiver)
        hardware.device.supportsReceiver = false
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == nil)
        hardware.device.supportsReceiver = true
        hardware.device.inputs = [.init(id: "bt", name: "AirPods Pro", route: .bluetooth)]
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == nil)
        #expect(fixture.call.audio.devices.headsetInputs.map(\.id) == ["bt"])
        hardware.device.route = .bluetooth
        hardware.device.outputName = "AirPods Pro"
        hardware.device.inputs = [] // A playback-only Bluetooth route has no selectable input.
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.output == .system)
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == nil)
        #expect(fixture.call.audio.devices.outputTitle.localized(in: AppLanguage.english.locale) == "AirPods Pro")
        hardware.device.outputName = ""
        hardware.device.route = .receiver
        await fixture.call.audio.refresh()
        #expect(fixture.call.audio.devices.alternateBuiltInOutput == .speaker)
        await fixture.call.shutdown()
    }

    @Test func joiningDrainsLateMicrophoneTestStartupBeforeAuthorizingOrCreatingMedia() async throws {
        let hardware = TestCallAudioHardware(), gate = CallGate()
        hardware.startGate = gate
        let fixture = CallFixture(hardware: hardware)
        fixture.call.setClientSession(try callLogin())
        let testing = Task { try await fixture.call.startMicrophoneTest() }
        try await eventually { gate.entered }
        let joining = Task { try await fixture.start() }
        try await eventually { fixture.call.phase == .authorizing }
        #expect(fixture.apiCount == 0 && fixture.medias.isEmpty)
        gate.release(); _ = try? await testing.value
        try await joining.value
        try await eventually { fixture.call.phase == .active }
        #expect(!fixture.createdMediaWhileTesting && !hardware.recording && hardware.finishes == 1)
        #expect(fixture.call.audio.testPhase == .idle)
        await fixture.call.shutdown()
    }

    @Test func shutdownAlsoDrainsAProbeWithoutAnyLoginOrCall() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.call.startMicrophoneTest()
        #expect(hardware.recording && fixture.call.hasPendingWork)
        await fixture.call.shutdown()
        #expect(!hardware.recording && !fixture.call.hasPendingWork && fixture.apiCount == 0)
    }

    @Test func aDifferentWindowsDisappearanceDoesNotStopTheProbesOwner() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), owner = UUID()
        try await fixture.call.startMicrophoneTest(owner: owner)
        #expect(fixture.call.audio.cancelTest(owner: UUID()) == nil)
        #expect(hardware.recording)
        await fixture.call.audio.cancelTest(owner: owner)?.value
        #expect(!hardware.recording && fixture.call.audio.testPhase == .idle)
        await fixture.call.shutdown()
    }

    @Test func joiningSuppressesAQueuedLocalSamplePlayback() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        fixture.call.setClientSession(try callLogin())
        try await fixture.call.startMicrophoneTest()
        hardware.finishGate = gate
        fixture.call.audio.cancelTest(playSample: true)
        try await eventually { gate.entered }
        let joining = Task { try await fixture.start() }
        try await eventually { fixture.call.phase == .authorizing }
        gate.release(); try await joining.value
        try await eventually { fixture.call.phase == .active }
        #expect(!hardware.isTestPlaying && !fixture.createdMediaWhileTesting)
        await fixture.call.shutdown()
    }

    @Test func failedProbeCleanupPreventsJoiningUntilRecordingCanBeStopped() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        fixture.call.setClientSession(try callLogin())
        try await fixture.call.startMicrophoneTest()
        hardware.stopFailures = 1
        await #expect(throws: ClientFailure.self) { try await fixture.start() }
        #expect(fixture.call.audio.error?.code == ClientErrorCode.microphoneTestFailed.rawValue)
        #expect(hardware.recording && fixture.medias.isEmpty && fixture.apiCount == 0)
        try await fixture.active()
        #expect(!hardware.recording && !fixture.createdMediaWhileTesting)
        await fixture.call.shutdown()
    }

    @Test func joiningWaitsForAnAlreadyRequestedDeviceChange() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        hardware.changeGate = gate
        let selecting = Task { try await fixture.call.audio.selectInput("test-input") }
        try await eventually { gate.entered }
        let joining = Task { try await fixture.start() }
        try await eventually { fixture.call.phase == .authorizing }
        #expect(fixture.apiCount == 0)
        gate.release(); try await selecting.value; try await joining.value
        try await eventually { fixture.call.phase == .active }
        #expect(fixture.call.audio.devices.inputID == "test-input")
        await fixture.call.shutdown()
    }

    @Test func interruptionRevokesQueuedDataAndDeclinedResumeKeepsAudioBlocked() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        fixture.call.toggleMute()
        try await eventually { !fixture.call.isChangingMicrophone }
        let oldGate = media.gate
        hardware.send(.interrupted)
        #expect(!oldGate.isValid && !fixture.call.isConnected && !fixture.call.canSendChat)
        try await eventually { media.audioSuspended }
        hardware.send(.resumeDeclined)
        #expect(fixture.call.canResumeAudio && group.refreshCount == 0 && !media.microphoneEnabled)
        fixture.call.toggleMute()
        try await eventually { fixture.call.isMuted && !fixture.call.isChangingMicrophone }
        fixture.call.resumeAudio()
        try await eventually { group.refreshCount == 1 }
        try await group.completeRound()
        #expect(fixture.call.isConnected && fixture.call.isMuted && !media.audioSuspended && !media.microphoneEnabled)
        await fixture.call.shutdown()
    }

    @Test func recommendedResumeUsesFreshKeysAndPreservesTheUnmutedIntent() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        fixture.call.toggleMute()
        try await eventually { media.microphoneEnabled && !fixture.call.isChangingMicrophone }
        hardware.send(.interrupted)
        try await eventually { media.audioSuspended }
        hardware.send(.resumeRecommended)
        try await eventually { group.refreshCount == 1 }
        #expect(!fixture.call.isConnected && !media.microphoneEnabled)
        try await group.completeRound()
        #expect(fixture.call.isConnected && !fixture.call.isMuted && media.microphoneEnabled && media.installations == 2)
        await fixture.call.shutdown()
    }

    @Test(arguments: [CallAudioSystemEvent.interrupted, .routeChanged])
    func audioRecoveryCancelsAndDrainsAnInFlightPresetChange(event: CallAudioSystemEvent) async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        let previous = fixture.call.audioPreset
        media.presetGate = gate
        let changing = Task { try await fixture.call.changeAudioPreset(to: previous == .apple ? .webRTC : .apple) }
        try await eventually { gate.entered }
        hardware.send(event)
        #expect(!fixture.call.isConnected && !media.gate.isValid)
        if case .interrupted = event {
            try await eventually { media.audioSuspended }
            hardware.send(.resumeRecommended)
        }
        #expect(group.refreshCount == 0)
        gate.release()
        await #expect(throws: CancellationError.self) { try await changing.value }
        try await eventually { group.refreshCount == 1 }
        try await group.completeRound()
        #expect(fixture.call.isConnected && fixture.call.audioPreset == previous && fixture.call.errorMessage == nil)
        await fixture.call.shutdown()
    }

    @Test func lateAudioResumeCannotAffectTheNextLoginOrCall() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        try await fixture.active()
        let old = try #require(fixture.medias.first)
        old.resumeGate = gate
        hardware.send(.interrupted)
        try await eventually { old.audioSuspended }
        hardware.send(.resumeRecommended)
        try await eventually { gate.entered }
        fixture.call.setClientSession(try callLogin("b"))
        let shutdown = Task { await fixture.call.shutdown() }
        gate.release(); await shutdown.value
        try await fixture.active("room-next")
        #expect(fixture.call.isConnected && fixture.call.isMuted && !old.microphoneEnabled)
        #expect(fixture.call.errorMessage == nil && !fixture.call.canResumeAudio)
        await fixture.call.shutdown()
    }

    @Test func mediaServicesResetCleansTheCallAndRequiresAUserInitiatedRejoin() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        hardware.send(.servicesReset)
        try await eventually { fixture.call.phase == .idle }
        #expect(fixture.call.errorMessage?.code == ClientErrorCode.audioServicesReset.rawValue)
        #expect(fixture.medias.count == 1 && fixture.cleanups.count == 1)
        try await fixture.active()
        #expect(fixture.call.isMuted)
        await fixture.call.shutdown()
    }

    @Test func aSecondInterruptionInvalidatesTheOlderResumeOperation() async throws {
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware), gate = CallGate()
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        hardware.send(.interrupted)
        try await eventually { media.audioSuspended }
        media.resumeGate = gate
        hardware.send(.resumeRecommended)
        try await eventually { gate.entered }
        hardware.send(.interrupted)
        gate.release()
        try await eventually { media.audioSuspended && fixture.call.canResumeAudio }
        #expect(!fixture.call.isConnected && group.refreshCount == 0 && !media.microphoneEnabled)
        hardware.send(.resumeRecommended)
        try await eventually { group.refreshCount == 1 }
        try await group.completeRound()
        #expect(fixture.call.isConnected && fixture.call.isMuted)
        await fixture.call.shutdown()
    }

    @Test func localListeningAndMemberVolumeNeverChangeMicrophoneIntentOrRoomAuthority() async throws {
        let fixture = CallFixture()
        fixture.extraPeers = [diagnosticPeer("private-peer")]
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        fixture.call.toggleMute()
        try await eventually { media.microphoneEnabled && !fixture.call.isChangingMicrophone }
        fixture.call.setMemberVolume(1.5, for: "private-peer")
        #if os(macOS)
        fixture.call.toggleListening()
        #expect(!media.listening && media.volumes["private-peer"] == 1.5)
        #else
        #expect(media.listening && media.volumes["private-peer"] == 1.5)
        #endif
        #expect(media.microphoneEnabled && !fixture.call.isMuted && fixture.call.isConnected)
        fixture.call.setMemberVolume(.nan, for: "private-peer")
        fixture.call.setMemberVolume(1, for: "outsider")
        #expect(fixture.call.memberVolumes["private-peer"] == 1.5 && fixture.call.memberVolumes["outsider"] == nil)
        fixture.call.setMemberVolume(9, for: "private-peer")
        #expect(media.volumes["private-peer"] == 2)
        #if os(macOS)
        fixture.call.toggleListening()
        #endif
        #expect(media.listening && media.volumes["private-peer"] == 2 && !fixture.call.isMuted)
        await fixture.call.shutdown()
    }

    @Test func memberAudioStatesFollowTheirOwnDevicesAcrossPlaybackChangesAndReconnects() async throws {
        let fixture = CallFixture(), peerID = "private-peer"
        fixture.extraPeers = [diagnosticPeer(peerID)]
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        let localID = try #require(fixture.committed.first).participantIdentity
        func member(_ id: String) throws -> CallMember {
            try #require(fixture.call.members.first { $0.id == id })
        }

        #expect(try member(peerID).microphoneEnabled == nil)
        #expect(try member(peerID).listening == nil)
        let snapshots: [CallMediaParticipant] = [
            .init(identity: localID, microphoneEnabled: false, speaking: false, listening: true),
            .init(identity: peerID, microphoneEnabled: true, speaking: true, listening: true),
            .init(identity: "outsider", microphoneEnabled: true, speaking: true, listening: false),
        ]
        media.emit(.participants(snapshots))
        fixture.call.setMemberVolume(0, for: peerID)
        #if os(macOS)
        fixture.call.toggleListening()
        #expect(try member(localID).listening == false)
        #else
        #expect(try member(localID).listening == true)
        #endif
        #expect(try member(localID).microphoneEnabled == false)
        #expect(try member(peerID).isSpeaking)
        #expect(try member(peerID).listening == true)
        #expect(!fixture.call.members.contains { $0.id == "outsider" })

        media.emit(.reconnecting)
        media.emit(.participants(snapshots))
        #expect(try member(peerID).microphoneEnabled == nil)
        #expect(try member(peerID).listening == nil)
        media.emit(.reconnected)
        media.emit(.participants([.init(identity: peerID, microphoneEnabled: false, speaking: false, listening: false)]))
        #if os(macOS)
        fixture.call.toggleListening()
        #endif
        #expect(try member(localID).listening == true)
        #expect(try member(peerID).microphoneEnabled == false)
        #expect(try member(peerID).listening == false)
        await fixture.call.shutdown()
    }

    @Test func oneHealthyTrackCannotMaskAnotherTracksDecryptionProblem() async throws {
        let fixture = CallFixture()
        fixture.extraPeers = [diagnosticPeer("private-a"), diagnosticPeer("private-b")]
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        media.emit(.participants([.init(identity: "private-a", microphoneEnabled: true, speaking: false, listening: nil), .init(identity: "private-b", microphoneEnabled: true, speaking: false, listening: nil)]))
        media.emit(.trackDiagnostics([diagnosticTrack("private-a", id: "a", encryption: .decryptionFailed), diagnosticTrack("private-b", id: "b")]))
        #expect(fixture.call.audioStatus(for: "private-a") == .decryptionProblem)
        #expect(fixture.call.audioStatus(for: "private-b") == .verified)
        let message: LocalizedMessage = "有 \(1) 个音轨等待恢复解密"
        #expect(fixture.call.encryptionStatus == message)
        #expect(fixture.call.isConnected)
        await fixture.call.shutdown()
    }

    @Test func missingTracksMutedPeersAndNonProgressingOldPacketsDoNotTriggerRekeys() async throws {
        let fixture = CallFixture()
        fixture.extraPeers = [diagnosticPeer("private-peer")]
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        media.emit(.participants([.init(identity: "private-peer", microphoneEnabled: false, speaking: false, listening: nil)]))
        #expect(fixture.call.audioStatus(for: "private-peer") == .noTrack)
        media.emit(.trackDiagnostics([diagnosticTrack("private-peer", encryption: .missingKey, muted: true)]))
        #expect(fixture.call.audioStatus(for: "private-peer") == .muted)
        fixture.now = fixture.now.advanced(by: .seconds(10))
        media.emit(.trackDiagnostics([diagnosticTrack("private-peer", encryption: .decryptionFailed)]))
        fixture.now = fixture.now.advanced(by: .seconds(10))
        media.emit(.trackDiagnostics([diagnosticTrack("private-peer", encryption: .decryptionFailed)]))
        #expect(group.refreshCount == 0 && fixture.call.isConnected)
        await fixture.call.shutdown()
    }

    @Test func subscriptionAndNetworkProblemsDoNotAppearAsDecryptionFailures() async throws {
        let fixture = CallFixture()
        fixture.extraPeers = [diagnosticPeer("private-peer")]
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        media.emit(.participants([.init(identity: "private-peer", microphoneEnabled: true, speaking: false, listening: nil)]))
        var track = diagnosticTrack("private-peer", encryption: .decryptionFailed)
        track.subscribed = false
        media.emit(.trackDiagnostics([track]))
        #expect(fixture.call.audioStatus(for: "private-peer") == .notSubscribed)
        track.subscriptionFailed = true
        media.emit(.trackDiagnostics([track]))
        #expect(fixture.call.audioStatus(for: "private-peer") == .subscriptionProblem)
        track.quality = .lost
        media.emit(.trackDiagnostics([track]))
        #expect(fixture.call.audioStatus(for: "private-peer") == .networkProblem)
        fixture.now = fixture.now.advanced(by: .seconds(10)); track.packetsReceived = 100
        media.emit(.trackDiagnostics([track]))
        #expect(group.refreshCount == 0)
        await fixture.call.shutdown()
    }

    @Test func persistentDecryptFailureHasABoundedRecoveryBudget() async throws {
        let fixture = CallFixture()
        fixture.extraPeers = [diagnosticPeer("private-peer")]
        try await fixture.active()
        let media = try #require(fixture.medias.first), group = try #require(fixture.groups.first)
        for attempt in 0..<3 {
            media.emit(.trackDiagnostics([diagnosticTrack("private-peer", encryption: .decryptionFailed, packets: 10)]))
            fixture.now = fixture.now.advanced(by: .seconds(6))
            media.emit(.trackDiagnostics([diagnosticTrack("private-peer", encryption: .decryptionFailed, packets: 20)]))
            if attempt < 2 {
                try await eventually { group.refreshCount == attempt + 1 }
                try await group.completeRound()
                #expect(fixture.call.isConnected)
            }
        }
        try await eventually { fixture.call.phase == .idle }
        #expect(group.refreshCount == 2 && fixture.call.errorMessage?.code == ClientErrorCode.audioDecryptionRecoveryFailed.rawValue)
        await fixture.call.shutdown()
    }

    @Test func diagnosticSampleUsesAnAllowlistAndAnonymousTrackNumbers() async throws {
        let logs = try ClientLogFixture(enabled: true)
        let hardware = TestCallAudioHardware(), fixture = CallFixture(hardware: hardware, log: logs.log)
        fixture.extraPeers = [diagnosticPeer("private-peer-identity")]
        hardware.device.inputName = "Private microphone name"; hardware.device.inputID = "private-device-uid"
        await fixture.call.audio.refresh()
        try await fixture.active()
        let media = try #require(fixture.medias.first)
        var track = diagnosticTrack("private-peer-identity", id: "private-track-sid")
        track.jitterMS = .nan; track.roundTripMS = .infinity
        media.emit(.trackDiagnostics([diagnosticTrack("unlisted-peer")]))
        #expect(!(try await logs.callEvents()).contains { $0.event == .firstRemoteDecryption })
        media.emit(.trackDiagnostics([track]))
        media.emit(.trackDiagnostics([track]))
        #expect((try await logs.callEvents()).filter { $0.event == .firstRemoteDecryption }.count == 1)
        let data = try await logs.log.export()
        let samples = try logs.rows(data, "SELECT details FROM call WHERE event='trackSample' ORDER BY seq")
        let text = try #require(samples.last?.first)
        let report = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        for secret in ["private-peer-identity", "private-track-sid", "private-device-uid", "Private microphone name", "Private Name", fixture.call.clientSession!.credential, "rtc.example.com"] {
            #expect(data.range(of: Data(secret.utf8)) == nil)
        }
        let tracks = try #require(report["tracks"] as? [[String: Any]])
        #expect(tracks.count == 1 && tracks[0]["number"] as? Int == 1)
        #expect(tracks[0]["jitterMS"] == nil && tracks[0]["roundTripMS"] == nil)
        #expect(report["schema"] as? Int == 1)
        await fixture.call.shutdown()
    }
}

@MainActor
private final class RealGroupCallAPI: CallRoomAPI {
    let endpoint: URL
    let login: ClientSession
    var sequence: Int64 = 0
    init(endpoint: URL, login: ClientSession) { self.endpoint = endpoint; self.login = login }
    func joinSequence(for login: ClientSession) async throws -> Int64 { sequence }
    func freshMediaToken(_ admission: RoomAdmission) async throws -> String { "synthetic-fresh-token" }
    func authorizeRoom(roomID: String, sequence: Int64, login: ClientSession, password: String?) async throws -> JoinResponse {
        self.sequence = sequence
        let entry = "entry_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        var request = URLRequest(url: endpoint.appendingPathComponent("test/admission")); request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["member_id": login.member.id, "room_id": roomID, "entry_id": entry, "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(login.deviceIdentity))])
        let (_, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 204 else { throw ClientFailure(.invalidAdmission) }
        return JoinResponse(livekitURL: "wss://unused.example", roomID: roomID, displayName: "Lifecycle",
            entryID: entry, joinSequence: sequence, admissionExpiresAt: Int64(Date().timeIntervalSince1970) + 30,
            participantIdentity: login.participantIdentity + "." + entry, token: "synthetic",
            keyProtocol: VoiceRooms.keyProtocol, mediaTransport: "udp", e2eeRequired: true)
    }
    func leave(_ admission: RoomAdmission) async throws {}
    nonisolated func close() {}
}

@Test(.enabled(if: ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"] != nil))
@MainActor func callLifecycleRealGroupIntegration() async throws {
    guard let value = ProcessInfo.processInfo.environment["CHIRP_GROUP_TEST_URL"], let endpoint = URL(string: value) else { return }
    let identity = try testIdentityStore("group-peer-03")
    try await trustFixtureRoom(identity, url: endpoint, roomID: "lifecycle-room")
    let login = try ClientSession(data: JSONSerialization.data(withJSONObject: [
        "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(identity.requireDevice())),
        "member": ["id": "member03", "display_name": "Peer 3"],
        "credential": "chirp_03" + String(repeating: "a", count: 41),
        "participant_identity": "member03.login_test", "expires_at": Int(Date().timeIntervalSince1970) + 3600,
    ]), connection: ServerConnection(apiURL: endpoint, passkeyOrigin: testServerConnection.passkeyOrigin))
    let api = RealGroupCallAPI(endpoint: endpoint, login: login)
    let media = TestCallMedia(event: { _ in })
    var receive: (@MainActor (CallMediaEvent) -> Void)?
    let dependencies = CallDependencies(authorizeIdentity: { true }, prepare: {}, makeAPI: { _ in api }, makeMedia: { _, callback in
        receive = callback; media.verifyNativeKeys = true; return media
    }, makeGroup: { login, admission, callbacks in
        try GroupSession(baseURL: login.connection.endpoints.groupBaseURL, login: login, admission: admission, identity: identity,
            onPause: callbacks.pause, onInstall: callbacks.install, onReady: callbacks.ready, onFailure: callbacks.failed,
            approveRoster: { _ in V5Crypto.hash(Data("verified fixture roster".utf8)) },
            authorizationDeadline: { .now.advanced(by: .seconds(60)) }, authorizeMedia: callbacks.authorizeMedia)
    }, validateAudioPreset: { _ in })
    let call = CallController(dependencies: dependencies)
    call.setClientSession(login)
    do {
        try await call.startJoin(room: .loading(id: "lifecycle-room"))
        try await eventually { call.phase == .active }
        let firstKeys = media.senderKeys
        #expect(firstKeys.count == 1 && firstKeys.values.allSatisfy { $0.count == 32 })
        call.setChatDraft("preserve across rekey", entryID: call.chat.admission?.entryID)
        media.isConnected = false; receive?(.reconnecting)
        #expect(call.phase == .recovering && !call.isConnected)
        media.isConnected = true; receive?(.reconnected)
        try await eventually { call.phase == .active && media.senderKeys != firstKeys }
        #expect(call.chat.draft == "preserve across rekey" && call.isMuted)
        #expect(!media.microphoneEnabled && call.errorMessage == nil)
        await call.shutdown()
        #expect(call.phase == .idle && !call.hasPendingWork && media.senderKeys.isEmpty)
    } catch {
        await call.shutdown()
        throw error
    }
}

private final class EmptyIdentityURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
@Test @MainActor func authenticatedSoloRoomConnectsMutedShowsOwnNameAndCanLeave() async throws {
    let fixture = CallFixture(); let certificate = try V5TestIdentity("solo-authenticated")
    fixture.registeredFixture = certificate
    let identity = try testIdentityStore("solo-authenticated", fixture: certificate)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [IdentityBusURLProtocol.self]
    let social = SocialIdentity(identity: identity, persistence: MemoryIdentityPersistence(), configuration: configuration, authority: IdentityBusURLProtocol.authorityConfiguration)
    let room = RoomIdentity(identity: identity, social: social, configuration: configuration)
    let login = try ClientSession(data: JSONSerialization.data(withJSONObject: ["member": ["id": "member_test", "display_name": "Fixture"], "credential": "chirp_" + String(repeating: "a", count: 43), "participant_identity": "member_test.login_a", "expires_at": Date().timeIntervalSince1970 + 3600, "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(certificate.device))]), connection: testServerConnection, expectedDevice: certificate.device)
    try IdentityBusURLProtocol.register(certificate)
    IdentityBusURLProtocol.state.withLock { $0.accounts[login.credential] = (login.member.id, certificate.device) }
    social.reset(for: login); defer { social.reset(for: nil) }
    try await eventually { social.voiceAllowed }
    fixture.call.setClientSession(login); fixture.call.roomIdentity = room
    try await fixture.active()
    let media = try #require(fixture.medias.first)
    #expect(fixture.medias.count == 1 && media.connectCount == 1 && media.installations == 1)
    #expect(room.trust == .solo && fixture.call.hasSession && fixture.call.isConnected)
    #expect(fixture.call.isMuted && !media.microphoneEnabled && fixture.microphoneAccessRequests == 0)
    #expect(fixture.call.members.count == 1 && fixture.call.members.first?.name == "Fixture")
    #expect(fixture.call.members.first?.identityVerified == true)
    fixture.call.updateProfileNames([login.member.id: "柚子"])
    #expect(fixture.call.members.first?.name == "柚子")
    #expect(fixture.call.showsChat(in: "friends"))
    fixture.call.setChatDraft("Hello", entryID: fixture.call.chat.admission?.entryID)
    fixture.call.sendChat()
    try await eventually { fixture.call.chat.messages.last?.delivery == .sent }
    #expect(fixture.call.chat.messages.last?.senderName == "柚子")
    fixture.call.toggleMute()
    try await eventually { !fixture.call.isChangingMicrophone }
    #expect(!fixture.call.isMuted && media.microphoneEnabled && fixture.microphoneAccessRequests == 1)
    fixture.call.leave()
    #expect(!fixture.call.hasSession && fixture.call.currentRoomID == nil)
    await fixture.call.shutdown()
    #expect(media.stopped && fixture.cleanups.count == 1)
    #expect(fixture.call.phase == .idle && !fixture.call.hasPendingWork && fixture.call.errorMessage == nil)
}

@Test @MainActor func authenticatedRoomSurvivesSoloRotationsAndRepeatedPeerArrivals() async throws {
    let fixture = CallFixture(); fixture.smoothRotation = true
    let certificate = try V5TestIdentity("solo-rounds"); fixture.registeredFixture = certificate
    let identity = try testIdentityStore("solo-rounds", fixture: certificate)
    let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [IdentityBusURLProtocol.self]
    let social = SocialIdentity(identity: identity, persistence: MemoryIdentityPersistence(), configuration: configuration, authority: IdentityBusURLProtocol.authorityConfiguration)
    let verificationGate = CallGate()
    defer { verificationGate.release() }
    let room = RoomIdentity(identity: identity, social: social, configuration: configuration, security: { native, parameters in
        let data = try await native.security(parameters)
        if parameters["action"] == "sas_start" { await verificationGate.wait() }
        return data
    })
    let login = try ClientSession(data: JSONSerialization.data(withJSONObject: ["member": ["id": "member_test", "display_name": "Fixture"], "credential": "chirp_" + String(repeating: "a", count: 43), "participant_identity": "member_test.login_a", "expires_at": Date().timeIntervalSince1970 + 3600, "device_identity": JSONSerialization.jsonObject(with: JSONEncoder().encode(certificate.device))]), connection: testServerConnection, expectedDevice: certificate.device)
    try IdentityBusURLProtocol.register(certificate)
    IdentityBusURLProtocol.state.withLock { $0.accounts[login.credential] = (login.member.id, certificate.device) }
    social.reset(for: login); defer { social.reset(for: nil) }
    try await eventually { social.voiceAllowed }
    fixture.call.setClientSession(login); fixture.call.roomIdentity = room
    try await fixture.active()
    let group = try #require(fixture.groups.first)
    let media = try #require(fixture.medias.first)
    let local = try #require(room.peer(for: group.admission.identity))
    let remote = try V5TestIdentity("solo-rounds-remote"), remoteID = "member_remote.login_test.entry_test"
    let policy = V5RoomPolicy.mutual(origin: ServerAddress.identityOrigin(testServerConnection.passkeyOrigin), roomID: "friends")
    let peer = MLSPeer(identity: remoteID, name: "Remote", publicKey: remote.device.leafKey, keyPackage: "", binding: try remote.binding(policy: policy, identity: remoteID, mlsKey: remote.device.leafKey))
    for arrival in 1...2 {
        // Solo rotations use the same live transport as subsequent peers.
        try await group.callbacks.prepare?(group.native, [local], 1)
        try await group.callbacks.switchKeys?(1)
        try await group.callbacks.retireKeys?(0)
        #expect(media.preparedRotations == arrival && media.switchedRotations == arrival)
        #expect(fixture.call.isConnected && fixture.call.hasSession && !media.stopped)
        fixture.call.toggleMute()
        try await eventually { !fixture.call.isChangingMicrophone }
        #expect(!fixture.call.isMuted && media.microphoneEnabled)
        group.extraPeers = [peer]
        try await group.completeRound()
        #expect(media.isConnected && media.connectCount == 1 && media.installations == arrival)
        #expect(fixture.mediaTokenRequests == 0 && room.trust == .pending)
        #expect(fixture.call.phase == .verifying && !fixture.call.isBusy && fixture.call.isMuted && !media.microphoneEnabled)
        #expect(fixture.call.status == "等待身份核验" && !fixture.call.canSendChat && !fixture.call.canSendAttachment)
        #expect(fixture.call.members.first(where: { $0.id == remoteID })?.name == (arrival == 1 ? "Remote" : "朋友 B 😀"))
        fixture.call.updateProfileNames([login.member.id: "柚子", "member_remote": "朋友 B 😀"])
        #expect(fixture.call.members.first(where: { $0.id == local.identity })?.name == "柚子")
        #expect(fixture.call.members.first(where: { $0.id == remoteID })?.name == "朋友 B 😀")
        #expect(fixture.call.members.first(where: { $0.id == remoteID })?.identityVerified == false)
        group.extraPeers = []
        try await group.completeRound()
        #expect(!media.stopped && media.isConnected && fixture.medias.count == 1)
        #expect(media.installations == arrival + 1)
        #expect(room.trust == .solo && fixture.call.phase == .active)
        #expect(fixture.call.currentRoomID == "friends" && fixture.call.hasSession && fixture.call.isConnected && fixture.call.isMuted)
    }
    // A terminal disconnect while the SAS sheet is open clears all visible
    // connection/verification state and allows application shutdown to finish.
    group.extraPeers = [peer]
    try await group.completeRound()
    let startingVerification = Task { await room.startVerification(peer) }
    try await eventually { verificationGate.entered }
    #expect(room.verification != nil && fixture.call.phase == .verifying)
    await group.callbacks.failed(ClientFailure(.groupMembershipLost))
    verificationGate.release(); await startingVerification.value
    #expect(room.verification == nil && !fixture.call.hasSession && fixture.call.currentRoomID == nil)
    #expect(fixture.call.encryptionStatus == "未连接" && fixture.call.members.isEmpty)
    await fixture.call.shutdown()
    #expect(fixture.call.phase == .idle && !fixture.call.hasPendingWork && media.stopped)
    #expect(fixture.call.errorMessage?.code == ClientErrorCode.groupMembershipLost.rawValue)
}

#if canImport(LiveKit)
@Test @MainActor func productionMediaCanPauseBeforeConnectingWithoutAuthorizingSending() async throws {
    let media = LiveKitCallMedia(preset: .defaultPreset, event: { _ in })
    try await media.pause()
    try await media.pause()
    #expect(!media.isConnected && !media.hasMicrophone)
    #expect(throws: (any Error).self) {
        try media.encryptedSender(deadline: .now.advanced(by: .seconds(3)), loginExpiresAt: Date().addingTimeInterval(60))
    }
    await media.stop()
    await #expect(throws: (any Error).self) { try await media.pause() }
}
#endif

#if os(iOS) && !SWIFT_PACKAGE
@MainActor
struct IOSRoomControlLayoutTests {
    @Test func bluetoothNamesFitTheSameControlBarAsTheBuiltInRoutes() async throws {
        let hardware = TestCallAudioHardware()
        hardware.device.supportsReceiver = true
        hardware.device.route = .receiver
        let fixture = CallFixture(hardware: hardware)
        try await fixture.active()
        let call = try #require(fixture.call)
        defer { call.leave() }
        await call.audio.refresh()

        let controls = CallControlsView(call: call, room: .loading(id: "friends"))
            .environment(\.locale, AppLanguage.simplifiedChinese.locale)
        let host = UIHostingController(rootView: controls)
        let proposal = CGSize(width: 327, height: CGFloat.greatestFiniteMagnitude)
        let builtInHeight = host.sizeThatFits(in: proposal).height
        #expect(builtInHeight >= 44)

        for name in ["AirPods Pro", "Mira’s Bluetooth Headphones Pro Max"] {
            hardware.device.route = .bluetooth
            hardware.device.outputName = name
            await call.audio.refresh()
            await Task.yield()
            let bluetoothHeight = host.sizeThatFits(in: proposal).height
            #expect(abs(bluetoothHeight - builtInHeight) <= 1)
            #expect(call.isListening && call.isMuted && fixture.microphoneAccessRequests == 0)
        }
    }
}
#endif

#if os(macOS) && !SWIFT_PACKAGE
@Suite(.serialized) @MainActor
struct MacRoomControlLayoutTests {
    @Test(arguments: [AppLanguage.simplifiedChinese, .english])
    func controlsStayCenteredInTheVisibleRoom(_ language: AppLanguage) async throws {
        let suiteName = "ChirpRoomControlTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fixture = CallFixture(defaults: defaults)
        let call = try #require(fixture.call)
        defer { call.leave() }
        let directory = RoomDirectory()
        let login = try callLogin()
        call.setClientSession(login)
        directory.reset(for: login)
        let room = RoomOverview(roomID: "friends", displayName: "朋友客厅", keyProtocol: VoiceRooms.keyProtocol,
                                maxParticipants: 0, participants: [], mediaStatus: "available", passwordRequired: false)
        directory.apply([room], credential: login.credential)
        var openedSettings = false
        let page = MacClientView(call: call, directory: directory, memberID: "local", memberName: "Mira",
                                 logout: {}, showAudioSettings: { openedSettings = true })
            .environment(\.locale, language.locale)
            .environment(\.accessibilityEnabled, true)
        let host = NSHostingView(rootView: page)
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 720),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: language == .english ? .darkAqua : .aqua)
        window.contentView = host
        window.orderBack(nil)
        defer { window.orderOut(nil) }

        // SwiftUI button nodes expose the AppKit accessibility selectors without
        // adopting the full NSAccessibilityProtocol used by AppKit controls.
        func elements() -> [String: AnyObject] {
            host.layoutSubtreeIfNeeded()
            var pending: [AnyObject] = [host, window]
            var result: [String: AnyObject] = [:]
            var seen = Set<ObjectIdentifier>()
            while let node = pending.popLast() {
                guard seen.insert(ObjectIdentifier(node)).inserted else { continue }
                if let id = node.accessibilityIdentifier?() { result[id] = node }
                pending += (node.accessibilityChildren?() ?? []).map { $0 as AnyObject }
            }
            return result
        }

        let ids = ["toggle-microphone", "toggle-call-listening", "audio-preset-settings", "leave-call"]
        func frame(_ id: String, in controls: [String: AnyObject]) throws -> NSRect {
            let control = try #require(controls[id], "Missing \(id) among \(controls.keys.sorted())")
            return window.convertFromScreen(try #require(control.accessibilityFrame?()))
        }

        func centeredFrames(_ buttonIDs: [String]) throws -> [NSRect] {
            let controls = elements()
            let room = try frame("voice-room-content", in: controls)
            let buttons = try buttonIDs.map { try frame($0, in: controls) }
            let group = buttons.reduce(NSRect.null) { $0.union($1) }
            #expect(abs(group.midX - room.midX) <= 1)
            #expect(group.minX >= room.minX && group.maxX <= room.maxX)
            for (left, right) in zip(buttons, buttons.dropFirst()) {
                #expect(left.maxX < right.minX && abs(left.midY - right.midY) <= 1)
            }
            return buttons
        }

        func press(_ id: String) throws {
            let control = try #require(elements()[id])
            #expect(control.isAccessibilityEnabled?() == true)
            _ = control.accessibilityPerformPress?()
        }

        try await eventually { elements()["join-call"] != nil }
        #expect(Set(ids).isDisjoint(with: elements().keys))
        _ = try centeredFrames(["join-call"])
        try press("join-call")
        try await eventually { call.isConnected && elements()["leave-call"] != nil }
        let initial = try centeredFrames(ids)
        for width: CGFloat in [900, 1120, 1280, 1520, 900] {
            window.setContentSize(NSSize(width: width, height: 720))
            await Task.yield()
            window.displayIfNeeded()
            let updated = try centeredFrames(ids)
            for (button, original) in zip(updated, initial) {
                #expect(button.width >= 44 && button.height >= 44)
                #expect(abs(button.minY - original.minY) <= 1)
            }
        }

        try press("toggle-microphone")
        try await eventually { !call.isMuted && !call.isChangingMicrophone }
        try press("toggle-call-listening")
        #expect(!call.isListening && !call.isMuted)
        try press("audio-preset-settings")
        #expect(openedSettings)
        try press("toggle-room-chat")
        try await eventually { elements()["room-chat-send"] == nil }
        let withoutChat = try centeredFrames(ids)
        #expect(withoutChat[0].midX > initial[0].midX)
        try press("toggle-room-chat")
        try await eventually { elements()["room-chat-send"] != nil }
        try press("toggle-call-listening")
        #expect(call.isListening && !call.isMuted)
        try press("toggle-microphone")
        try await eventually { call.isMuted && !call.isChangingMicrophone }
        #expect(try centeredFrames(ids) == initial)
        try press("leave-call")
        try await eventually { !call.hasSession && elements()["join-call"] != nil }
        #expect(Set(ids).isDisjoint(with: elements().keys))
        _ = try centeredFrames(["join-call"])
    }
}
#endif
