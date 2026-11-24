import Combine
import Foundation

enum CallAudioRoute: String, Codable, Sendable {
    case unknown, speaker, receiver, wired, bluetooth, usb, airPlay, other

    var output: CallAudioOutput {
        switch self {
        case .speaker: .speaker
        case .receiver: .receiver
        default: .system
        }
    }
}
enum CallAudioOutput: String, CaseIterable, Sendable { case system, speaker, receiver }

struct CallAudioDevice: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    var route: CallAudioRoute = .unknown
}

/// Device names and IDs are UI-only. This type deliberately isn't Codable.
struct CallAudioSnapshot: Equatable, Sendable {
    var inputs: [CallAudioDevice] = []
    var outputs: [CallAudioDevice] = []
    var inputID = "system"
    var outputID = "system"
    var inputName = ""
    var outputName = ""
    var activeInputID: String?
    var route: CallAudioRoute = .unknown
    var supportsReceiver = false
    var fellBackToDefault = false

    var headsetInputs: [CallAudioDevice] {
        inputs.filter { $0.route == .bluetooth || $0.route == .wired }
    }

    var alternateBuiltInOutput: CallAudioOutput? {
        guard supportsReceiver, headsetInputs.isEmpty else { return nil }
        switch route {
        case .speaker: return .receiver
        case .receiver: return .speaker
        default: return nil
        }
    }

    var outputTitle: LocalizedMessage {
        switch route {
        case .speaker: "扬声器"
        case .receiver: "听筒"
        case .bluetooth: outputName.isEmpty ? "蓝牙耳机" : "\(outputName)"
        default: outputName.isEmpty ? "输出设备" : "\(outputName)"
        }
    }
}

enum CallAudioSystemEvent: Sendable {
    case routeChanged, interrupted, resumeRecommended, resumeDeclined, servicesReset
}

enum CallAudioEvent: Sendable {
    case devices(CallAudioSnapshot)
    case system(CallAudioSystemEvent)
    case failed(ClientFailure)
}

@MainActor
protocol CallAudioHardware: AnyObject {
    var onEvent: (@MainActor @Sendable (CallAudioEvent) -> Void)? { get set }
    var isTestPlaying: Bool { get }
    func acquireSettingsSession() throws -> () -> Void
    func setVoiceActivation(_ control: VoiceActivationControl)
    func refresh() async
    func selectInput(_ id: String) async throws
    func selectOutput(_ id: String) async throws
    func preferOutput(_ output: CallAudioOutput) async throws
    func startTest(preset: AudioPreset) async throws
    func finishTest(playSample: Bool) async throws
    func playRoomSound(_ sound: RoomPresenceSound)
    func stopRoomSounds()
}

/// One app-owned audio owner. It serializes probe teardown before any call starts.
@MainActor
final class CallAudioController: ObservableObject {
    enum TestPhase { case idle, starting, measuring, stopping, playing }
    @Published private(set) var devices = CallAudioSnapshot()
    /// The picker follows the actual route, including changes made by iOS.
    var output: CallAudioOutput { devices.route.output }
    @Published private(set) var testPhase: TestPhase = .idle
    @Published private(set) var isChangingDevice = false
    @Published private(set) var error: ClientFailure?
    var onSystemEvent: (@MainActor (CallAudioSystemEvent) -> Void)?
    var onDiagnostic: (@MainActor (CallDiagnostic.Event) -> Void)?
    private let hardware: (any CallAudioHardware)?
    private var starting: Task<Void, Error>?
    private var metering: Task<Void, Never>?
    private var stopping: Task<Void, Never>?
    private var changing: Task<Void, Error>?
    private var testID: UUID?
    private var stopID: UUID?
    private var cleanupFailed = false
    private var testOwner: UUID?

    var isAvailable: Bool { hardware != nil }
    var hasPendingWork: Bool { testPhase != .idle || isChangingDevice || stopID != nil }
    var isTesting: Bool { testPhase == .starting || testPhase == .measuring }

    init(hardware: (any CallAudioHardware)?) {
        self.hardware = hardware
        hardware?.onEvent = { [weak self] event in
            guard let self else { return }
            switch event {
            case let .devices(snapshot): devices = snapshot
            case let .failed(failure): error = failure; _ = cancelTest()
            case let .system(event):
                if case .interrupted = event { _ = cancelTest() }
                if case .servicesReset = event { _ = cancelTest() }
                onSystemEvent?(event)
            }
        }
    }

    func resetLocalSettings() async {
        await cancelTest()?.value; error = nil
        try? await hardware?.selectInput("system"); try? await hardware?.selectOutput("system")
        try? await hardware?.preferOutput(.system); devices = CallAudioSnapshot(); await hardware?.refresh()
    }
    func refresh() async { await hardware?.refresh() }

    /// The settings screen owns listening/routing until its task ends. iOS
    /// cannot keep a receiver route when its audio session is inactive.
    func acquireSettingsSession() throws -> () -> Void {
        guard let hardware else { throw ClientFailure(.audioControlUnavailable) }
        return try hardware.acquireSettingsSession()
    }

    func playRoomSound(_ sound: RoomPresenceSound) {
        guard !isChangingDevice, testPhase == .idle else { return }
        hardware?.playRoomSound(sound)
    }
    func stopRoomSounds() { hardware?.stopRoomSounds() }

    private func change(_ operation: StaticString = #function, _ action: @escaping @MainActor (any CallAudioHardware) async throws -> Void) async throws {
        guard let hardware else { throw ClientFailure(.audioControlUnavailable) }
        guard !isChangingDevice, testPhase == .idle else { throw ClientFailure(.audioControlBusy) }
        isChangingDevice = true; error = nil
        let task = Task { @MainActor in try await action(hardware); await hardware.refresh() }
        changing = task
        defer { changing = nil; isChangingDevice = false }
        let span = ClientLog.shared.begin()
        do {
            try await task.value
            ClientLog.shared.finish(span, .audio, operation)
        } catch {
            ClientLog.shared.finish(span, .audio, operation, error: error)
            self.error = ClientFailure.capture(error, fallback: .audioDeviceChangeFailed); throw error
        }
    }

    func selectInput(_ id: String) async throws { try await change { try await $0.selectInput(id) } }
    func selectOutput(_ id: String) async throws { try await change { try await $0.selectOutput(id) } }
    func preferOutput(_ output: CallAudioOutput) async throws {
        try await change { try await $0.preferOutput(output) }
    }
    func prepareForCall() async throws {
        await cancelTest()?.value
        if testPhase == .playing { await cancelTest()?.value }
        _ = try? await changing?.value
        if cleanupFailed { throw error ?? ClientFailure(.microphoneTestFailed) }
    }

    func startTest(preset: AudioPreset, owner: UUID? = nil) async throws {
        guard let hardware else { throw ClientFailure(.audioControlUnavailable) }
        guard testPhase == .idle, !isChangingDevice, stopID == nil else { throw ClientFailure(.audioControlBusy) }
        let id = UUID()
        testID = id; testOwner = owner; testPhase = .starting; error = nil
        let task = Task { @MainActor in try await hardware.startTest(preset: preset) }
        starting = task
        do {
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard testID == id else { throw CancellationError() }
            starting = nil; testPhase = .measuring
            onDiagnostic?(.microphoneTestStarted)
            metering = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self, testID == id, !Task.isCancelled else { return }
                await cancelTest()?.value
            }
        } catch {
            if testID == id {
                if !(error is CancellationError) { self.error = ClientFailure.capture(error, fallback: .microphoneTestFailed) }
                await cancelTest()?.value
            }
            throw error
        }
    }

    @discardableResult
    func cancelTest(owner: UUID? = nil, playSample: Bool = false) -> Task<Void, Never>? {
        if let owner, owner != testOwner { return nil }
        guard testID != nil || testPhase == .playing || cleanupFailed else {
            if !playSample { stopping?.cancel() }
            return stopping
        }
        let pending = starting, previous = stopping, id = UUID()
        testID = nil; stopID = id; starting = nil
        pending?.cancel(); metering?.cancel(); metering = nil
        testPhase = .stopping
        let task = Task { @MainActor [self] in
            await previous?.value
            _ = try? await pending?.value
            do { try await hardware?.finishTest(playSample: playSample); cleanupFailed = false }
            catch { cleanupFailed = true; self.error = ClientFailure.capture(error, fallback: .microphoneTestFailed) }
            guard stopID == id else { return }
            stopID = nil; stopping = nil
            onDiagnostic?(.microphoneTestStopped)
            testPhase = cleanupFailed ? .stopping : hardware?.isTestPlaying == true ? .playing : .idle
            if testPhase == .idle { testOwner = nil }
            if testPhase == .playing {
                metering = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                        guard let self else { return }
                        if hardware?.isTestPlaying != true { await cancelTest()?.value; return }
                    }
                }
            }
        }
        stopping = task
        return task
    }
}
