import ChirpAudio
import CRNNoise
import Foundation
import Testing

private struct Noise {
    var state: UInt32 = 0x12345678
    mutating func next() -> Float {
        state = state &* 1664525 &+ 1013904223
        return (Float(state >> 8) / Float(1 << 24) * 2 - 1) * 2000
    }
}

private func process(_ frame: inout [Float], using denoiser: RNNoiseDenoiser, channel: Int = 0) -> Bool {
    frame.withUnsafeMutableBufferPointer { denoiser.process($0, channel: channel) }
}

@Test func modelLoadingRejectsNullMissingEmptyAndOversizedFiles() throws {
    #expect(rnnoise_model_from_filename(nil) == nil)
    #expect(rnnoise_model_from_file(nil) == nil)
    #expect(rnnoise_model_from_buffer(nil, 1) == nil)
    rnnoise_model_free(nil)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("model.bin")
    #expect(file.path.withCString { rnnoise_model_from_filename($0) } == nil)
    try Data().write(to: file)
    #expect(file.path.withCString { rnnoise_model_from_filename($0) } == nil)
    let handle = try FileHandle(forWritingTo: file)
    // A sparse file checks the ftell-to-int boundary without allocating 2 GiB.
    try handle.truncate(atOffset: UInt64(Int32.max) + 1)
    try handle.close()
    #expect(file.path.withCString { rnnoise_model_from_filename($0) } == nil)
}

@Test func modelBuffersAndBorrowedFilesHaveInitializedOwnership() throws {
    let bytes = Data(repeating: 0, count: 256)
    try bytes.withUnsafeBytes { buffer in
        #expect(rnnoise_model_from_buffer(buffer.baseAddress, 0) == nil)
        let model = try #require(rnnoise_model_from_buffer(buffer.baseAddress, Int32(buffer.count)))
        rnnoise_model_free(model)
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: file) }
    try bytes.write(to: file)
    let owned = try #require(file.path.withCString { rnnoise_model_from_filename($0) })
    rnnoise_model_free(owned)
    let stream = try #require(file.path.withCString { fopen($0, "rb") })
    defer { fclose(stream) }
    let borrowed = try #require(rnnoise_model_from_file(stream))
    rnnoise_model_free(borrowed)
    #expect(fseek(stream, 0, SEEK_SET) == 0) // Caller still owns this FILE.
    #expect(fgetc(stream) == 0)
}

@Test func rejectsUnsupportedFormats() {
    #expect(RNNoiseDenoiser.version == "0.2")
    for rate in [0, 44100, 96000, -48000] { #expect(RNNoiseDenoiser(sampleRate: rate, channels: 1) == nil) }
    for channels in [0, 3, -1] { #expect(RNNoiseDenoiser(sampleRate: 48000, channels: channels) == nil) }
}

@Test(arguments: [8000, 16000, 32000, 48000])
func silenceRemainsSilent(sampleRate: Int) throws {
    let denoiser = try #require(RNNoiseDenoiser(sampleRate: sampleRate, channels: 1))
    for _ in 0..<20 {
        var frame = [Float](repeating: 0, count: sampleRate / 100)
        #expect(process(&frame, using: denoiser))
        #expect(frame.allSatisfy { $0 == 0 })
    }
}

// Verify the real shipped model and Float-S16 scaling against the upstream API,
// rather than a mocked denoiser or an identity implementation.
@Test func nativeOutputMatchesOfficialModel() throws {
    let denoiser = try #require(RNNoiseDenoiser(sampleRate: 48000, channels: 1))
    let official = try #require(rnnoise_create(nil))
    defer { rnnoise_destroy(official) }
    var noise = Noise()
    for frameIndex in 0..<60 {
        var actual = (0..<480).map { sample in
            noise.next() + 5000 * sin(Float(frameIndex * 480 + sample) * 2 * .pi * 220 / 48000)
        }
        var expected = actual
        expected.withUnsafeMutableBufferPointer { buffer in
            _ = rnnoise_process_frame(official, buffer.baseAddress, buffer.baseAddress)
        }
        #expect(process(&actual, using: denoiser))
        #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.001 })
    }
}

@Test(arguments: [8000, 16000, 32000, 48000])
func attenuatesNoiseWithoutReplacingAudioWithSilence(sampleRate: Int) throws {
    let denoiser = try #require(RNNoiseDenoiser(sampleRate: sampleRate, channels: 1))
    var noise = Noise()
    var inputEnergy = 0.0
    var outputEnergy = 0.0
    let start = ContinuousClock.now
    for frameIndex in 0..<200 {
        var frame = (0..<(sampleRate / 100)).map { _ in noise.next() }
        if frameIndex > 50 { inputEnergy += frame.reduce(0) { $0 + Double($1 * $1) } }
        #expect(process(&frame, using: denoiser))
        #expect(frame.allSatisfy { $0.isFinite && abs($0) <= 32768 })
        if frameIndex > 50 { outputEnergy += frame.reduce(0) { $0 + Double($1 * $1) } }
    }
    let reduction = 10 * log10(inputEnergy / outputEnergy)
    print("RNNoise \(sampleRate) Hz: synthetic noise attenuation \(reduction) dB; 2 s audio processed in \(start.duration(to: .now))")
    #expect(reduction > 6)
    #expect(outputEnergy > 0)
}

@Test func channelsHaveIndependentHistory() throws {
    let stereo = try #require(RNNoiseDenoiser(sampleRate: 32000, channels: 2))
    let mono = try #require(RNNoiseDenoiser(sampleRate: 32000, channels: 1))
    var noise = Noise()
    for _ in 0..<50 {
        var left = (0..<320).map { _ in noise.next() }
        var expected = left
        var right = [Float](repeating: 0, count: 320)
        #expect(process(&left, using: stereo))
        #expect(process(&right, using: stereo, channel: 1))
        #expect(process(&expected, using: mono))
        #expect(left == expected)
        #expect(right.allSatisfy { $0 == 0 })
    }
}

@Test func invalidFrameIsSilencedUntilReinitialized() throws {
    let denoiser = try #require(RNNoiseDenoiser(sampleRate: 48000, channels: 1))
    var wrongSize = [Float](repeating: 1000, count: 479)
    #expect(!process(&wrongSize, using: denoiser))
    #expect(wrongSize.allSatisfy { $0 == 0 })
    var valid = [Float](repeating: 1000, count: 480)
    #expect(!process(&valid, using: denoiser))
    #expect(valid.allSatisfy { $0 == 0 })
    let replacement = try #require(RNNoiseDenoiser(sampleRate: 48000, channels: 1))
    #expect(process(&valid, using: replacement))
}

@Test func nonfiniteInputNeverReachesTheNetwork() throws {
    for invalid: Float in [.nan, .infinity, -.infinity] {
        let denoiser = try #require(RNNoiseDenoiser(sampleRate: 16000, channels: 1))
        var frame = [Float](repeating: 1000, count: 160)
        frame[50] = invalid
        #expect(!process(&frame, using: denoiser))
        #expect(frame.allSatisfy { $0 == 0 })
    }
}

@Test func newCaptureDoesNotReusePreviousModelState() throws {
    var noise = Noise()
    do {
        let oldCapture = try #require(RNNoiseDenoiser(sampleRate: 48000, channels: 1))
        for _ in 0..<20 {
            var frame = (0..<480).map { _ in noise.next() }
            #expect(process(&frame, using: oldCapture))
        }
    }
    let newCapture = try #require(RNNoiseDenoiser(sampleRate: 16000, channels: 1))
    let reference = try #require(RNNoiseDenoiser(sampleRate: 16000, channels: 1))
    var frame = (0..<160).map { _ in noise.next() }
    var expected = frame
    #expect(process(&frame, using: newCapture))
    #expect(process(&expected, using: reference))
    #expect(frame == expected)
}
