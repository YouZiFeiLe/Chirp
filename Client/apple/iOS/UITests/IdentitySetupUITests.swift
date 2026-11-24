import XCTest

/// Exercises identity setup and settings with offline fixtures.
@MainActor
final class IdentitySetupUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Recovery setup UI checks use an isolated simulator")
        #endif
    }

    func testMatchingPasswordsPresentGenerationConfirmation() throws {
        let app = launch()
        let password = app.secureTextFields["recovery-new-password"]
        XCTAssertTrue(password.waitForExistence(timeout: 10), app.debugDescription)
        password.tap()
        password.typeText("Chirp recovery UI test password")
        let confirmation = app.secureTextFields["recovery-confirm-password"]
        reveal(confirmation, in: app)
        confirmation.tap()
        confirmation.typeText("Chirp recovery UI test password")
        let next = app.buttons["prepare-recovery-file"]
        reveal(next, in: app)
        next.tap()
        let dialog = app.alerts["Generate a recovery file?"]
        XCTAssertTrue(dialog.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(dialog.buttons["Generate and save"].exists)
        dialog.buttons["Review password"].tap()
        XCTAssertTrue(password.exists)
        XCTAssertFalse(app.buttons["select-backup-to-verify"].exists)
        reveal(next, in: app)
        next.tap()
        XCTAssertTrue(dialog.waitForExistence(timeout: 3))
        dialog.buttons["Generate and save"].tap()
        let systemCancel = app.buttons.matching(NSPredicate(
            format: "(label == %@ OR label == %@) AND identifier != %@",
            "Cancel", "取消", "cancel-identity-setup")).firstMatch
        XCTAssertTrue(systemCancel.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertFalse(app.buttons["select-backup-to-verify"].exists)
        attach("recovery-system-save-panel", app: app)
        systemCancel.tap()
        XCTAssertTrue(app.buttons["export-recovery-file"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["select-backup-to-verify"].exists)
    }

    func testImportStartsWithFileSelectionAndNoPasswordField() throws {
        let app = launch(["--recovery-authorize", "--recovery-dark"])
        XCTAssertTrue(app.buttons["select-recovery-file"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.secureTextFields.count, 0)
        XCTAssertFalse(app.buttons["confirm-recovery-password"].exists)
        attach("recovery-import-dark", app: app)
    }

    func testSavedFileShowsOptionalCheckAndRequiresFinalConfirmation() throws {
        let app = launch(["--recovery-saved"])
        XCTAssertTrue(app.buttons["select-backup-to-verify"].waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertEqual(app.secureTextFields.count, 0)
        app.buttons["continue-after-recovery-save"].tap()
        let finish = app.buttons["confirm-recovery-backup"]
        XCTAssertTrue(finish.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertFalse(finish.isEnabled)
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: finish)
        XCTAssertEqual(XCTWaiter.wait(for: [ready], timeout: 8), .completed)
        let back = app.buttons["save-recovery-again"]
        reveal(back, in: app)
        back.tap()
        XCTAssertTrue(app.buttons["select-backup-to-verify"].waitForExistence(timeout: 3))
    }

    func testDeviceAuthorizationSavesPNGToPhotos() throws {
        let app = launch(["--recovery-authorize"])
        XCTAssertTrue(app.buttons["select-recovery-file"].waitForExistence(timeout: 10))
        let start = app.buttons["start-device-pairing"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        reveal(start, in: app); start.tap()
        let qr = app.descendants(matching: .any)["device-pairing-qr"]
        XCTAssertTrue(qr.waitForExistence(timeout: 10), app.debugDescription)
        let export = app.buttons["export-device-pairing-png"]
        reveal(export, in: app)
        XCTAssertTrue(export.isEnabled)
        XCTAssertEqual(export.label, "Save QR code to Photos")
        XCTAssertFalse(app.buttons["confirm-new-device-pairing-code"].exists)
        attach("device-authorization-qr-light", app: app)
        export.tap()
        let prompt = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch
        if prompt.waitForExistence(timeout: 3) {
            let allow = prompt.buttons.matching(NSPredicate(format: "label IN %@",
                ["Allow", "Allow Adding Photos", "允许", "允许添加照片"])).firstMatch
            XCTAssertTrue(allow.exists, prompt.debugDescription)
            allow.tap()
        }
        let saved = app.descendants(matching: .any)["device-pairing-photo-saved"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10), app.debugDescription)
        XCTAssertTrue(qr.exists)
    }

    func testDeviceAuthorizationCanCancelWithoutASecondDevice() throws {
        let app = launch(["--recovery-authorize", "--recovery-dark"])
        let start = app.buttons["start-device-pairing"]
        XCTAssertTrue(start.waitForExistence(timeout: 10), app.debugDescription)
        reveal(start, in: app); start.tap()
        XCTAssertTrue(app.buttons["export-device-pairing-png"].waitForExistence(timeout: 10))
        let cancel = app.buttons["Cancel this device authorization"]
        reveal(cancel, in: app)
        attach("device-authorization-qr-dark", app: app)
        cancel.tap()
        XCTAssertTrue(app.buttons["start-device-pairing"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["confirm-new-device-pairing-code"].exists)
    }

    func testAuthorizeNewDeviceIsASeparateSettingsEntry() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "en"]
        app.launch()
        let settings = app.buttons["open-account-settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 10))
        settings.tap()

        let authorize = app.buttons["authorize-device-settings-action"]
        let local = app.buttons["local-identity-settings-action"]
        for _ in 0..<5 {
            if authorize.isHittable && local.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(authorize.isHittable && local.isHittable, app.debugDescription)
        XCTAssertFalse(app.buttons["connection-settings"].exists)
        authorize.tap()

        let scan = app.buttons["scan-device-pairing-qr"]
        let importImage = app.buttons["import-device-pairing-image"]
        let reset = app.buttons["reset-local-identity"]
        XCTAssertTrue(scan.waitForExistence(timeout: 5))
        XCTAssertTrue(importImage.exists)
        XCTAssertFalse(reset.exists)
        app.buttons["Done"].tap()

        local.tap()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        XCTAssertFalse(scan.exists)
        XCTAssertFalse(importImage.exists)
    }

    private func launch(_ arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--identity-setup-preview", "-appLanguage", "en"] + arguments
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["identity-setup-scroll"]
        for _ in 0..<16 {
            if element.isHittable { return }
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTAssertTrue(element.isHittable, app.debugDescription)
    }

    private func attach(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
