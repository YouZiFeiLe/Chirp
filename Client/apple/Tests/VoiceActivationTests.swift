import Foundation
import Testing
#if SWIFT_PACKAGE
@testable import ChirpCore
#else
@testable import Chirp
#endif

@Test func voiceActivationDefaultsToOffAndPersistsIndependentlyOfPresets() throws {
    let suite = "ChirpVoiceActivationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    #expect(VoiceActivationSettings.load(from: defaults) == VoiceActivationSettings(enabled: false, thresholdDBFS: -45))
    let settings = VoiceActivationSettings(enabled: true, thresholdDBFS: -52)
    settings.save(to: defaults)
    for preset in AudioPreset.allCases {
        preset.save(to: defaults)
        #expect(VoiceActivationSettings.load(from: defaults) == settings)
    }
    #expect(VoiceActivationSettings.load(from: try #require(UserDefaults(suiteName: suite))) == settings)
}

@Test func invalidVoiceActivationThresholdsAreBounded() {
    #expect(VoiceActivationSettings(thresholdDBFS: -.infinity).thresholdDBFS == -45)
    #expect(VoiceActivationSettings(thresholdDBFS: .nan).thresholdDBFS == -45)
    #expect(VoiceActivationSettings(thresholdDBFS: -100).thresholdDBFS == -80)
    #expect(VoiceActivationSettings(thresholdDBFS: 100).thresholdDBFS == -10)
    #expect(VoiceActivationSettings(thresholdDBFS: -42.3).thresholdDBFS == -42)
}

@Test @MainActor func settingsAreAppliedToTheAudioControlAndMeteringDoesNotChangeThem() throws {
    let suite = "ChirpVoiceActivationTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let controller = VoiceActivationController(defaults: defaults)
    controller.setThreshold(-51)
    controller.setEnabled(true)
    #expect(controller.control.settings == VoiceActivationSettings(enabled: true, thresholdDBFS: -51))
    controller.control.publish(inputDBFS: -60, isOpen: false)
    controller.refresh()
    #expect(controller.reading.isProcessing && !controller.reading.isOpen)
    #expect(controller.reading.inputDBFS == -60 && controller.reading.level > 0)
    #expect(VoiceActivationSettings.load(from: defaults) == controller.settings)
    controller.control.resetMeter()
    controller.refresh()
    #expect(controller.reading == VoiceActivationReading())
    controller.setEnabled(false)
    #expect(controller.control.settings == VoiceActivationSettings(enabled: false, thresholdDBFS: -51))
}

@Test func audioSettingsAndReadingsRemainCoherentAcrossThreads() async {
    let control = VoiceActivationControl()
    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            for _ in 0..<10_000 {
                control.update(VoiceActivationSettings(enabled: true, thresholdDBFS: -70))
                control.update(VoiceActivationSettings(enabled: false, thresholdDBFS: -20))
            }
        }
        group.addTask {
            for _ in 0..<10_000 {
                let settings = control.settings
                #expect(settings == VoiceActivationSettings() ||
                        settings == VoiceActivationSettings(enabled: true, thresholdDBFS: -70) ||
                        settings == VoiceActivationSettings(enabled: false, thresholdDBFS: -20))
                control.publish(inputDBFS: -35, isOpen: true)
                #expect(control.reading == VoiceActivationReading(inputDBFS: -35, isProcessing: true, isOpen: true))
            }
        }
    }
}
