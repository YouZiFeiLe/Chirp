import XCTest

@MainActor
final class LanguageUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Language UI checks run on a simulator")
        #endif
    }

    func testServerAddressOpensLowercaseLatinKeyboardInChinese() {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "zh-Hans"]
        app.launch()
        let field = app.textFields["server-address"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        let keys = app.keyboards.firstMatch.keys
        XCTAssertTrue(keys["q"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(keys["a"].exists && keys["z"].exists)
        XCTAssertFalse(keys["/"].exists)
        let address = "room42.example:8443"
        field.typeText(address)
        XCTAssertTrue((field.value as? String)?.contains(address) == true)
        attach("login-address-keyboard")
    }

    func testLanguageSettingsRowOpensAllChoices() {
        let app = XCUIApplication()
        app.launchArguments = ["--design-preview", "-appLanguage", "zh-Hans"]
        app.launch()
        app.buttons["open-account-settings"].tap()
        let language = app.buttons["app-language-picker"]
        XCTAssertTrue(language.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(language.label, "界面语言")
        XCTAssertEqual(language.value as? String, "简体中文")
        XCTAssertGreaterThanOrEqual(language.frame.height, 44)
        attach("settings-language-row")
        language.tap()
        for name in ["简体中文", "English", "跟随系统"] {
            XCTAssertTrue(app.buttons[name].exists, app.debugDescription)
        }
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
