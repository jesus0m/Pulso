import XCTest

final class DashboardTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testDemoPortraitLandscapeAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.staticTexts["demoBanner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["GitHub Copilot"].exists)
        saveScreenshot("portrait-demo")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["GitHub Copilot"].exists)
        saveScreenshot("landscape-demo")
        app.buttons["deskModeButton"].tap()
        XCTAssertTrue(app.buttons["Desactivar modo escritorio"].exists)
        app.buttons["deskModeButton"].tap()
        XCTAssertTrue(app.buttons["Activar modo escritorio"].exists)
        XCUIDevice.shared.orientation = .portrait
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Conexiones"].waitForExistence(timeout: 5))
        let username = app.textFields["githubUsername"]
        for _ in 0..<5 {
            if username.exists { break }
            let form = app.collectionViews.firstMatch
            if form.exists { form.swipeUp() }
            else {
                app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
                    .press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.35)))
            }
        }
        saveScreenshot("connections-before-assertion")
        XCTAssertTrue(username.exists)
        saveScreenshot("connections")
        app.buttons["Listo"].tap()
        XCUIDevice.shared.orientation = .portrait
    }

    func testDemoExitRestoresDisconnectedState() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let exit = app.buttons["exitDemoButton"]
        if !exit.isHittable { app.swipeUp() }
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        XCTAssertTrue(app.buttons["Conectar Codex"].exists)
        XCTAssertTrue(app.buttons["Conectar GitHub Copilot"].exists)
        saveScreenshot("disconnected")
    }

    func testLargeTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["GitHub Copilot"].exists)
        saveScreenshot("large-text")
    }

    private func saveScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
