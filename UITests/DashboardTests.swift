import XCTest

final class DashboardTests: XCTestCase {
    func testReleaseBuildIgnoresDemoAndResetArguments() throws {
        #if DEBUG
        throw XCTSkip("This regression validates the Release configuration.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences",
                               "-AppleLanguages", "(es)", "-AppleLocale", "es_ES"]
        app.launch()
        XCTAssertFalse(app.staticTexts["demoBanner"].exists)
        XCTAssertFalse(app.buttons["demoButton"].exists)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Conexiones"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.switches["demoToggle"].exists)
        #endif
    }

    func testWidgetDashboardLinkOpensDashboardOnColdLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        app.terminate()
        app.open(URL(string: "pulso://dashboard")!)
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.navigationBars["Conexiones"].exists)
        XCTAssertTrue(app.buttons["settingsButton"].isHittable)
    }

    func testWidgetDashboardLinkDismissesPreviouslyOpenSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Conexiones"].waitForExistence(timeout: 5))
        XCUIDevice.shared.press(.home)
        app.open(URL(string: "pulso://dashboard")!)
        let dismissed = expectation(for: NSPredicate(format: "exists == false"),
                                    evaluatedWith: app.navigationBars["Conexiones"])
        wait(for: [dismissed], timeout: 5)
        XCTAssertTrue(app.buttons["settingsButton"].isHittable)
    }

    func testSummaryWidgetAppearsInSystemGallery() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons.matching(NSPredicate(
            format: "identifier == 'Pulso' AND value != 'Widget'"
        )).firstMatch
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        for _ in 0..<4 {
            if icon.isHittable { break }
            springboard.swipeLeft()
        }
        icon.press(forDuration: 1.5)
        let editHome = springboard.buttons["com.apple.springboardhome.application-shortcut-item.rearrange-icons"]
        XCTAssertTrue(editHome.waitForExistence(timeout: 5))
        editHome.tap()
        let edit = springboard.buttons.matching(NSPredicate(format: "label == 'Editar' OR label == 'Edit'")).firstMatch
        XCTAssertTrue(edit.waitForExistence(timeout: 5))
        edit.tap()
        let addWidget = springboard.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'widget' AND (label CONTAINS[c] 'añadir' OR label CONTAINS[c] 'agregar' OR label CONTAINS[c] 'add')"
        )).firstMatch
        XCTAssertTrue(addWidget.waitForExistence(timeout: 5))
        addWidget.tap()
        let search = springboard.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap()
        search.typeText("Pulso")
        let result = springboard.staticTexts["Pulso"].firstMatch
        XCTAssertTrue(result.waitForExistence(timeout: 5))
        result.tap()
        let summary = springboard.staticTexts["Resumen de Pulso"]
        for _ in 0..<18 {
            if summary.exists { break }
            springboard.swipeLeft()
        }
        XCTAssertTrue(summary.exists)
        saveScreenshot("summary-widget-gallery")
        XCUIDevice.shared.press(.home)
        XCUIDevice.shared.press(.home)
    }

    func testExistingPhysicalWidgetRefreshDoesNotForegroundApp() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("Requires an existing widget on an unlocked physical device")
        #else
        // Never launch the containing app or change the device's accounts/preferences.
        let app = XCUIApplication(bundleIdentifier: "com.jesusom.pulso")
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let refresh = springboard.buttons.matching(NSPredicate(
            format: "label IN %@",
            ["Actualizar cuotas", "Actualiza cuotas", "Actualizar cuota de GitHub Copilot",
             "Actualizar cuota de Codex", "Actualizar cuota de Claude"]
        )).firstMatch
        for _ in 0..<4 {
            if refresh.isHittable { break }
            springboard.swipeLeft()
        }
        guard refresh.exists && refresh.isHittable else {
            throw XCTSkip("No existing, tappable Pulso widget refresh button found; no refresh was attempted")
        }
        XCTAssertNotEqual(app.state, .runningForeground)
        saveScreenshot("physical-widget-before-refresh")
        print("WIDGET_REFRESH_TAP_UTC=\(ISO8601DateFormatter().string(from: Date()))")
        refresh.tap()
        XCTAssertFalse(app.wait(for: .runningForeground, timeout: 3),
                       "Refreshing a widget must not bring Pulso to the foreground")
        XCTAssertTrue(springboard.wait(for: .runningForeground, timeout: 3))
        saveScreenshot("physical-widget-after-refresh")
        #endif
    }

    func testLiveActivitySettingsPersistWithoutStartingDemoActivity() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        app.buttons["settingsButton"].tap()
        let toggle = app.switches["liveActivityToggle"]
        for _ in 0..<12 {
            if toggle.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(toggle.isHittable)
        if toggle.value as? String == "0" {
            toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        }
        XCTAssertEqual(toggle.value as? String, "1")
        app.collectionViews.firstMatch.swipeUp()
        let provider = app.descendants(matching: .any).matching(identifier: "liveActivityProvider").firstMatch
        XCTAssertTrue(provider.waitForExistence(timeout: 5), app.debugDescription)
        provider.tap()
        app.buttons["Claude"].tap()
        let start = app.buttons["startLiveActivity"]
        XCTAssertTrue(start.exists)
        start.tap()
        XCTAssertTrue(app.staticTexts["liveActivityMessage"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["stopLiveActivity"].exists, "Demo readings must not start a real Live Activity")
        saveScreenshot("live-activity-settings")
        app.terminate()
        app.launchArguments = ["--demo"]
        app.launch()
        app.buttons["settingsButton"].tap()
        for _ in 0..<12 {
            if toggle.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertEqual(toggle.value as? String, "1")
        app.collectionViews.firstMatch.swipeUp()
        XCTAssertTrue(provider.label.contains("Claude") || String(describing: provider.value ?? "").contains("Claude"))
        app.collectionViews.firstMatch.swipeDown()
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
    }

    func testHomeScreenOffersAllSupportedWidgetSizes() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let icon = springboard.icons["Pulso"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.press(forDuration: 1.5)
        saveScreenshot("widget-size-menu")
        for labels in [
            ["Widget pequeño", "Small Widget"],
            ["Widget mediano", "Medium Widget"],
            ["Widget grande", "Large Widget"],
            ["Widget vertical extragrande", "Extra Large Portrait Widget"]
        ] {
            XCTAssertTrue(labels.contains { springboard.buttons[$0].exists }, "Missing widget format: \(labels[0])")
        }
        XCUIDevice.shared.press(.home)
    }

    override func setUp() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        XCUIDevice.shared.orientation = .portrait
    }

    func testEnglishDashboardAndDeveloperLinks() throws {
        #if !DEBUG
        throw XCTSkip("Development screenshots require Debug-only sample data.")
        #else
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences",
                               "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        XCTAssertTrue(app.staticTexts["demoBanner"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["used_codex"].label.contains("used"))
        saveScreenshot("public-portrait-en")
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.staticTexts["Claude"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["used_copilot"].label.contains("used"))
        app.buttons["deskModeButton"].tap()
        saveScreenshot("public-landscape-en")
        app.buttons["deskModeButton"].tap()
        XCUIDevice.shared.orientation = .portrait
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Connections"].waitForExistence(timeout: 5))
        let copyright = app.staticTexts["authorCopyright"]
        let website = app.descendants(matching: .any).matching(identifier: "developerWebsite").firstMatch
        let support = app.descendants(matching: .any).matching(identifier: "supportDeveloper").firstMatch
        for _ in 0..<18 {
            if support.exists && support.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(copyright.isHittable)
        XCTAssertTrue(copyright.label.contains("Jesus Oliva Morales"))
        XCTAssertTrue(website.isHittable)
        XCTAssertTrue(support.isHittable)
        app.collectionViews.firstMatch.swipeUp()
        saveScreenshot("public-settings-en")
        #endif
    }

    func testDemoPortraitLandscapeAndSettings() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
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
        app.launchArguments = ["--demo", "--reset-preferences"]
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
        app.launchArguments = ["--demo", "--reset-preferences"]
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
        connect.tap()
        let email = app.textFields["claudeLoginEmail"]
        XCTAssertTrue(email.waitForExistence(timeout: 5))
        let continueEmail = app.buttons["claudeContinueEmail"]
        XCTAssertFalse(continueEmail.isEnabled)
        email.tap()
        email.typeText("pulso-test@example.test")
        XCTAssertTrue(continueEmail.isEnabled)
        XCTAssertFalse(app.buttons["Consultar cuota"].exists)
        saveScreenshot("claude-native-email")
        app.buttons["Cerrar"].tap()
    }

    func testCorporateCopilotSettingAndUsageLink() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
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

    func testBusinessCreditBalancesAreShownWithoutRecomputingRemaining() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences", "-AppleLocale", "es_ES"]
        app.launch()
        let used = app.staticTexts["used_copilot"]
        for _ in 0..<5 {
            if used.isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(used.exists)
        XCTAssertTrue(used.label.contains("6.134 consumidos"), used.label)
        XCTAssertTrue(app.staticTexts["60.000 de límite mensual"].exists)
        XCTAssertTrue(app.staticTexts["53.774 restantes"].exists)
        XCTAssertEqual(app.staticTexts["quota_copilot"].label, "90")
        saveScreenshot("copilot-monthly-credit-balances")
    }

    func testDashboardAndConnectionsHaveNoBetaOrExperimentalLabels() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        XCTAssertFalse(app.staticTexts["BETA"].exists)
        let experimental = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'experimental'"))
        XCTAssertEqual(experimental.count, 0)
        app.buttons["settingsButton"].tap()
        XCTAssertTrue(app.navigationBars["Conexiones"].waitForExistence(timeout: 5))
        XCTAssertEqual(experimental.count, 0)
    }

    func testUsedLabelsAndRememberedPanelVisibility() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        setQuotaDisplay("Restante", app: app)
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
        // Relaunch without the reset: this is what verifies the choice is remembered.
        app.launchArguments = ["--demo"]
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

    func testQuotaDisplayPreferenceSwapsTheHeadlineFigure() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences"]
        app.launch()
        setQuotaDisplay("Restante", app: app)
        let headline = app.staticTexts["quota_codex"]
        XCTAssertTrue(headline.waitForExistence(timeout: 10))
        XCTAssertEqual(headline.label, "72")
        XCTAssertEqual(app.staticTexts["used_codex"].label, "28% usado")
        XCTAssertTrue(app.staticTexts["54% disponible · 46% usado"].exists)

        setQuotaDisplay("Usado", app: app)
        XCTAssertEqual(headline.label, "28", "La cifra grande pasa a ser la usada")
        XCTAssertEqual(app.staticTexts["used_codex"].label, "72% disponible")

        app.terminate()
        // Relaunch without the reset: this is what verifies the choice is remembered.
        app.launchArguments = ["--demo"]
        app.launch()
        XCTAssertEqual(app.staticTexts["quota_codex"].label, "28", "La preferencia se recuerda")
        XCTAssertTrue(app.staticTexts["46% usado · 54% disponible"].exists,
                      "La semana debe respetar la misma preferencia que la sesión, también al reabrir")
        saveScreenshot("quota-display-used")
        setQuotaDisplay("Restante", app: app)
        XCTAssertEqual(app.staticTexts["quota_codex"].label, "72")
        XCTAssertTrue(app.staticTexts["54% disponible · 46% usado"].exists)
    }

    func testLargeTextLayout() {
        let app = XCUIApplication()
        app.launchArguments = ["--demo", "--reset-preferences", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsButton"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Codex"].exists)
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["GitHub Copilot"].exists)
        saveScreenshot("large-text")
    }

    /// The preference lives in the shared app group, so it survives launches and
    /// leaks between tests unless each one states what it expects.
    private func setQuotaDisplay(_ option: String, app: XCUIApplication) {
        app.buttons["settingsButton"].tap()
        let picker = app.segmentedControls["quotaDisplayPicker"]
        for _ in 0..<8 {
            if picker.exists { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(picker.exists)
        picker.buttons[option].tap()
        app.buttons["Listo"].tap()
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
