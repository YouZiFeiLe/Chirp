import XCTest

@MainActor
final class ProfileEditUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("The offline profile editor fixture runs on a simulator.")
        #endif
    }

    func testNicknameValidationPreviewAndSave() {
        let app = openEditor()
        let save = app.buttons["save-profile"]
        let field = app.textFields["profile-nickname"]
        XCTAssertFalse(save.isEnabled)
        field.tap()
        app.buttons["clear-profile-nickname"].tap()
        XCTAssertTrue(app.staticTexts["Enter a nickname."].exists)
        XCTAssertFalse(save.isEnabled)

        field.typeText(String(repeating: "a", count: 81))
        XCTAssertTrue(app.staticTexts["Shorten your nickname to 80 characters or fewer."].exists)
        XCTAssertFalse(save.isEnabled)
        app.buttons["clear-profile-nickname"].tap()
        field.typeText("River")
        XCTAssertEqual(app.buttons["change-profile-avatar"].value as? String, "River")
        save.tap()
        let profile = app.buttons["profile-settings"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, "River")
        profile.tap()
        XCTAssertEqual(field.value as? String, "River")
        XCTAssertFalse(save.isEnabled)
    }

    func testCancelRetainsDraftUntilDiscardConfirmed() {
        let app = openEditor()
        let field = app.textFields["profile-nickname"]
        let original = field.value as? String
        field.tap()
        app.buttons["clear-profile-nickname"].tap()
        field.typeText("Draft")
        app.buttons["cancel-profile-edits"].tap()
        app.buttons["Keep editing"].tap()
        XCTAssertEqual(field.value as? String, "Draft")
        app.buttons["cancel-profile-edits"].tap()
        app.buttons["Discard changes"].tap()
        let profile = app.buttons["profile-settings"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        XCTAssertEqual(profile.value as? String, original)
    }

    func testPhotoSourcesAndCancelledFileSelection() {
        let app = openEditor(language: "zh-Hans")
        let field = app.textFields["profile-nickname"]
        let original = field.value as? String
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Profile editor – iPhone"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["change-profile-avatar"].tap()
        XCTAssertTrue(app.buttons["choose-avatar-photo"].exists)
        app.buttons["choose-avatar-file"].tap()
        let cancel = app.buttons.matching(NSPredicate(format:
            "(label IN %@ OR identifier == 'DOC.cancelButton') AND identifier != 'cancel-profile-edits'",
            ["Cancel", "取消", "Close", "关闭"])).firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 8), app.debugDescription)
        cancel.tap()
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertEqual(field.value as? String, original)
        XCTAssertFalse(app.buttons["save-profile"].isEnabled)
    }

    func testLargeTextKeepsNicknameAndSaveReachable() {
        let app = openEditor(language: "zh-Hans", arguments: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-AppleInterfaceStyle", "Dark"
        ])
        let field = app.textFields["profile-nickname"]
        let editor = app.scrollViews.containing(.textField, identifier: "profile-nickname").firstMatch
        if !field.isHittable { editor.swipeUp() }
        XCTAssertTrue(field.isHittable)
        field.tap()
        app.buttons["clear-profile-nickname"].tap()
        field.typeText("River")
        XCTAssertTrue(app.buttons["save-profile"].isHittable)
        app.buttons["save-profile"].tap()
        XCTAssertEqual(app.buttons["profile-settings"].value as? String, "River")
    }

    private func openEditor(language: String = "en", arguments: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", language] + arguments
        app.launch()
        app.buttons["open-account-settings"].tap()
        let profile = app.buttons["profile-settings"]
        XCTAssertTrue(profile.waitForExistence(timeout: 5))
        profile.tap()
        XCTAssertTrue(app.textFields["profile-nickname"].waitForExistence(timeout: 5))
        return app
    }
}
