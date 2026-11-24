import AVFoundation
import Foundation
import Synchronization
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
import LiveKit
#endif

@Test(arguments: [false, true])
func microphoneAuthorizationReturnsTheSystemDecision(allowed: Bool) async {
    #expect(await MicrophoneAuthorization.request { $0(allowed) } == allowed)
}

@Test func cancelledMicrophoneAuthorizationNeverStartsASystemRequest() async {
    let started = Mutex(false)
    let task = Task {
        try? await Task.sleep(for: .seconds(10))
        return await MicrophoneAuthorization.request { completion in
            started.withLock { $0 = true }
            completion(true)
        }
    }
    task.cancel()
    #expect(await task.value == false)
    #expect(!started.withLock { $0 })
}

@Test func microphoneAuthorizationCancellationDoesNotWaitForALateSystemDecision() async throws {
    let pending = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    let task = Task { await MicrophoneAuthorization.request { completion in pending.withLock { $0 = completion } } }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while pending.withLock({ $0 == nil }) {
        guard ContinuousClock.now < deadline else { task.cancel(); throw URLError(.timedOut) }
        try await Task.sleep(for: .milliseconds(1))
    }
    task.cancel()
    // This must return before we deliver the simulated system callback.
    #expect(await task.value == false)
    let completion = try #require(pending.withLock { $0 })
    completion(true)
    completion(false) // A duplicate callback must not resume the continuation twice.
}

@Test func microphoneSampleIsBoundedDecodableAndRejectsLateFramesAfterErasure() throws {
    let sample = MicrophoneSample(), frame = Array(repeating: Float(0.25), count: 8_000)
    #expect(!sample.hasFrames)
    for _ in 0..<5 { sample.append(frame, sampleRate: 8_000) }
    #expect(sample.hasFrames && sample.level > 0)
    let data = try #require(sample.finish(includeSample: true))
    #expect(data.count == 44 + 8_000 * 2 * 3)
    let player = try AVAudioPlayer(data: data)
    #expect(abs(player.duration - 3) < 0.01)
    #expect(!sample.hasFrames && sample.level == 0)
    sample.append(frame, sampleRate: 8_000)
    #expect(sample.finish(includeSample: true) == nil && sample.level == 0)
}

@Test func aSilentMicrophoneFrameStillConfirmsThatCaptureIsRunning() {
    let sample = MicrophoneSample()
    sample.append(Array(repeating: 0, count: 480), sampleRate: 48_000)
    #expect(sample.hasFrames && sample.level == 0)
    _ = sample.finish(includeSample: false)
    #expect(!sample.hasFrames)
}

#if !SWIFT_PACKAGE
/// Opt in explicitly: exercises the app's real microphone, without any room,
/// login, publication, audio file or network transport.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["CHIRP_AUDIO_HARDWARE_CHECK"] == "1"))
@MainActor struct LocalMicrophoneHardwareTests {
    #if os(iOS)
    @Test(arguments: [CallAudioOutput.system, .speaker, .receiver])
    #else
    @Test(arguments: [CallAudioOutput.system])
    #endif
    func stopAndListenStartsPlaybackAdvancesAndFinishesWithoutRecording(output: CallAudioOutput) async throws {
        var player: AVAudioPlayer?
        let hardware = LiveKitAudioHardware(makeTestPlayer: { data in
            let next = try AVAudioPlayer(data: data)
            player = next
            return next
        })
        let activation = VoiceActivationControl()
        hardware.setVoiceActivation(activation)
        let audio = CallAudioController(hardware: hardware)
        #if os(iOS)
        let deactivations = Mutex(0)
        var transitionObserver: (any NSObjectProtocol)?
        defer { if let transitionObserver { NotificationCenter.default.removeObserver(transitionObserver) } }
        #endif
        do {
            #if os(iOS)
            try await hardware.preferOutput(output)
            #endif
            try await audio.startTest(preset: .apple)
            try await Task.sleep(for: .seconds(1))
            #if os(iOS)
            transitionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.didBecomeInactiveNotification,
                object: nil, queue: .main) { _ in deactivations.withLock { $0 += 1 } }
            #endif
            await audio.cancelTest(playSample: true)?.value
            #expect(audio.testPhase == .playing, "Playback phase: \(audio.testPhase), error: \(String(describing: audio.error))")
            let playing = try #require(player, "The recorded sample was never handed to the player")
            #expect(playing.isPlaying && !activation.reading.isProcessing && !AudioManager.shared.isEngineRunning)
            try await Task.sleep(for: .milliseconds(250))
            #expect(playing.isPlaying && playing.currentTime > 0.1)
            #if os(iOS)
            #expect(deactivations.withLock { $0 } == 0, "Recording-to-playback must keep the session active")
            if let token = transitionObserver { NotificationCenter.default.removeObserver(token); transitionObserver = nil }
            #endif
            let deadline = ContinuousClock.now.advanced(by: .seconds(4))
            while audio.testPhase != .idle, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(audio.testPhase == .idle && !hardware.isTestPlaying && !playing.isPlaying)
        } catch {
            await audio.cancelTest()?.value
            throw error
        }
    }

    @Test func everyPresetMetersFromAColdStartAndStopsCleanly() async throws {
        let hardware = LiveKitAudioHardware(), activation = VoiceActivationControl()
        hardware.setVoiceActivation(activation)
        do {
            for preset in AudioPreset.allCases {
                do { try await hardware.startTest(preset: preset) }
                catch {
                    Issue.record("Preset \(preset) failed; effective state: \(await AudioPresetRuntime.observation()); error: \(error)")
                    throw error
                }
                #expect(activation.reading.isProcessing, "No capture frames for \(preset)")
                #expect(AudioManager.shared.isEngineRunning)
                try await hardware.finishTest(playSample: false)
                #expect(!activation.reading.isProcessing && !AudioManager.shared.isEngineRunning)
            }
        } catch {
            try? await hardware.finishTest(playSample: false)
            throw error
        }
    }

    #if os(iOS)
    @Test func receiverAndSpeakerWorkWhileListeningAndCapturing() async throws {
        let hardware = LiveKitAudioHardware()
        var snapshot = CallAudioSnapshot()
        hardware.onEvent = { if case let .devices(devices) = $0 { snapshot = devices } }
        await hardware.refresh()
        guard snapshot.supportsReceiver else { return }
        // Use the same session lifetime as the real settings view, before
        // joining a room or starting capture. No WebRTC engine is running.
        let releaseSettings = try hardware.acquireSettingsSession()
        defer { releaseSettings() }
        for output in [CallAudioOutput.speaker, .receiver, .speaker] {
            try await hardware.preferOutput(output)
            for _ in 0..<20 {
                await hardware.refresh()
                if snapshot.route.output == output { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            #expect(snapshot.route.output == output, "Idle selection did not reach \(output)")
            #expect(!AudioManager.shared.isEngineRunning)
        }
        let idleInputID = try #require(snapshot.inputs.first?.id)
        try await hardware.selectInput(idleInputID)
        await hardware.refresh()
        #expect(snapshot.inputID == idleInputID && !AudioManager.shared.isEngineRunning)
        try await hardware.selectInput("system")
        let requirement = try AudioManager.shared.acquireSessionRequirement(.playbackOnly)
        do {
            for output in [CallAudioOutput.receiver, .speaker, .receiver] {
                try await hardware.preferOutput(output)
                for _ in 0..<20 {
                    await hardware.refresh()
                    if snapshot.route.output == output { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
                #expect(snapshot.route.output == output)
                #expect(!AudioManager.shared.isEngineRunning)
            }
            let inputID = try #require(snapshot.inputs.first?.id)
            try await hardware.preferOutput(.system)
            try await hardware.selectInput(inputID)
            await hardware.refresh()
            #expect(snapshot.inputID == inputID && !AudioManager.shared.isEngineRunning)
            try await hardware.selectInput("system")
            for preset in [AudioPreset.apple, .webRTC] {
                try await hardware.startTest(preset: preset)
                for output in [CallAudioOutput.speaker, .receiver] {
                    try await hardware.preferOutput(output)
                    for _ in 0..<20 {
                        await hardware.refresh()
                        if snapshot.route.output == output { break }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                    #expect(snapshot.route.output == output)
                    try await AudioPresetRuntime.waitUntilApplied(preset)
                }
                try await hardware.finishTest(playSample: false)
            }
            try await hardware.preferOutput(.system)
            try requirement.release()
        } catch {
            try? await hardware.finishTest(playSample: false)
            try? await hardware.preferOutput(.system)
            try? requirement.release()
            throw error
        }
    }
    #endif
}
#endif

@Test func microphoneSampleNeverSerializesNonFiniteValuesAndDiscardingReturnsNoAudio() throws {
    let sample = MicrophoneSample()
    sample.append([.nan, .infinity, -.infinity, 9, -9], sampleRate: 48_000)
    #expect(sample.level.isFinite)
    #expect(sample.finish(includeSample: false) == nil && sample.level == 0)
    let changing = MicrophoneSample()
    changing.append(Array(repeating: 0.1, count: 8_000), sampleRate: 8_000)
    changing.append(Array(repeating: 0.2, count: 4_000), sampleRate: 16_000)
    let player = try AVAudioPlayer(data: #require(changing.finish(includeSample: true)))
    #expect(abs(player.duration - 0.25) < 0.01)
}
