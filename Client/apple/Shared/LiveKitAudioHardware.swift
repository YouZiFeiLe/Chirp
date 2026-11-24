import AVFoundation
import Foundation
import LiveKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// SDK device access and blocking track-volume setters share a dedicated queue.
enum CallAudioQueue {
    private static let queue = DispatchQueue(label: "cn.youzifeile.chirp.audio-control")
    static func perform<T: Sendable>(_ action: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result(catching: action)) }
        }
    }
}

private final class MicrophoneRenderer: NSObject, AudioRenderer, @unchecked Sendable {
    let sample = MicrophoneSample()
    func render(pcmBuffer: AVAudioPCMBuffer) {
        let count = Int(pcmBuffer.frameLength), channels = Int(pcmBuffer.format.channelCount)
        guard count > 0, count <= 8_192, channels > 0 else { return }
        let stride = pcmBuffer.format.isInterleaved ? channels : 1
        let values: [Float]
        if let input = pcmBuffer.floatChannelData?[0] {
            values = (0..<count).map { input[$0 * stride] }
        } else if let input = pcmBuffer.int16ChannelData?[0] {
            values = (0..<count).map { Float(input[$0 * stride]) / 32_768 }
        } else { return }
        sample.append(values, sampleRate: Int(pcmBuffer.format.sampleRate))
    }
}

@MainActor
final class LiveKitAudioHardware: CallAudioHardware {
    var onEvent: (@MainActor @Sendable (CallAudioEvent) -> Void)?
    private var observers: [(NotificationCenter, any NSObjectProtocol)] = []
    private var previous: CallAudioSnapshot?
    private var snapshotRevision: UInt64 = 0
    private var preferredInput = "system"
    private var preferredOutput = "system"
    private var fallback = false
    private var probe: MicrophoneRenderer?
    private var captureContext: ChirpLocalAudioCapture?
    private var recording = false
    private var changingRoute = false
    #if os(iOS)
    private var outputPreference: CallAudioOutput = .system
    #endif
    private var captureProcessor: CaptureAudioProcessor?
    private var voiceActivation = VoiceActivationControl()
    private var player: AVAudioPlayer?
    private var sampleData = Data()
    private var releasePlayback: (() -> Void)?
    private let makeTestPlayer: (Data) throws -> AVAudioPlayer
    private let presenceSounds = RoomPresenceSounds()
    #if os(macOS)
    private var preparedDevices = false
    private var preparingDevices: Task<Void, Error>?
    #endif
    var isTestPlaying: Bool { player?.isPlaying == true }

    func setVoiceActivation(_ control: VoiceActivationControl) { voiceActivation = control }

    func acquireSettingsSession() throws -> () -> Void {
        #if os(iOS)
        // No player, capture, or room: own only session activation so manual
        // receiver/speaker choices remain effective while settings are visible.
        let requirement = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)
        return { try? requirement.release() }
        #else
        return {}
        #endif
    }

    init(makeTestPlayer: @escaping (Data) throws -> AVAudioPlayer = { try AVAudioPlayer(data: $0) }) {
        self.makeTestPlayer = makeTestPlayer
        AudioManager.shared.onDeviceUpdate = { [weak self] _ in Task { @MainActor [weak self] in await self?.refresh() } }
        #if os(iOS)
        observe(AVAudioSession.routeChangeNotification) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        observe(AVAudioSession.availableInputsChangeNotification) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh() }
        }
        observe(AVAudioSession.didBecomeInactiveNotification) { [weak self] notification in
            guard let context = notification.userInfo?[AVAudioSession.deactivationContextKey] as? AVAudioSession.DeactivationContext,
                  context.source == .system else { return }
            Task { @MainActor [weak self] in self?.onEvent?(.system(.interrupted)) }
        }
        observe(AVAudioSession.resumptionRecommendationNotification) { [weak self] notification in
            guard let context = notification.userInfo?[AVAudioSession.resumptionContextKey] as? AVAudioSession.ResumptionContext else { return }
            let event: CallAudioSystemEvent = context.recommendation == .shouldResume ? .resumeRecommended : .resumeDeclined
            Task { @MainActor [weak self] in self?.onEvent?(.system(event)) }
        }
        for name in [AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observe(name) { [weak self] _ in Task { @MainActor [weak self] in self?.onEvent?(.system(.servicesReset)) } }
        }
        #elseif os(macOS)
        observe(NSWorkspace.willSleepNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] _ in
            Task { @MainActor [weak self] in self?.onEvent?(.system(.interrupted)) }
        }
        observe(NSWorkspace.didWakeNotification, center: NSWorkspace.shared.notificationCenter) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.refresh(); self?.onEvent?(.system(.resumeRecommended)) }
        }
        #endif
    }

    isolated deinit {
        for (center, token) in observers { center.removeObserver(token) }
        AudioManager.shared.onDeviceUpdate = nil
        player?.stop(); releasePlayback?()
        presenceSounds.stop()
        _ = probe?.sample.finish(includeSample: false)
    }

    private func observe(_ name: Notification.Name, center: NotificationCenter = .default,
                         action: @escaping @Sendable (Notification) -> Void) {
        observers.append((center, center.addObserver(forName: name, object: nil, queue: .main, using: action)))
    }

    func refresh() async {
        guard !changingRoute else { return }
        #if os(macOS)
        do { try await prepareDevices() }
        catch { onEvent?(.failed(ClientFailure(.audioDeviceChangeFailed))); return }
        #endif
        snapshotRevision &+= 1
        let revision = snapshotRevision
        var snapshot: CallAudioSnapshot
        #if os(macOS)
        let input = preferredInput, output = preferredOutput
        guard let result = try? await CallAudioQueue.perform({
            let manager = AudioManager.shared
            var snapshot = CallAudioSnapshot()
            let inputs = manager.inputDevices, outputs = manager.outputDevices
            snapshot.inputs = inputs.filter { !$0.isDefault && !$0.deviceId.isEmpty }.map { .init(id: $0.deviceId, name: $0.name) }
            snapshot.outputs = outputs.filter { !$0.isDefault && !$0.deviceId.isEmpty }.map { .init(id: $0.deviceId, name: $0.name) }
            snapshot.inputID = snapshot.inputs.contains(where: { $0.id == input }) ? input : "system"
            snapshot.outputID = snapshot.outputs.contains(where: { $0.id == output }) ? output : "system"
            snapshot.inputName = inputs.first { input == "system" ? $0.isDefault : $0.deviceId == input }?.name ?? ""
            snapshot.outputName = outputs.first { output == "system" ? $0.isDefault : $0.deviceId == output }?.name ?? ""
            snapshot.route = .other
            return snapshot
        }) else { return }
        guard revision == snapshotRevision, input == preferredInput, output == preferredOutput else { return }
        if input != "system", !result.inputs.contains(where: { $0.id == input }) {
            do { try await selectInput("system"); fallback = true; await refresh() }
            catch {
                if input == preferredInput, output == preferredOutput { onEvent?(.devices(result)) }
                onEvent?(.failed(ClientFailure(.audioDeviceChangeFailed)))
            }
            return
        }
        if output != "system", !result.outputs.contains(where: { $0.id == output }) {
            do { try await selectOutput("system"); fallback = true; await refresh() }
            catch {
                if input == preferredInput, output == preferredOutput { onEvent?(.devices(result)) }
                onEvent?(.failed(ClientFailure(.audioDeviceChangeFailed)))
            }
            return
        }
        snapshot = result
        #else
        let session = AVAudioSession.sharedInstance()
        snapshot = CallAudioSnapshot()
        snapshot.inputs = (session.availableInputs ?? []).map {
            .init(id: $0.uid, name: $0.portName, route: Self.routeKind($0.portType))
        }
        if preferredInput != "system", !snapshot.inputs.contains(where: { $0.id == preferredInput }) {
            do { try session.setPreferredInput(nil); snapshot.fellBackToDefault = true }
            catch { onEvent?(.failed(ClientFailure(.audioDeviceChangeFailed))) }
        }
        let input = session.preferredInput?.uid
        if let input, snapshot.inputs.contains(where: { $0.id == input }) { snapshot.inputID = input }
        let currentRoute = session.currentRoute
        snapshot.activeInputID = currentRoute.inputs.first?.uid
        snapshot.inputName = currentRoute.inputs.first?.portName ?? ""
        snapshot.outputName = currentRoute.outputs.first?.portName ?? ""
        snapshot.route = Self.routeKind(currentRoute.outputs.first?.portType)
        snapshot.supportsReceiver = UIDevice.current.userInterfaceIdiom == .phone
        #endif
        guard revision == snapshotRevision else { return }
        if snapshot.fellBackToDefault { preferredInput = snapshot.inputID; preferredOutput = snapshot.outputID; fallback = true }
        snapshot.fellBackToDefault = fallback
        let changed = previous.map {
            $0.inputID != snapshot.inputID || $0.outputID != snapshot.outputID ||
            $0.inputName != snapshot.inputName || $0.outputName != snapshot.outputName || $0.route != snapshot.route
        } ?? false
        previous = snapshot
        #if os(macOS)
        presenceSounds.setOutputDeviceID(snapshot.outputID == "system" ? nil : snapshot.outputID)
        #endif
        onEvent?(.devices(snapshot))
        if changed { onEvent?(.system(.routeChanged)) }
    }

    func selectInput(_ id: String) async throws {
        #if os(macOS)
        try await prepareDevices()
        #endif
        let previous = preferredInput
        preferredInput = id; snapshotRevision &+= 1
        var succeeded = false
        defer { if !succeeded, preferredInput == id { preferredInput = previous } }
        #if os(macOS)
        try await CallAudioQueue.perform {
            let manager = AudioManager.shared
            guard let device = id == "system" ? manager.defaultInputDevice : manager.inputDevices.first(where: { $0.deviceId == id }) else {
                throw ClientFailure(.audioDeviceChangeFailed)
            }
            try manager.chirpSelectAudioDevice(device, input: true)
        }
        #else
        changingRoute = true
        defer { changingRoute = false }
        let output = outputPreference
        let keptOutput = try await CallAudioQueue.perform {
            let session = AVAudioSession.sharedInstance()
            let previousInput = session.preferredInput
            let routing = AudioManager.shared.audioSession
            try routing.chirpSetSpeakerOutputOverride(Self.speakerOverride(output), inputSelected: id != "system")
            do {
                let input = id == "system" ? nil : session.availableInputs?.first { $0.uid == id }
                guard id == "system" || input != nil else { throw ClientFailure(.audioDeviceChangeFailed) }
                // Headset input selects its paired output. Keep an input-capable
                // session while listening, without starting microphone capture.
                let nextOutput: CallAudioOutput = input?.portType == .builtInMic ? output : .system
                try routing.chirpSetSpeakerOutputOverride(Self.speakerOverride(nextOutput), inputSelected: id != "system")
                if session.category == .playAndRecord {
                    try session.overrideOutputAudioPort(nextOutput == .speaker ? .speaker : .none)
                }
                try session.setPreferredInput(input)
                return nextOutput
            } catch {
                try? routing.chirpSetSpeakerOutputOverride(Self.speakerOverride(output), inputSelected: previousInput != nil)
                try? session.setPreferredInput(previousInput)
                if session.category == .playAndRecord {
                    try? session.overrideOutputAudioPort(output == .speaker ? .speaker : .none)
                }
                throw error
            }
        }
        outputPreference = keptOutput
        #endif
        preferredInput = id; fallback = false
        succeeded = true
    }

    func selectOutput(_ id: String) async throws {
        #if os(macOS)
        presenceSounds.stop()
        try await prepareDevices()
        let previous = preferredOutput
        preferredOutput = id; snapshotRevision &+= 1
        var succeeded = false
        defer { if !succeeded, preferredOutput == id { preferredOutput = previous } }
        try await CallAudioQueue.perform {
            let manager = AudioManager.shared
            guard let device = id == "system" ? manager.defaultOutputDevice : manager.outputDevices.first(where: { $0.deviceId == id }) else {
                throw ClientFailure(.audioDeviceChangeFailed)
            }
            try manager.chirpSelectAudioDevice(device, input: false)
        }
        preferredOutput = id; fallback = false
        presenceSounds.setOutputDeviceID(id == "system" ? nil : id)
        succeeded = true
        #else
        throw ClientFailure(.audioControlUnavailable)
        #endif
    }

    func preferOutput(_ output: CallAudioOutput) async throws {
        #if os(iOS)
        guard output != .receiver || UIDevice.current.userInterfaceIdiom == .phone else {
            throw ClientFailure(.audioDeviceChangeFailed)
        }
        changingRoute = true; snapshotRevision &+= 1
        defer { changingRoute = false }
        let previous = outputPreference
        let inputID = try await CallAudioQueue.perform {
            let session = AVAudioSession.sharedInstance()
            let previousInput = session.preferredInput
            try AudioManager.shared.audioSession.chirpSetSpeakerOutputOverride(Self.speakerOverride(output))
            do {
                if session.category == .playAndRecord {
                    try session.overrideOutputAudioPort(output == .speaker ? .speaker : .none)
                    if output != .system {
                        let microphone = session.availableInputs?.first { $0.portType == .builtInMic }
                        try session.setPreferredInput(microphone)
                    }
                }
                if output == .system { try session.setPreferredInput(nil) }
                return session.preferredInput?.uid ?? "system"
            } catch {
                try? AudioManager.shared.audioSession.chirpSetSpeakerOutputOverride(Self.speakerOverride(previous), inputSelected: previousInput != nil)
                try? session.setPreferredInput(previousInput)
                if session.category == .playAndRecord {
                    try? session.overrideOutputAudioPort(previous == .speaker ? .speaker : .none)
                }
                throw error
            }
        }
        outputPreference = output; preferredInput = inputID; fallback = false
        #endif
    }

    func playRoomSound(_ sound: RoomPresenceSound) { presenceSounds.enqueue(sound) }
    func stopRoomSounds() { presenceSounds.stop() }

    func startTest(preset: AudioPreset) async throws {
        guard !recording, probe == nil, player == nil else { throw ClientFailure(.audioControlBusy) }
        guard await MicrophoneAuthorization.request() else { throw ClientFailure(.microphonePermissionRequired) }
        try Task.checkCancellation()
        try await AudioPresetRuntime.validate(preset)
        try Task.checkCancellation()
        captureProcessor = CaptureAudioProcessor.configure(for: preset, voiceActivation: voiceActivation, reusing: captureProcessor) { [weak self] failure in
            self?.onEvent?(.failed(failure))
        }
        let renderer = MicrophoneRenderer()
        probe = renderer; recording = true
        AudioManager.shared.add(localAudioRenderer: renderer)
        do {
            let context = try await AudioManager.shared.chirpPrepareLocalAudioCapture()
            captureContext = context
            try Task.checkCancellation()
            try await context.startRecording(audioProcessingOptions: preset.processingOptions)
            try Task.checkCancellation()
            try await AudioPresetRuntime.waitUntilApplied(preset)
            for _ in 0..<30 {
                try Task.checkCancellation()
                if renderer.sample.hasFrames && voiceActivation.reading.isProcessing { return }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ClientFailure(.microphoneTestFailed)
        } catch {
            try? await finishTest(playSample: false)
            throw error
        }
    }

    #if os(macOS)
    private func prepareDevices() async throws {
        guard !preparedDevices else { return }
        let task = preparingDevices ?? Task { try await AudioManager.shared.chirpPrepareAudioDevices() }
        preparingDevices = task
        do { try await task.value; preparedDevices = true; preparingDevices = nil }
        catch { preparingDevices = nil; throw error }
    }
    #endif

    func finishTest(playSample: Bool) async throws {
        player?.stop(); player = nil; releasePlayback?(); releasePlayback = nil
        sampleData.resetBytes(in: 0..<sampleData.count); sampleData = Data()
        var sample = probe?.sample.finish(includeSample: playSample)
        defer {
            if var bytes = sample { bytes.resetBytes(in: 0..<bytes.count) }; sample = nil
            if player == nil { releasePlayback?(); releasePlayback = nil }
        }
        #if os(iOS)
        // Keep ownership continuous across ADM shutdown. Acquiring only after
        // stopping capture lets its deactivation interrupt the new player.
        var playbackFailure: Error?
        if playSample, !Task.isCancelled, sample != nil {
            do {
                let requirement = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)
                releasePlayback = { try? requirement.release() }
            } catch { playbackFailure = error }
        }
        #endif
        if let probe { AudioManager.shared.remove(localAudioRenderer: probe) }
        probe = nil
        if recording {
            try await CallAudioQueue.perform { try AudioManager.shared.stopLocalRecording() }
            recording = false
        }
        CaptureAudioProcessor.remove(captureProcessor); captureProcessor = nil
        await captureContext?.close(); captureContext = nil
        guard playSample, !Task.isCancelled else { return }
        #if os(iOS)
        if let playbackFailure { throw playbackFailure }
        #endif
        guard let data = sample else { throw ClientFailure(.microphoneTestFailed) }
        let player = try makeTestPlayer(data)
        guard player.prepareToPlay(), player.play() else { throw ClientFailure(.microphoneTestFailed) }
        self.player = player; sampleData = data
    }

    #if os(iOS)
    nonisolated private static func speakerOverride(_ output: CallAudioOutput) -> Bool? {
        switch output {
        case .system: nil
        case .speaker: true
        case .receiver: false
        }
    }

    private static func routeKind(_ port: AVAudioSession.Port?) -> CallAudioRoute {
        switch port {
        case .builtInSpeaker: .speaker
        case .builtInReceiver: .receiver
        case .headphones, .headsetMic, .lineOut: .wired
        case .bluetoothA2DP, .bluetoothHFP, .bluetoothLE: .bluetooth
        case .usbAudio: .usb
        case .airPlay: .airPlay
        case nil: .unknown
        default: .other
        }
    }
    #endif
}
