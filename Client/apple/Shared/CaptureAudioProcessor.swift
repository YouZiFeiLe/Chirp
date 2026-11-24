import ChirpAudio
import Foundation
import LiveKit
import Synchronization

// WebRTC serializes its CustomProcessing initialize/process/release callbacks.
// Mutable DSP state is accessed only from those callbacks, never from the UI.
final class CaptureAudioProcessor: NSObject, AudioCustomProcessingDelegate, @unchecked Sendable {
    /// The call or probe owns its processor. Reusing it only within that owner
    /// prevents late failures from a previous capture from affecting a new one.
    @MainActor
    static func configure(for preset: AudioPreset, voiceActivation: VoiceActivationControl,
                          reusing processor: CaptureAudioProcessor?, authorization: MediaContentGate? = nil,
                          onFailure: @escaping @MainActor @Sendable (ClientFailure) -> Void) -> CaptureAudioProcessor {
        let next: CaptureAudioProcessor
        if let processor, processor.usesRNNoise == preset.usesRNNoise, processor.voiceActivation === voiceActivation, processor.authorization === authorization {
            next = processor
        } else {
            next = CaptureAudioProcessor(usesRNNoise: preset.usesRNNoise, voiceActivation: voiceActivation, authorization: authorization, onFailure: onFailure)
        }
        if AudioManager.shared.capturePostProcessingDelegate !== next {
            AudioManager.shared.capturePostProcessingDelegate = next
        }
        return next
    }

    @MainActor
    static func remove(_ processor: CaptureAudioProcessor?) {
        guard let processor, AudioManager.shared.capturePostProcessingDelegate === processor else { return }
        AudioManager.shared.capturePostProcessingDelegate = nil
        processor.voiceActivation.resetMeter()
    }

    @MainActor
    static var observation: (rnnoise: RNNoiseProcessingState, isReady: Bool) {
        guard let delegate = AudioManager.shared.capturePostProcessingDelegate else { return (.disabled, false) }
        guard let processor = delegate as? CaptureAudioProcessor else { return (.unknown, false) }
        let state = processor.lifecycle.withLock { $0.state }
        return (state, state == .active || state == .disabled)
    }

    var audioProcessingName: String { usesRNNoise ? "chirp_rnnoise_0_2" : "chirp_voice_activation" }
    private struct Lifecycle {
        var generation: UInt64 = 0
        var state: RNNoiseProcessingState = .initializing
    }
    // Read by the control thread; updated only on initialize/release/failure.
    // Successful per-frame processing never takes this lock.
    private let lifecycle = Mutex(Lifecycle())
    private let onFailure: @MainActor @Sendable (ClientFailure) -> Void
    private let usesRNNoise: Bool
    private let voiceActivation: VoiceActivationControl
    private let authorization: MediaContentGate?
    private let resetGeneration = Atomic<UInt64>(0)
    private var appliedResetGeneration: UInt64 = 0
    private var pipeline: CaptureAudioPipeline?
    private var channelCount = 0
    private var frameCount = 0
    private var didReportFailure = false

    private init(usesRNNoise: Bool, voiceActivation: VoiceActivationControl, authorization: MediaContentGate?,
                 onFailure: @escaping @MainActor @Sendable (ClientFailure) -> Void) {
        self.usesRNNoise = usesRNNoise
        self.voiceActivation = voiceActivation
        self.authorization = authorization
        self.onFailure = onFailure
        super.init()
    }

    /// Control threads request a reset; only the audio callback mutates DSP state.
    func resetGate() {
        resetGeneration.wrappingAdd(1, ordering: .relaxed)
        voiceActivation.resetMeter()
    }

    func audioProcessingInitialize(sampleRate sampleRateHz: Int, channels: Int) {
        lifecycle.withLock { $0.generation &+= 1; $0.state = .initializing }
        pipeline = nil
        didReportFailure = false
        voiceActivation.resetMeter()
        appliedResetGeneration = resetGeneration.load(ordering: .relaxed)
        channelCount = channels
        frameCount = sampleRateHz / 100
        pipeline = CaptureAudioPipeline(sampleRate: sampleRateHz, channels: channels, usesRNNoise: usesRNNoise)
        if pipeline == nil {
            reportFailure(ClientFailure(usesRNNoise ? .noiseInitializationFailed : .audioProcessingFailed))
        } else {
            lifecycle.withLock { $0.state = usesRNNoise ? .active : .disabled }
            ClientLog.shared.record(.audio, "captureInitialized", details: .capture(rate: sampleRateHz, channels: channels, denoising: usesRNNoise))
        }
    }

    func audioProcessingProcess(audioBuffer: LKAudioBuffer) {
        // A blocked MainActor or sleeping device cannot keep capturing speech
        // under expired authorization. Local microphone tests have no network
        // publisher and deliberately use a separate processor with no gate.
        if let authorization, !authorization.permitsCapture() { silence(audioBuffer); return }
        guard !didReportFailure, let pipeline,
              audioBuffer.channels == channelCount, audioBuffer.frames == frameCount else {
            silence(audioBuffer)
            reportFailure(ClientFailure(usesRNNoise ? .noiseFormatInvalid : .audioProcessingFailed))
            return
        }
        let generation = resetGeneration.load(ordering: .relaxed)
        if generation != appliedResetGeneration {
            pipeline.resetGate(); appliedResetGeneration = generation
        }
        let settings = voiceActivation.settings
        guard let reading = pipeline.process(frames: audioBuffer.frames, channels: audioBuffer.channels,
                                              enabled: settings.enabled, thresholdDBFS: settings.thresholdDBFS,
                                              channelData: { audioBuffer.rawBuffer(forChannel: $0) }) else {
            silence(audioBuffer)
            reportFailure(ClientFailure(usesRNNoise ? .noiseProcessingFailed : .audioProcessingFailed))
            return
        }
        if let authorization, !authorization.permitsCapture() { silence(audioBuffer); return }
        voiceActivation.publish(inputDBFS: reading.inputDBFS, isOpen: reading.isOpen)
    }

    func audioProcessingRelease() {
        lifecycle.withLock { $0.generation &+= 1; $0.state = .initializing }
        pipeline = nil
        voiceActivation.resetMeter()
        channelCount = 0
        frameCount = 0
    }

    private func silence(_ buffer: LKAudioBuffer) {
        for channel in 0..<buffer.channels {
            buffer.rawBuffer(forChannel: channel).update(repeating: 0, count: buffer.frames)
        }
    }

    private func reportFailure(_ message: ClientFailure) {
        guard !didReportFailure else { return }
        didReportFailure = true
        voiceActivation.resetMeter()
        let generation = lifecycle.withLock { state in state.state = .failed; return state.generation }
        ClientLog.shared.record(.audio, "captureFailed", outcome: .failed, failure: message)
        DispatchQueue.main.async { [self] in
            guard AudioManager.shared.capturePostProcessingDelegate === self,
                  lifecycle.withLock({ $0.generation == generation && $0.state == .failed }) else { return }
            onFailure(message)
        }
    }
}
