import XCTest

@MainActor
final class LocalDataResetUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if !targetEnvironment(simulator)
        throw XCTSkip("Local data reset UI checks run only on an isolated simulator")
        #endif
        try XCTSkipIf(ProcessInfo.processInfo.environment["CHIRP_LOCAL_RESET_UI_CHECK"] != "1",
                      "Set CHIRP_LOCAL_RESET_UI_CHECK=1 on a dedicated test simulator")
    }

    func testLoginResetRequiresConfirmationAndReturnsToAnEmptyLogin() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-appLanguage", "en"]
        app.launch()
        let address = app.textFields["server-address"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        let draft = "invalid reset test address"
        address.typeText(draft + "\n")

        let clear = app.buttons["clear-local-data-before-login"]
        XCTAssertTrue(clear.waitForExistence(timeout: 5))
        clear.tap()
        let warning = app.alerts["Clear local data"]
        XCTAssertTrue(warning.waitForExistence(timeout: 3), app.debugDescription)
        XCTAssertTrue(warning.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "app-managed device keys")).firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Devices, friends and local settings"].exists)
        warning.buttons["Cancel"].tap()
        XCTAssertEqual(address.value as? String, draft)

        clear.tap()
        XCTAssertTrue(warning.waitForExistence(timeout: 3))
        warning.buttons["Confirm clearing all local data"].firstMatch.tap()
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", address.placeholderValue ?? ""), object: address)
        XCTAssertEqual(XCTWaiter.wait(for: [cleared], timeout: 10), .completed, app.debugDescription)
        let finished = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: clear)
        XCTAssertEqual(XCTWaiter.wait(for: [finished], timeout: 10), .completed)
        XCTAssertFalse(app.buttons["Change the password of a saved recovery file"].exists)
        XCTAssertFalse(warning.exists)
    }
}
