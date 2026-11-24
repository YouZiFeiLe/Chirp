import Foundation

public struct VoiceActivationResult: Sendable {
    public let inputDBFS: Double
    public let isOpen: Bool
}

/// Confined to the serialized capture callbacks. Buffers use WebRTC Float-S16.
/// RNNoise continues running while the gate is closed, preserving its history.
public final class CaptureAudioPipeline {
    private let channels: Int
    private let frames: Int
    private let denoiser: RNNoiseDenoiser?
    private var gate: VoiceActivationGate
    private var failed = false

    public init?(sampleRate: Int, channels: Int, usesRNNoise: Bool) {
        guard (8_000...192_000).contains(sampleRate), sampleRate % 100 == 0,
              (1...2).contains(channels) else { return nil }
        self.channels = channels
        frames = sampleRate / 100
        gate = VoiceActivationGate(sampleRate: sampleRate)
        if usesRNNoise {
            guard let denoiser = RNNoiseDenoiser(sampleRate: sampleRate, channels: channels) else { return nil }
            self.denoiser = denoiser
        } else {
            denoiser = nil
        }
    }

    public func resetGate() { gate.reset() }

    /// No allocations, locks, or asynchronous work on the successful frame path.
    /// A failed stream stays silent until its owner creates a new pipeline.
    public func process(frames: Int, channels: Int, enabled: Bool, thresholdDBFS: Double,
                        channelData: (Int) -> UnsafeMutablePointer<Float>) -> VoiceActivationResult? {
        if !failed, frames == self.frames, channels == self.channels {
            var denoised = true
            if let denoiser {
                for channel in 0..<channels {
                    if !denoiser.process(UnsafeMutableBufferPointer(start: channelData(channel), count: frames), channel: channel) {
                        denoised = false
                        break
                    }
                }
            }
            if denoised, let result = gate.process(frames: frames, channels: channels, enabled: enabled,
                                                   thresholdDBFS: thresholdDBFS, channelData: channelData) {
                return result
            }
        }
        failed = true
        if frames > 0, frames <= 8_192, channels > 0, channels <= 2 {
            for channel in 0..<channels { channelData(channel).update(repeating: 0, count: frames) }
        }
        return nil
    }
}

private struct VoiceActivationGate {
    private let holdSamples: Int
    private let gainStep: Float
    private var isOpen = false
    private var quietSamples = 0
    private var gain: Float = 0
    private var wasEnabled = false

    init(sampleRate: Int) {
        holdSamples = sampleRate / 4 // 250 ms, independent of capture sample rate.
        gainStep = 1 / Float(max(1, sampleRate / 200)) // 5 ms attack/release.
    }

    mutating func reset() {
        isOpen = false; quietSamples = 0; gain = 0; wasEnabled = false
    }

    mutating func process(frames: Int, channels: Int, enabled: Bool, thresholdDBFS: Double,
                          channelData: (Int) -> UnsafeMutablePointer<Float>) -> VoiceActivationResult? {
        guard thresholdDBFS.isFinite else { return nil }
        var energy = 0.0
        // Link channels using the loudest RMS; opposite phases never cancel,
        // and an unused stereo channel cannot halve the activation level.
        for channel in 0..<channels {
            let samples = channelData(channel)
            var channelEnergy = 0.0
            for index in 0..<frames {
                guard samples[index].isFinite else { return nil }
                let sample = Double(samples[index]) / 32_768
                channelEnergy += sample * sample
            }
            energy = max(energy, channelEnergy / Double(frames))
        }
        let db = max(-96, min(0, 10 * log10(max(energy, 1e-12))))
        guard enabled else {
            reset()
            return VoiceActivationResult(inputDBFS: db, isOpen: false)
        }
        if !wasEnabled { reset(); wasEnabled = true }
        let threshold = min(-10, max(-80, thresholdDBFS))
        if db >= threshold || (isOpen && db >= threshold - 5) {
            isOpen = true; quietSamples = 0
        } else if isOpen {
            quietSamples += frames
            if quietSamples >= holdSamples { isOpen = false; quietSamples = 0 }
        }

        let initialGain = gain
        let target: Float = isOpen ? 1 : 0
        for channel in 0..<channels {
            let samples = channelData(channel)
            var nextGain = initialGain
            if nextGain == 0, target == 0 {
                samples.update(repeating: 0, count: frames)
            } else if nextGain != 1 || target != 1 {
                for index in 0..<frames {
                    nextGain = target > nextGain ? min(target, nextGain + gainStep) : max(target, nextGain - gainStep)
                    samples[index] *= nextGain
                }
            }
            gain = nextGain
        }
        return VoiceActivationResult(inputDBFS: db, isOpen: isOpen)
    }
}
