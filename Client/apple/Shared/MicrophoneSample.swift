import Foundation

/// At most three seconds of mono PCM, only for a user-requested local test.
/// Closing is atomic: late render callbacks cannot restore samples after cleanup.
final class MicrophoneSample: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var writeIndex = 0
    private var count = 0
    private var sampleRate = 0
    private var closed = false
    private var meter = 0.0
    var level: Double { lock.withLock { meter } }
    var hasFrames: Bool { lock.withLock { !closed && count > 0 } }

    func append(_ input: [Float], sampleRate: Int) {
        guard (8_000...192_000).contains(sampleRate), !input.isEmpty, input.count <= 8_192 else { return }
        lock.withLock {
            guard !closed else { return }
            if self.sampleRate != sampleRate {
                erase(); self.sampleRate = sampleRate
                samples = Array(repeating: 0, count: sampleRate * 3)
            }
            var energy = 0.0
            for sample in input {
                let bounded = sample.isFinite ? min(1, max(-1, sample)) : 0
                energy += Double(bounded * bounded)
                samples[writeIndex] = Int16(bounded * 32_767)
                writeIndex = (writeIndex + 1) % samples.count
                count = min(count + 1, samples.count)
            }
            let rms = sqrt(energy / Double(input.count))
            meter = max(0, min(1, (20 * log10(max(rms, 0.001)) + 60) / 60))
        }
    }

    func finish(includeSample: Bool) -> Data? {
        lock.withLock {
            guard !closed else { return nil }
            closed = true
            defer { erase() }
            guard includeSample, count > 0 else { return nil }
            var data = Data("RIFF".utf8)
            func append<T: FixedWidthInteger>(_ value: T) {
                var little = value.littleEndian
                withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
            }
            append(UInt32(36 + count * 2)); data.append(Data("WAVEfmt ".utf8))
            append(UInt32(16)); append(UInt16(1)); append(UInt16(1))
            append(UInt32(sampleRate)); append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
            data.append(Data("data".utf8)); append(UInt32(count * 2))
            let start = count == samples.count ? writeIndex : 0
            for index in 0..<count { append(samples[(start + index) % samples.count]) }
            return data
        }
    }

    private func erase() {
        for index in samples.indices { samples[index] = 0 }
        samples.removeAll(); count = 0; writeIndex = 0; sampleRate = 0; meter = 0
    }
}
