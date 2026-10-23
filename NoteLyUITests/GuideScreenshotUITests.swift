import XCTest

/// Photographs the private screens. Everyday screens are captured separately.
final class GuideScreenshotUITests: XCTestCase {
    func testCaptureVault() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-open-vault"
        ]
        app.launchEnvironment = ["NOTELY_UITEST_PHRASE": "harbor-lantern"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Hidden Folders"].waitForExistence(timeout: 12))
        snap("09-vault")

        app.staticTexts["Notes"].firstMatch.tap()
        if app.staticTexts["Travel plans"].waitForExistence(timeout: 8) {
            snap("10-private-notes")
            app.staticTexts["Travel plans"].tap()
            sleep(1)
            snap("11-private-note")
            app.navigationBars.buttons.element(boundBy: 0).tap()
        } else {
            snap("10-private-notes")
        }
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.staticTexts["Files"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 6))
        sleep(1)
        snap("12-files")
        app.navigationBars["Files"].buttons.element(boundBy: 0).tap()

        app.navigationBars["Hidden Folders"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Private Settings"].waitForExistence(timeout: 6))
        sleep(1)
        snap("13-private-settings")
    }

    func testCapturePrivateSettings() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-open-vault"
        ]
        app.launchEnvironment = ["NOTELY_UITEST_PHRASE": "harbor-lantern"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Hidden Folders"].waitForExistence(timeout: 12))
        app.navigationBars["Hidden Folders"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Private Settings"].waitForExistence(timeout: 6))
        sleep(1)

        let copyright = app.staticTexts["© 2026 DK Technologies Inc."]
        for index in 1...8 {
            snap("settings-\(index)")
            if copyright.isHittable { break }
            let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.78))
            let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.40))
            start.press(forDuration: 0.05, thenDragTo: end)
            sleep(1)
        }
    }

    func testCaptureFilesGuide() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-open-vault"
        ]
        app.launchEnvironment = ["NOTELY_UITEST_PHRASE": "harbor-lantern"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Hidden Folders"].waitForExistence(timeout: 12))
        XCTAssertTrue(app.staticTexts["3"].waitForExistence(timeout: 8))
        snap("09-vault")

        app.staticTexts["Files"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Trip"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Harbor.jpg"].waitForExistence(timeout: 8))
        sleep(1)
        snap("12-files")

        app.buttons["Trip, 1"].tap()
        XCTAssertTrue(app.buttons["Sunset.jpg"].waitForExistence(timeout: 6))
        sleep(1)
        snap("12-trip")
        app.buttons["Files"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Harbor.jpg"].waitForExistence(timeout: 6))

        app.buttons["Add"].tap()
        app.buttons["Photos or Videos"].tap()
        XCTAssertTrue(app.staticTexts["Move removes the original. Copy leaves it where it is."].waitForExistence(timeout: 6))
        sleep(1)
        snap("18-move-copy")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.72)).tap()
        sleep(1)

        let photo = app.buttons["Harbor.jpg"]
        XCTAssertTrue(photo.waitForExistence(timeout: 4))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1.5)
        sleep(1)
        snap("19-photo-menu")
    }

    func testCaptureDarkTheme() {
        XCUIDevice.shared.appearance = .dark
        let app = XCUIApplication()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-seed-notes"
        ]
        app.launch()

        XCTAssertTrue(app.staticTexts["Folders"].waitForExistence(timeout: 12))
        sleep(1)
        snap("dark-folders")

        if app.staticTexts["Notes"].firstMatch.waitForExistence(timeout: 4) {
            app.staticTexts["Notes"].firstMatch.tap()
        }
        if app.staticTexts["Grocery list"].waitForExistence(timeout: 6) {
            sleep(1)
            snap("dark-notes")
            app.staticTexts["Grocery list"].tap()
            sleep(1)
            snap("dark-note")
        }

        app.terminate()
        app.launchArguments = [
            "-ui-testing",
            "-ui-testing-skip-onboarding",
            "-ui-testing-open-vault"
        ]
        app.launchEnvironment = ["NOTELY_UITEST_PHRASE": "harbor-lantern"]
        app.launch()

        XCTAssertTrue(app.staticTexts["Hidden Folders"].waitForExistence(timeout: 12))
        sleep(1)
        snap("dark-hidden")
        app.staticTexts["Files"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Files"].waitForExistence(timeout: 6))
        sleep(1)
        snap("dark-files")
        XCUIDevice.shared.appearance = .light
    }

    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
