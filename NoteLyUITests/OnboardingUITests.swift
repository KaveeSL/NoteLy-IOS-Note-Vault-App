import XCTest

final class OnboardingUITests: XCTestCase {
    func testHappyPathReachesTheNotesList() {
        let app = launch(extra: ["-ui-testing-biometric-success"])
        tapContinue(app)
        fillPhrase(app)
        tapContinue(app)
        enterPin(app, "246810")
        enterPin(app, "246810")
        tapContinue(app)
        XCTAssertTrue(app.staticTexts["Face ID"].waitForExistence(timeout: 4))
        tapContinue(app)
        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: 8))
    }

    func testSetupCannotBeSkipped() {
        let app = launch()
        XCTAssertTrue(app.buttons["Get Started"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["onboarding.later"].exists)
        XCTAssertFalse(app.staticTexts["Folders"].exists)
    }

    func testFaceIDUnavailableCanContinue() {
        let app = launch(extra: ["-ui-testing-biometrics-off"])
        tapContinue(app)
        fillPhrase(app)
        tapContinue(app)
        enterPin(app, "246810")
        enterPin(app, "246810")
        tapContinue(app)
        XCTAssertTrue(app.staticTexts["Face ID isn't available here. Your code is enough."].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["onboarding.continue"].isEnabled)
    }

    func testKillAndRelaunchResumesThePhraseStep() {
        let app = launch()
        tapContinue(app)
        XCTAssertTrue(app.textFields["onboarding.phrase"].waitForExistence(timeout: 4) || app.secureTextFields["onboarding.phrase"].waitForExistence(timeout: 4))
        app.terminate()
        let again = launch(reset: false)
        let secure = again.secureTextFields["onboarding.phrase"]
        let plain = again.textFields["onboarding.phrase"]
        XCTAssertTrue(secure.waitForExistence(timeout: 8) || plain.waitForExistence(timeout: 2))
    }

    private func launch(extra: [String] = [], reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        var arguments = ["-ui-testing"]
        if reset { arguments.append("-ui-testing-reset-onboarding") }
        app.launchArguments = arguments + extra
        app.launch()
        return app
    }

    private func tapContinue(_ app: XCUIApplication) {
        let button = app.buttons["onboarding.continue"]
        XCTAssertTrue(button.waitForExistence(timeout: 4))
        button.tap()
    }

    private func fillPhrase(_ app: XCUIApplication) {
        let first = app.secureTextFields["onboarding.phrase"]
        XCTAssertTrue(first.waitForExistence(timeout: 4))
        first.tap()
        first.typeText("cedar-harbor")
        app.swipeUp()
        let second = app.secureTextFields["onboarding.phraseConfirm"]
        second.tap()
        second.typeText("cedar-harbor")
    }

    private func enterPin(_ app: XCUIApplication, _ code: String) {
        for character in code {
            app.buttons[String(character)].tap()
        }
    }
}
