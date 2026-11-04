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
        XCTAssertTrue(app.staticTexts["Claude"].exists)
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
        for _ in 0..<5 {
            if exit.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(exit.waitForExistence(timeout: 5))
        exit.tap()
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        XCTAssertTrue(app.buttons["Conectar Codex"].exists)
        XCTAssertTrue(app.buttons["Conectar GitHub Copilot"].exists)
        XCTAssertTrue(app.buttons["Conectar Claude"].exists)
        saveScreenshot("disconnected")
    }

    func testClaudeDemoAndConnectionControls() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        let claude = app.staticTexts["Claude"]
        for _ in 0..<5 {
            if claude.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(claude.isHittable)
        saveScreenshot("claude-portrait-demo")
        app.buttons["settingsButton"].tap()
        let connect = app.buttons["Abrir sesión de Claude"]
        for _ in 0..<5 {
            if connect.isHittable { break }
            let form = app.collectionViews.firstMatch
            if form.exists { form.swipeUp() }
            else { app.swipeUp() }
        }
        XCTAssertTrue(connect.isHittable)
        XCTAssertTrue(app.buttons["Borrar sesión web de Claude"].exists)
        saveScreenshot("claude-connection")
    }

    func testCorporateCopilotSettingAndUsageLink() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons["settingsButton"].tap()
        let accountType = app.buttons["githubAccountType"]
        let usageLink = app.buttons["Ver mi uso en GitHub"]
        for _ in 0..<8 {
            if accountType.exists || usageLink.exists { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(accountType.exists || app.staticTexts["Tipo de cuenta"].exists)
        XCTAssertTrue(app.staticTexts["Empresa u organización"].exists)
        saveScreenshot("copilot-corporate-settings")
    }

    func testUsedLabelsAndRememberedPanelVisibility() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertTrue(app.staticTexts["used_codex"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["used_codex"].label, "28% usado")
        app.buttons["settingsButton"].tap()
        let copilot = app.switches["visible_copilot"]
        XCTAssertTrue(copilot.waitForExistence(timeout: 5))
        for provider in ["codex", "copilot", "claude"] { setPanel(provider, visible: true, app: app) }
        setPanel("copilot", visible: false, app: app)
        saveScreenshot("panel-switches")
        app.buttons["Listo"].tap()
        XCTAssertFalse(app.otherElements["panel_copilot"].waitForExistence(timeout: 1))
        app.terminate()
        app.launch()
        XCTAssertFalse(app.staticTexts["GitHub Copilot"].exists)
        saveScreenshot("remembered-panels")
        app.buttons["settingsButton"].tap()
        setPanel("codex", visible: false, app: app)
        setPanel("claude", visible: false, app: app)
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Sin paneles visibles"].exists)
        app.buttons["Elegir paneles"].tap()
        for provider in ["codex", "copilot", "claude"] { setPanel(provider, visible: true, app: app) }
        app.buttons["Listo"].tap()
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        XCTAssertTrue(app.staticTexts["GitHub Copilot"].exists)
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

    private func setPanel(_ provider: String, visible: Bool, app: XCUIApplication) {
        let toggle = app.switches["visible_\(provider)"]
        let expected = visible ? "1" : "0"
        if toggle.value as? String != expected {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, expected)
    }

    private func saveScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
