import LiveKit

extension AudioPreset {
    var captureOptions: AudioCaptureOptions {
        AudioCaptureOptions(
            echoCancellation: true, autoGainControl: true, noiseSuppression: usesAppleProcessing,
            echoCancellationMode: usesAppleProcessing ? .platform : .software,
            autoGainControlMode: usesAppleProcessing ? .platform : .software,
            noiseSuppressionMode: usesAppleProcessing ? .platform : .software
        )
    }

    var processingOptions: AudioProcessingOptions {
        AudioProcessingOptions(
            echoCancellation: true, autoGainControl: true, noiseSuppression: usesAppleProcessing,
            echoCancellationMode: usesAppleProcessing ? .platform : .software,
            autoGainControlMode: usesAppleProcessing ? .platform : .software,
            noiseSuppressionMode: usesAppleProcessing ? .platform : .software
        )
    }
}

@MainActor
enum AudioPresetRuntime {
    static func validate(_ preset: AudioPreset) async throws {
        guard preset.usesAppleProcessing else { return }
        // Do not gate a platform request on the software graph's capability
        // snapshot. Let the typed .platform request validate the new path, then
        // verify live state after the transition (including when unmuting).
        let allowed = await Task.detached {
            AudioManager.shared.isPlatformVoiceProcessingAllowed
        }.value
        guard allowed else {
            throw ClientFailure(.appleAudioUnavailable)
        }
    }

    static func apply(_ preset: AudioPreset, to track: LocalAudioTrack) async throws {
        // The pinned SDK updates voice processing without restarting capture.
        // This call blocks on WebRTC's signaling thread, so keep it off the UI thread.
        // https://github.com/livekit/client-sdk-swift/blob/2.19.0/Sources/LiveKit/Track/Local/LocalAudioTrack.swift#L115
        _ = try await Task.detached(priority: .userInitiated) {
            try track.setAudioProcessingOptions(preset.processingOptions)
        }.value
    }

    static func observation() async -> AudioPresetObservation {
        let (state, platform) = await Task.detached {
            (AudioManager.shared.audioProcessingState, AudioManager.shared.platformVoiceProcessingState)
        }.value
        let capture = CaptureAudioProcessor.observation
        return AudioPresetObservation(
            echo: provider(state.echoCancellation.effective), noise: provider(state.noiseSuppression.effective),
            gain: provider(state.autoGainControl.effective),
            appleEchoActive: platform.echoCancellation.isActive,
            appleNoiseActive: platform.noiseSuppression.isActive,
            rnnoise: capture.rnnoise, captureProcessorReady: capture.isReady
        )
    }

    static func waitUntilApplied(_ preset: AudioPreset) async throws {
        let clock = ContinuousClock(), deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var interval = Duration.milliseconds(20)
        repeat {
            try Task.checkCancellation()
            if await observation().matches(preset) { return }
            try await clock.sleep(until: min(deadline, clock.now.advanced(by: interval)))
            interval = min(interval * 2, .milliseconds(100))
        } while clock.now < deadline
        throw ClientFailure(.audioPresetUnconfirmed)
    }

    private static func provider(_ implementation: AudioProcessingImplementation) -> AudioProcessingProvider {
        switch implementation {
        case .unknown: .unknown
        case .disabled: .disabled
        case .software: .webRTC
        case .platform: .apple
        case .softwareAndPlatform: .both
        }
    }
}
