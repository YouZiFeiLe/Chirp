import XCTest

/// Explicit opt-in: taps the real settings UI and records locally on the device.
/// The Debug entry point needs no login, room, or published audio track.
@MainActor
final class AudioSettingsUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        try XCTSkipIf(ProcessInfo.processInfo.environment["CHIRP_AUDIO_UI_CHECK"] != "1",
                      "Set CHIRP_AUDIO_UI_CHECK=1 to exercise the device microphone and settings UI")
    }

    func testStopAndListenDoesNotAlsoInvokeStop() throws {
        let app = launchSettings()
        let start = app.buttons["start-microphone-test"]
        reveal(start, in: app)
        start.tap()
        let listen = app.buttons["play-microphone-test"]
        XCTAssertTrue(listen.waitForExistence(timeout: 10))
        XCTAssertTrue(wait(for: listen, predicate: "enabled == true", timeout: 10))
        // Keep enough audio to distinguish playback from an immediate reset.
        Thread.sleep(forTimeInterval: 2)
        listen.tap()
        let playing = app.staticTexts["Playing the local microphone sample"]
        XCTAssertTrue(playing.waitForExistence(timeout: 2), app.debugDescription)
        XCTAssertFalse(start.exists)
        XCTAssertTrue(start.waitForExistence(timeout: 5))
    }

    func testReceiverAndSpeakerCanBeSelectedBeforeStartingMicrophone() throws {
        let app = launchSettings()
        let picker = app.buttons["audio-output-device"]
        reveal(picker, in: app)
        for name in ["Receiver", "Speaker", "Receiver"] {
            picker.tap()
            app.buttons[name].tap()
            let current = app.descendants(matching: .any)["audio-current-output"].firstMatch
            XCTAssertTrue(wait(for: current, predicate: "value == %@", argument: name, timeout: 3), app.debugDescription)
        }
    }

    private func launchSettings() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--audio-settings-preview", "-appLanguage", "en"]
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<8 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func wait(for element: XCUIElement, predicate: String, argument: String? = nil, timeout: TimeInterval) -> Bool {
        let condition = argument.map { NSPredicate(format: predicate, $0) } ?? NSPredicate(format: predicate)
        let expectation = XCTNSPredicateExpectation(predicate: condition, object: element)
        return XCTWaiter.wait(for: [expectation], timeout: timeout) == .completed
    }
}
