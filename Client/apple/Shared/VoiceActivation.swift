import Combine
import Foundation
import Synchronization

struct VoiceActivationSettings: Equatable, Sendable {
    static let thresholdRange = -80.0 ... -10.0
    static let defaultThreshold = -45.0
    static let enabledKey = "voiceActivationEnabled"
    static let thresholdKey = "voiceActivationThresholdDBFS"
    let enabled: Bool
    let thresholdDBFS: Double

    init(enabled: Bool = false, thresholdDBFS: Double = defaultThreshold) {
        self.enabled = enabled
        self.thresholdDBFS = thresholdDBFS.isFinite
            ? min(Self.thresholdRange.upperBound, max(Self.thresholdRange.lowerBound, thresholdDBFS.rounded()))
            : Self.defaultThreshold
    }

    static func load(from defaults: UserDefaults) -> Self {
        Self(enabled: defaults.bool(forKey: enabledKey),
             thresholdDBFS: (defaults.object(forKey: thresholdKey) as? NSNumber)?.doubleValue ?? defaultThreshold)
    }

    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: Self.enabledKey)
        defaults.set(thresholdDBFS, forKey: Self.thresholdKey)
    }
}

struct VoiceActivationReading: Equatable, Sendable {
    var inputDBFS = -96.0
    var isProcessing = false
    var isOpen = false
    var level: Double { min(1, max(0, (inputDBFS + 80) / 80)) }
}

/// Shared by the app's mutually exclusive call and microphone-test owners.
/// Each configuration and reading fits in one atomic word, so the audio callback
/// never waits for the UI or observes half of an updated configuration.
final class VoiceActivationControl: Sendable {
    private let configuration: Atomic<UInt32>
    private let meter = Atomic<UInt32>(0)

    init(settings: VoiceActivationSettings = VoiceActivationSettings()) {
        configuration = Atomic(Self.encode(settings))
    }

    var settings: VoiceActivationSettings {
        let value = configuration.load(ordering: .relaxed)
        return VoiceActivationSettings(enabled: value & 1 != 0, thresholdDBFS: Double(value >> 1) - 80)
    }

    func update(_ settings: VoiceActivationSettings) {
        configuration.store(Self.encode(settings), ordering: .relaxed)
    }

    private static func encode(_ settings: VoiceActivationSettings) -> UInt32 {
        (UInt32(settings.thresholdDBFS + 80) << 1) | (settings.enabled ? 1 : 0)
    }

    var reading: VoiceActivationReading {
        let value = meter.load(ordering: .relaxed)
        return VoiceActivationReading(inputDBFS: Double(value >> 2) / 10 - 96,
                                      isProcessing: value & 1 != 0, isOpen: value & 2 != 0)
    }

    func publish(inputDBFS: Double, isOpen: Bool) {
        let db = inputDBFS.isFinite ? min(0, max(-96, inputDBFS)) : -96
        meter.store((UInt32(((db + 96) * 10).rounded()) << 2) | 1 | (isOpen ? 2 : 0), ordering: .relaxed)
    }

    func resetMeter() { meter.store(0, ordering: .relaxed) }
}

@MainActor
final class VoiceActivationController: ObservableObject {
    @Published private(set) var settings: VoiceActivationSettings
    @Published private(set) var reading = VoiceActivationReading()
    let control: VoiceActivationControl
    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = VoiceActivationSettings.load(from: defaults)
        settings = saved
        control = VoiceActivationControl(settings: saved)
    }

    func resetLocalSettings() {
        settings = VoiceActivationSettings(enabled: false, thresholdDBFS: VoiceActivationSettings.defaultThreshold)
        control.update(settings); control.resetMeter(); reading = VoiceActivationReading()
    }
    func setEnabled(_ enabled: Bool) {
        ClientLog.shared.record(.audio, enabled ? "enableVoiceActivation" : "disableVoiceActivation")
        update(VoiceActivationSettings(enabled: enabled, thresholdDBFS: settings.thresholdDBFS))
    }

    func setThreshold(_ db: Double) {
        update(VoiceActivationSettings(enabled: settings.enabled, thresholdDBFS: db))
    }

    private func update(_ next: VoiceActivationSettings) {
        guard next != settings else { return }
        settings = next
        control.update(next)
        next.save(to: defaults)
    }

    func refresh() {
        let next = control.reading
        if next != reading { reading = next }
    }
}
