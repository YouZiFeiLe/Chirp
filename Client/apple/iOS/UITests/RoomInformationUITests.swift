import XCTest

@MainActor
final class RoomInformationUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Room information fixtures run on an isolated simulator")
        #endif
    }

    func testRoomShowsConfiguredDescriptionBeforeJoining() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "en"]
        app.launch()
        let room = app.buttons["voice-room-friends"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()
        XCTAssertTrue(app.staticTexts["周五晚八点，一起听歌。"].waitForExistence(timeout: 5))
    }

    func testRoomToolbarOpensAudioSettingsDirectly() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "en"]
        app.launch()
        let room = app.buttons["voice-room-friends"]
        XCTAssertTrue(room.waitForExistence(timeout: 10))
        room.tap()

        let audio = app.buttons["room-audio-settings"]
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["room-options"].exists)
        audio.tap()
        XCTAssertTrue(app.buttons["apply-audio-preset"].waitForExistence(timeout: 5))
    }

    func testEmptyRoomShowsTheEntireAudioCardAboveTheJoinControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "zh-Hans"]
        app.launch()
        let room = app.buttons["voice-room-room-3"]
        XCTAssertTrue(room.waitForExistence(timeout: 8))
        reveal(room, in: app)
        room.tap()

        let audio = app.buttons["audio-preset-settings"]
        let controls = app.descendants(matching: .any)["room-call-controls"].firstMatch
        XCTAssertTrue(audio.waitForExistence(timeout: 5))
        XCTAssertTrue(controls.exists)
        XCTAssertGreaterThan(audio.frame.height, 44)
        XCTAssertLessThanOrEqual(audio.frame.maxY, controls.frame.minY)
        if app.frame.height >= 900 && app.frame.width < app.frame.height {
            let title = app.staticTexts["林间还很安静"]
            XCTAssertTrue(title.exists)
            XCTAssertEqual(title.frame.midX, audio.frame.midX, accuracy: 2)
        }
        audio.tap()
        XCTAssertTrue(app.buttons["apply-audio-preset"].waitForExistence(timeout: 5))
    }

    func testPublicInformationStatesDoNotInventCompletedRotations() {
        let app = launch()
        let entry = app.buttons["room-information"]
        let panel = app.descendants(matching: .any)["room-public-information"].firstMatch
        let close = app.buttons["close-room-information"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        XCTAssertFalse(panel.exists)
        for (scenario, expected) in [("Room status awaiting sync", "Unknown for now"),
                                      ("Waiting for identity verification", "Scheduled after verification"),
                                      ("Rotating keys", "Waiting for everyone to finish")] {
            selectScenario(scenario, in: app)
            entry.tap()
            XCTAssertTrue(panel.waitForExistence(timeout: 3), app.debugDescription)
            let next = app.descendants(matching: .any)["room-next-rotation"].firstMatch
            XCTAssertTrue(next.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(next.label.contains(expected), app.debugDescription)
            close.tap()
            XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
        }
        selectScenario("Normal call", in: app)
        entry.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        let last = panel.descendants(matching: .any)["room-last-rotation"].firstMatch
        XCTAssertTrue(last.label.contains("Last full-room key rotation"), app.debugDescription)
        attach("room-public-information-light", app: app)
        let encryption = app.buttons["Encryption and key rotation"]
        let coverage = panel.descendants(matching: .any)["room-encryption-coverage"].firstMatch
        XCTAssertFalse(coverage.exists)
        reveal(encryption, in: app)
        encryption.tap()
        XCTAssertTrue(coverage.waitForExistence(timeout: 3), app.debugDescription)
        close.tap()
        app.switches["room-preview-dark"].tap()
        entry.tap()
        XCTAssertTrue(panel.waitForExistence(timeout: 3))
        attach("room-public-information-dark", app: app)
    }

    func testPublicInformationFitsRoomRulesBeforeJoining() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "en"]
        app.launch()
        app.buttons["voice-room-friends"].tap()
        app.buttons["room-information"].tap()

        let panel = app.descendants(matching: .any)["room-public-information"].firstMatch
        let close = app.buttons["close-room-information"]
        let rules = app.buttons["Room rules"]
        XCTAssertTrue(rules.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["room-public-status"].label.contains("Join to view security status"))
        let compactHeight = panel.frame.height
        XCTAssertLessThan(compactHeight, app.frame.height / 2)
        attach("room-information-outside-collapsed", app: app)

        rules.tap()
        let resized = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            panel.frame.height > compactHeight + 24
        }, object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [resized], timeout: 4), .completed, app.debugDescription)
        XCTAssertTrue(close.isHittable)
        attach("room-information-outside-expanded", app: app)
        rules.tap()
        let collapsed = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            abs(panel.frame.height - compactHeight) < 2
        }, object: panel)
        XCTAssertEqual(XCTWaiter.wait(for: [collapsed], timeout: 4), .completed, app.debugDescription)
        close.tap()
        XCTAssertTrue(panel.waitForNonExistence(timeout: 3))
    }

    func testVerificationBannerStaysVisibleAndOpensTheRightDevice() {
        let app = launch()
        let title = app.staticTexts["room-verification-title"]
        let verifySingle = app.buttons["room-verify-single-device"]
        let verifyMenu = app.buttons["room-verify-device-menu"]
        XCTAssertFalse(title.exists)

        selectScenario("Waiting for identity verification", in: app)
        XCTAssertTrue(title.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertEqual(title.label, "Voice and chat paused")
        XCTAssertTrue(verifySingle.label.contains("小林"))
        attach("room-verification-banner-light", app: app)
        let bannerY = title.frame.minY
        let scroll = app.scrollViews["preview-room-scroll"]
        let card = app.buttons["room-information"]
        let previousCardY = card.frame.minY
        scroll.swipeUp()
        XCTAssertLessThan(card.frame.minY, previousCardY, app.debugDescription)
        XCTAssertEqual(title.frame.minY, bannerY, accuracy: 1, app.debugDescription)
        XCTAssertTrue(verifySingle.isHittable, app.debugDescription)
        verifySingle.tap()
        let close = app.buttons["close-sas-verification"]
        XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["小林"].exists)
        close.tap()

        selectScenario("Multiple devices to verify", in: app)
        XCTAssertGreaterThanOrEqual(verifyMenu.frame.height, 44)
        attach("room-verification-device-selector", app: app)
        verifyMenu.tap()
        app.buttons["Alex"].tap()
        XCTAssertTrue(close.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Alex"].exists)
        close.tap()

        selectScenario("Waiting for other members", in: app)
        XCTAssertTrue(app.staticTexts["room-verification-detail"].label.contains("You’ve verified"), app.debugDescription)
        XCTAssertFalse(verifySingle.exists || verifyMenu.exists)
        app.switches["room-preview-dark"].tap()
        attach("room-verification-banner-dark", app: app)

        selectScenario("Normal call", in: app)
        XCTAssertFalse(title.exists)
    }

    func testBusyVerificationOffersAnotherInvitationOrReturnToRoom() {
        let app = XCUIApplication()
        app.launchArguments = ["--device-verification-preview", "--verification-busy", "-appLanguage", "zh-Hans"]
        app.launch()
        let title = app.staticTexts["sas-step-title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "对方正忙")
        let invite = app.buttons["sas-primary-action"]
        XCTAssertEqual(invite.label, "重新邀请")
        XCTAssertEqual(app.buttons["sas-secondary-action"].label, "返回房间")
        invite.tap()
        XCTAssertEqual(title.label, "等待朋友接受邀请")
    }

    func testMemberVolumeAndProgressiveDetails() {
        let app = launch()
        let member = app.buttons["preview-member-information"]
        selectScenario("Waiting for identity verification", in: app)
        XCTAssertTrue(member.label.contains("Microphone muted"), member.label)
        XCTAssertTrue(member.label.contains("Room playback is paused"), member.label)
        selectScenario("Normal call", in: app)
        reveal(member, in: app)
        XCTAssertTrue(member.label.contains("Microphone on"), member.label)
        XCTAssertTrue(member.label.contains("Room playback is on"), member.label)
        member.tap()
        let slider = app.sliders["member-playback-volume"]
        XCTAssertTrue(slider.waitForExistence(timeout: 5), app.debugDescription)
        attach("member-information-default", app: app)
        slider.adjust(toNormalizedSliderPosition: 0.75)
        app.buttons["member-local-mute"].tap()
        XCTAssertEqual(app.staticTexts["member-volume-value"].label, "0%")
        XCTAssertEqual(app.descendants(matching: .any)["member-microphone-state"].firstMatch.label, "Microphone on")
        XCTAssertEqual(app.descendants(matching: .any)["member-listening-state"].firstMatch.label, "Room playback is on")
        app.buttons["member-local-mute"].tap()
        XCTAssertNotEqual(app.staticTexts["member-volume-value"].label, "0%")
        app.buttons["member-volume-reset"].tap()
        XCTAssertEqual(app.staticTexts["member-volume-value"].label, "100%")
        let details = app.buttons["Connection details"]
        reveal(details, in: app)
        details.tap()
        XCTAssertTrue(app.staticTexts["32.0 ms"].exists, app.debugDescription)
        let identity = app.buttons["Friends and device"]
        reveal(identity, in: app)
        identity.tap()
        let full = app.buttons["member-full-fingerprint"]
        reveal(full, in: app)
        full.tap()
        XCTAssertTrue(app.buttons["Hide full device fingerprint"].waitForExistence(timeout: 3), app.debugDescription)
        reveal(full, in: app)
        attach("member-information-expanded", app: app)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--room-information-preview", "-appLanguage", "en"]
        app.launch()
        return app
    }

    private func selectScenario(_ name: String, in app: XCUIApplication) {
        app.buttons["room-preview-scenario"].tap()
        app.buttons[name].tap()
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
