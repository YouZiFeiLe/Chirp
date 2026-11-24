import Foundation

enum AudioPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple
    case appleOnly
    case webRTC

    static let preferenceKey = "audioPreset"
    static let defaultPreset: AudioPreset = .apple
    var id: String { rawValue }
    var usesAppleProcessing: Bool { self != .webRTC }
    var usesRNNoise: Bool { self != .appleOnly }

    var title: LocalizedMessage {
        switch self {
        case .apple: "Apple 系统处理＋RNNoise"
        case .appleOnly: "Apple 系统处理（不使用 RNNoise）"
        case .webRTC: "WebRTC 回声消除＋RNNoise"
        }
    }

    var explanation: LocalizedMessage {
        switch self {
        case .apple: "Apple 提供回声消除、系统降噪和音量控制，再由 RNNoise 进一步降噪。Apple 回声消除与系统降噪一起启用。"
        case .appleOnly: "仅使用 Apple 的回声消除、系统降噪和音量控制，不经过 RNNoise。Apple 回声消除与系统降噪一起启用。"
        case .webRTC: "WebRTC 提供回声消除和音量控制，RNNoise 负责降噪；不启用 Apple 系统语音处理。"
        }
    }

    static func load(from defaults: UserDefaults = .standard) -> AudioPreset {
        defaults.string(forKey: preferenceKey).flatMap(AudioPreset.init(rawValue:)) ?? defaultPreset
    }

    func save(to defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.preferenceKey) }
}

enum AudioProcessingProvider: Sendable {
    case unknown, disabled, apple, webRTC, both
}

enum RNNoiseProcessingState: Sendable {
    case unknown, disabled, initializing, active, failed
}

/// Values read back from the SDK and the installed processor, not the selection.
struct AudioPresetObservation: Sendable {
    let echo: AudioProcessingProvider
    let noise: AudioProcessingProvider
    let gain: AudioProcessingProvider
    let appleEchoActive: Bool
    let appleNoiseActive: Bool
    let rnnoise: RNNoiseProcessingState
    let captureProcessorReady: Bool

    func matches(_ preset: AudioPreset) -> Bool {
        guard captureProcessorReady, rnnoise == (preset.usesRNNoise ? .active : .disabled) else { return false }
        return switch preset {
        case .apple, .appleOnly:
            echo == .apple && noise == .apple && gain == .apple && appleEchoActive && appleNoiseActive
        case .webRTC:
            echo == .webRTC && noise == .disabled && gain == .webRTC && !appleEchoActive && !appleNoiseActive
        }
    }
}
