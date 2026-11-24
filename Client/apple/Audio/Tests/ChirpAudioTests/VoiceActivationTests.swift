import ChirpAudio
import Foundation
import Testing

private func levelFrame(_ db: Double, rate: Int = 48_000) -> [Float] {
    [Float](repeating: Float(32_768 * pow(10, db / 20)), count: rate / 100)
}

private func capture(_ samples: inout [Float], using pipeline: CaptureAudioPipeline,
                     enabled: Bool = true, threshold: Double = -45) -> VoiceActivationResult? {
    let count = samples.count
    return samples.withUnsafeMutableBufferPointer { buffer in
        pipeline.process(frames: count, channels: 1, enabled: enabled, thresholdDBFS: threshold,
                         channelData: { _ in buffer.baseAddress! })
    }
}

@Test(arguments: [8_000, 16_000, 32_000, 44_100, 48_000, 96_000, 192_000])
func quietAudioIsSilencedButMeterSeesTheInput(rate: Int) throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: rate, channels: 1, usesRNNoise: false))
    var frame = levelFrame(-60, rate: rate)
    let reading = try #require(capture(&frame, using: pipeline))
    #expect(!reading.isOpen)
    #expect(abs(reading.inputDBFS + 60) < 0.01)
    #expect(frame.allSatisfy { $0 == 0 })
}

@Test func activationUsesHysteresisAndAQuarterSecondHold() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: false))
    var frame = levelFrame(-47)
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    frame = levelFrame(-35)
    #expect(capture(&frame, using: pipeline)?.isOpen == true)
    // Attack ramps up over several samples and then reaches unity.
    #expect(frame.first! > 0 && frame.first! < frame.last!)
    #expect(abs(frame.last! - levelFrame(-35).last!) < 0.001)
    for _ in 0..<40 {
        frame = levelFrame(-47)
        #expect(capture(&frame, using: pipeline)?.isOpen == true)
    }
    for _ in 0..<24 {
        frame = levelFrame(-60)
        #expect(capture(&frame, using: pipeline)?.isOpen == true)
    }
    frame = levelFrame(-60)
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    #expect(frame.first! > 0 && frame.last! == 0) // Release also ramps.
    frame = levelFrame(-60)
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    #expect(frame.allSatisfy { $0 == 0 })
}

@Test func disablingIsTransparentAndReenablingStartsClosed() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: false))
    var frame = levelFrame(-30)
    #expect(capture(&frame, using: pipeline)?.isOpen == true)
    let original = levelFrame(-60)
    frame = original
    #expect(capture(&frame, using: pipeline, enabled: false) != nil)
    #expect(frame == original)
    frame = original
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    #expect(frame.allSatisfy { $0 == 0 })
}

@Test func thresholdsChangeWithoutReinitializingCapture() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: false))
    var frame = levelFrame(-50)
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    frame = levelFrame(-50)
    #expect(capture(&frame, using: pipeline, threshold: -55)?.isOpen == true)
    pipeline.resetGate()
    frame = levelFrame(-50)
    #expect(capture(&frame, using: pipeline)?.isOpen == false)
    #expect(frame.allSatisfy { $0 == 0 })
}

@Test func stereoChannelsShareTheGateWithoutPhaseCancellation() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 2, usesRNNoise: false))
    var left = levelFrame(-42), right = left.map { -$0 }
    let result = left.withUnsafeMutableBufferPointer { a in
        right.withUnsafeMutableBufferPointer { b in
            pipeline.process(frames: 480, channels: 2, enabled: true, thresholdDBFS: -45,
                             channelData: { $0 == 0 ? a.baseAddress! : b.baseAddress! })
        }
    }
    #expect(result?.isOpen == true)
    #expect(abs(try #require(result?.inputDBFS) + 42) < 0.01)
    #expect(zip(left, right).allSatisfy { $0 == -$1 })
}

@Test func aSingleActiveStereoChannelCanActivateBothChannels() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 2, usesRNNoise: false))
    var left = levelFrame(-44), right = [Float](repeating: 0, count: 480)
    let result = left.withUnsafeMutableBufferPointer { a in
        right.withUnsafeMutableBufferPointer { b in
            pipeline.process(frames: 480, channels: 2, enabled: true, thresholdDBFS: -45,
                             channelData: { $0 == 0 ? a.baseAddress! : b.baseAddress! })
        }
    }
    #expect(result?.isOpen == true)
    #expect(right.allSatisfy { $0 == 0 })
}

@Test func aClosedGatePreservesRNNoiseHistoryAndDisablingRestoresItsExactOutput() throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: true))
    let reference = try #require(RNNoiseDenoiser(sampleRate: 48_000, channels: 1))
    for frameIndex in 0..<60 {
        var frame = (0..<480).map { Float(4_000 * sin(Double(frameIndex * 480 + $0) * 2 * .pi * 220 / 48_000)) }
        var expected = frame
        #expect(expected.withUnsafeMutableBufferPointer { reference.process($0, channel: 0) })
        let reading = try #require(capture(&frame, using: pipeline, enabled: frameIndex < 40, threshold: -10))
        if frameIndex < 40 {
            #expect(!reading.isOpen)
            #expect(frame.allSatisfy { $0 == 0 })
        } else {
            #expect(frame == expected)
        }
    }
}

@Test(arguments: [false, true])
func invalidAudioFailsClosedUntilANewPipelineIsCreated(usesRNNoise: Bool) throws {
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: usesRNNoise))
    var frame = levelFrame(-30)
    frame[25] = .nan
    #expect(capture(&frame, using: pipeline, enabled: false) == nil)
    #expect(frame.allSatisfy { $0 == 0 })
    frame = levelFrame(-30)
    #expect(capture(&frame, using: pipeline, enabled: false) == nil)
    #expect(frame.allSatisfy { $0 == 0 })
}

@Test func invalidFormatsDoNotBypassThePipeline() throws {
    #expect(CaptureAudioPipeline(sampleRate: 0, channels: 1, usesRNNoise: false) == nil)
    #expect(CaptureAudioPipeline(sampleRate: 48_000, channels: 3, usesRNNoise: false) == nil)
    #expect(CaptureAudioPipeline(sampleRate: 44_100, channels: 1, usesRNNoise: true) == nil)
    let pipeline = try #require(CaptureAudioPipeline(sampleRate: 48_000, channels: 1, usesRNNoise: false))
    var frame = [Float](repeating: 1_000, count: 479)
    #expect(capture(&frame, using: pipeline) == nil)
    #expect(frame.allSatisfy { $0 == 0 })
}
