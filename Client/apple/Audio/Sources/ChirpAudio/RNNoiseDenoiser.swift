import CChirpAudio

/// One microphone stream. Confine initialization, processing and destruction to
/// the serialized audio-processing lifecycle; do not share across capture streams.
public final class RNNoiseDenoiser {
    public static let version = "0.2"
    private let processor: OpaquePointer

    public init?(sampleRate: Int, channels: Int) {
        guard let rate = Int32(exactly: sampleRate), let count = Int32(exactly: channels),
              let processor = chirp_rnnoise_create(rate, count) else { return nil }
        self.processor = processor
    }

    deinit { chirp_rnnoise_destroy(processor) }

    /// Accepts one 10 ms channel in WebRTC's Float-S16 amplitude range.
    /// Returns false and silences the frame on failure. There is no bypass mode.
    public func process(_ samples: UnsafeMutableBufferPointer<Float>, channel: Int) -> Bool {
        guard let count = Int32(exactly: samples.count), let index = Int32(exactly: channel) else {
            samples.update(repeating: 0)
            return false
        }
        return chirp_rnnoise_process(processor, samples.baseAddress, count, index)
    }
}
