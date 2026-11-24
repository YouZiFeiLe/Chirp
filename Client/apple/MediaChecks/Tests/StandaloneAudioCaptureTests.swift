import AVFoundation
import Foundation
import Synchronization
import Testing
@testable import LiveKit

/// Run separately to preserve the cold SDK state and avoid changing another
/// test's shared audio engine. Manual rendering never accesses the microphone.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CHIRP_AUDIO_CAPTURE_CHECK"] == "1"))
struct StandaloneAudioCaptureTests {
    private final class Input: AudioEngineObserver, @unchecked Sendable {
        var next: (any AudioEngineObserver)?
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let source: AVAudioSourceNode
        init() {
            source = AVAudioSourceNode(format: format) { _, _, count, buffers in
                for buffer in UnsafeMutableAudioBufferListPointer(buffers) {
                    if let data = buffer.mData?.assumingMemoryBound(to: Float.self) {
                        data.update(repeating: 0.1, count: Int(count))
                    }
                }
                return noErr
            }
        }
        func engineDidCreate(_ engine: AVAudioEngine) -> Int { engine.attach(source); return 0 }
        func engineWillRelease(_ engine: AVAudioEngine) -> Int { engine.detach(source); return 0 }
        func engineWillConnectInput(_ engine: AVAudioEngine, src: AVAudioNode?, dst: AVAudioNode,
                                    format: AVAudioFormat, context: [AnyHashable: Any]) -> Int {
            engine.connect(source, to: dst, format: self.format)
            return 0
        }
    }

    private final class Frames: AudioRenderer, @unchecked Sendable {
        let count = Mutex(0)
        func render(pcmBuffer: AVAudioPCMBuffer) {
            if pcmBuffer.frameLength > 0 { count.withLock { $0 += 1 } }
        }
    }

    @Test func coldRecordingDeliversProcessedFramesWithoutJoiningARoom() async throws {
        let audio = AudioManager.shared, frames = Frames()
        let capture = try await audio.chirpPrepareLocalAudioCapture()
        audio.set(engineObservers: [Input()])
        try audio.setManualRenderingMode(true)
        audio.add(localAudioRenderer: frames)
        defer {
            try? audio.stopLocalRecording()
            audio.remove(localAudioRenderer: frames)
            try? audio.setManualRenderingMode(false)
            #if os(iOS)
            audio.set(engineObservers: [audio.audioSession, audio.mixer])
            #else
            audio.set(engineObservers: [audio.mixer])
            #endif
        }
        let options = AudioProcessingOptions(echoCancellation: true, autoGainControl: true, noiseSuppression: false,
            echoCancellationMode: .software, autoGainControlMode: .software, noiseSuppressionMode: .software)
        try await capture.startRecording(audioProcessingOptions: options)
        #expect(audio.audioProcessingState.echoCancellation.effective == .software)
        #expect(audio.audioProcessingState.autoGainControl.effective == .software)
        #expect(audio.audioProcessingState.noiseSuppression.effective == .disabled)
        for _ in 0..<100 {
            if frames.count.withLock({ $0 > 0 }) { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(frames.count.withLock { $0 } > 0)
        try audio.stopLocalRecording()
        #expect(!audio.isRecording && !audio.isEngineRunning)
        await capture.close()
    }
}
