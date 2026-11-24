import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func appleOnlyIsAnAdditionalPresetAndTheDefaultIsUnchanged() {
    #expect(AudioPreset.allCases == [.apple, .appleOnly, .webRTC])
    #expect(AudioPreset.defaultPreset == .apple)
    #expect(AudioPreset(rawValue: "appleThenWebRTC") == nil)
}

@Test func presetSelectionPersistsAcrossNewDefaultsInstances() throws {
    let suite = "cn.youzifeile.chirp.preset-test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(AudioPreset.load(from: defaults) == .apple)
    AudioPreset.webRTC.save(to: defaults)
    let reopened = try #require(UserDefaults(suiteName: suite))
    #expect(AudioPreset.load(from: reopened) == .webRTC)
    AudioPreset.apple.save(to: reopened)
    #expect(AudioPreset.load(from: defaults) == .apple)
    AudioPreset.appleOnly.save(to: defaults)
    #expect(AudioPreset.load(from: reopened) == .appleOnly)
    defaults.set("removed-preset", forKey: AudioPreset.preferenceKey)
    #expect(AudioPreset.load(from: reopened) == .apple)
}

@Test func appleOnlyKeepsSystemProcessingAndDisablesOnlyRNNoise() {
    #expect(AudioPreset.apple.usesAppleProcessing && AudioPreset.apple.usesRNNoise)
    #expect(AudioPreset.appleOnly.usesAppleProcessing && !AudioPreset.appleOnly.usesRNNoise)
    #expect(!AudioPreset.webRTC.usesAppleProcessing && AudioPreset.webRTC.usesRNNoise)
}

@Test func activeStateMustMatchBothTheProviderAndCoupledNoiseProcessing() {
    let apple = AudioPresetObservation(echo: .apple, noise: .apple, gain: .apple,
                                       appleEchoActive: true, appleNoiseActive: true, rnnoise: .active, captureProcessorReady: true)
    #expect(apple.matches(.apple))
    #expect(!apple.matches(.appleOnly))
    #expect(!apple.matches(.webRTC))
    let appleOnly = AudioPresetObservation(echo: .apple, noise: .apple, gain: .apple,
                                           appleEchoActive: true, appleNoiseActive: true, rnnoise: .disabled, captureProcessorReady: true)
    #expect(appleOnly.matches(.appleOnly))
    #expect(!appleOnly.matches(.apple))
    #expect(!appleOnly.matches(.webRTC))
    let webRTC = AudioPresetObservation(echo: .webRTC, noise: .disabled, gain: .webRTC,
                                        appleEchoActive: false, appleNoiseActive: false, rnnoise: .active, captureProcessorReady: true)
    #expect(webRTC.matches(.webRTC))
    #expect(!webRTC.matches(.apple))
    let duplicated = AudioPresetObservation(echo: .both, noise: .apple, gain: .both,
                                            appleEchoActive: true, appleNoiseActive: true, rnnoise: .active, captureProcessorReady: true)
    #expect(!duplicated.matches(.apple))
    #expect(!duplicated.matches(.webRTC))
}

@Test func unsupportedOrUnobservablePathsAreNeverReportedAsActive() {
    let unobservable = AudioPresetObservation(echo: .unknown, noise: .unknown, gain: .unknown,
                                              appleEchoActive: false, appleNoiseActive: false, rnnoise: .active, captureProcessorReady: true)
    for preset in AudioPreset.allCases { #expect(!unobservable.matches(preset)) }
    let notRunning = AudioPresetObservation(echo: .apple, noise: .apple, gain: .apple,
                                            appleEchoActive: false, appleNoiseActive: false, rnnoise: .active, captureProcessorReady: true)
    #expect(!notRunning.matches(.apple))
    let unexpectedAppleNoise = AudioPresetObservation(echo: .webRTC, noise: .apple, gain: .webRTC,
                                                      appleEchoActive: true, appleNoiseActive: true, rnnoise: .active, captureProcessorReady: true)
    #expect(!unexpectedAppleNoise.matches(.webRTC))
}

@Test(arguments: [RNNoiseProcessingState.unknown, .initializing, .failed])
func anUnreadyOrUnknownProcessorCannotConfirmAnyPreset(_ rnnoise: RNNoiseProcessingState) {
    let apple = AudioPresetObservation(echo: .apple, noise: .apple, gain: .apple,
                                       appleEchoActive: true, appleNoiseActive: true, rnnoise: rnnoise, captureProcessorReady: true)
    let webRTC = AudioPresetObservation(echo: .webRTC, noise: .disabled, gain: .webRTC,
                                        appleEchoActive: false, appleNoiseActive: false, rnnoise: rnnoise, captureProcessorReady: true)
    for preset in AudioPreset.allCases {
        #expect(!apple.matches(preset))
        #expect(!webRTC.matches(preset))
    }
}

@Test func disablingRNNoiseDoesNotMakeMissingAppleProcessingAcceptable() {
    let missingNoise = AudioPresetObservation(echo: .apple, noise: .disabled, gain: .apple,
                                              appleEchoActive: true, appleNoiseActive: false, rnnoise: .disabled, captureProcessorReady: true)
    let duplicated = AudioPresetObservation(echo: .both, noise: .apple, gain: .both,
                                            appleEchoActive: true, appleNoiseActive: true, rnnoise: .disabled, captureProcessorReady: true)
    #expect(!missingNoise.matches(.appleOnly))
    #expect(!duplicated.matches(.appleOnly))
}

@Test func evenAppleOnlyRequiresAnInitializedCaptureProcessor() {
    let missing = AudioPresetObservation(echo: .apple, noise: .apple, gain: .apple,
                                        appleEchoActive: true, appleNoiseActive: true,
                                        rnnoise: .disabled, captureProcessorReady: false)
    #expect(!missing.matches(.appleOnly))
}
