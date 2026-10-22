import XCTest

final class NotesSearchUITests: XCTestCase {
    func testNormalSearchFindsANoteAndAWrongPhraseDoesNotOpenTheVault() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-seed-notes"
        ]
        app.launch()

        let notesFolder = app.staticTexts["Notes"]
        XCTAssertTrue(notesFolder.waitForExistence(timeout: 8))
        notesFolder.tap()

        let grocery = app.staticTexts["Grocery list"]
        XCTAssertTrue(grocery.waitForExistence(timeout: 8))

        let search = app.textFields["Search notes"]
        XCTAssertTrue(search.waitForExistence(timeout: 4))
        search.tap()
        search.typeText("zzzzzz")

        XCTAssertTrue(app.staticTexts["No matching notes"].waitForExistence(timeout: 4))
        XCTAssertFalse(grocery.exists)
        XCTAssertFalse(app.descendants(matching: .any)["vault.home"].exists)

        if search.buttons["Clear text"].exists {
            search.buttons["Clear text"].tap()
        } else {
            search.tap()
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 8))
        }
        search.typeText("grocery")
        XCTAssertTrue(grocery.waitForExistence(timeout: 4))
        XCTAssertFalse(app.descendants(matching: .any)["vault.home"].exists)
    }

    func testSubmittedPhraseOpensTheVaultWhenBiometricsSucceed() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-biometric-success"
        ]
        // The phrase lives in the test target. Debug builds read it from the environment.
        app.launchEnvironment = ["NOTELY_UITEST_PHRASE": "harbor-lantern"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Notes"].waitForExistence(timeout: 8))
        app.staticTexts["Notes"].tap()
        let search = app.textFields["Search notes"]
        XCTAssertTrue(search.waitForExistence(timeout: 20))
        search.tap()
        search.typeText("harbor-lantern\n")

        let vault = app.buttons["vault.lock"]
        XCTAssertTrue(vault.waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Hidden Folders"].waitForExistence(timeout: 4))
    }
}
