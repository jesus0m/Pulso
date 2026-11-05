import XCTest

@MainActor
final class PulsoWatchUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testDemoOverviewAndWeeklyDetailUseRemainingPreference() {
        let app = launch("--demo")
        let codex = app.buttons["watch_panel_codex"]
        reveal(codex, in: app)
        XCTAssertTrue(codex.label.contains("72%"), codex.label)
        XCTAssertTrue(codex.label.contains("Semana"), codex.label)
        XCTAssertTrue(codex.label.contains("54%"), codex.label)
        codex.tap()

        let session = app.staticTexts["watch_quota_session"]
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        XCTAssertEqual(session.label, "72%")
        let weekly = app.staticTexts["watch_quota_week"]
        reveal(weekly, in: app)
        XCTAssertEqual(weekly.label, "54%")
        XCTAssertTrue(app.staticTexts["watch_window_week"].exists)
    }

    func testUsedPreferenceAppliesToWeeklyOverviewAndDetail() {
        let app = launch("--demo", "--quota-used")
        let codex = app.buttons["watch_panel_codex"]
        reveal(codex, in: app)
        XCTAssertTrue(codex.label.contains("28%"), codex.label)
        XCTAssertTrue(codex.label.contains("46%"), codex.label)
        XCTAssertTrue(codex.label.contains("usado"), codex.label)
        codex.tap()

        XCTAssertTrue(app.staticTexts["watch_quota_session"].waitForExistence(timeout: 5))
        let weekly = app.staticTexts["watch_quota_week"]
        reveal(weekly, in: app)
        XCTAssertEqual(weekly.label, "46%")
    }

    func testCopilotShowsIndependentlyReportedMonthlyBalances() {
        let app = launch("--demo")
        let copilot = app.buttons["watch_panel_copilot"]
        reveal(copilot, in: app)
        XCTAssertTrue(copilot.label.contains("53,774"), copilot.label)
        copilot.tap()

        let headline = app.staticTexts["watch_quota_copilot_credits"]
        XCTAssertTrue(headline.waitForExistence(timeout: 5))
        XCTAssertEqual(headline.label, "90%")
        for (identifier, expected) in [
            ("watch_credits_consumed", "6,134 consumidos"),
            ("watch_credits_limit", "60,000 de límite mensual"),
            ("watch_credits_remaining", "53,774 restantes"),
            ("watch_credits_reported_percent", "89.6% disponible")
        ] {
            let balance = app.staticTexts[identifier]
            reveal(balance, in: app)
            XCTAssertEqual(balance.label, expected)
        }
    }

    func testEmptyStateExplainsIPhoneSetupWithoutInventingQuota() {
        let app = launch("--empty-state")
        let empty = app.staticTexts["watch_empty"]
        XCTAssertTrue(empty.waitForExistence(timeout: 5))
        XCTAssertTrue(empty.label.contains("Pulso para iPhone"))
        XCTAssertFalse(app.buttons["watch_panel_codex"].exists)
        XCTAssertFalse(app.buttons["watch_panel_copilot"].exists)
        XCTAssertFalse(app.buttons["watch_panel_claude"].exists)
        let refresh = app.buttons["watch_refresh"]
        reveal(refresh, in: app)
        XCTAssertTrue(refresh.exists)
    }

    private func launch(_ arguments: String...) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--reset-preferences", "-AppleLanguages", "(es)", "-AppleLocale", "en_US"] + arguments
        app.launch()
        return app
    }

    private func reveal(_ element: XCUIElement, in app: XCUIApplication,
                        file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let scroll = app.scrollViews.firstMatch
            let surface = scroll.exists ? scroll : app
            let scrollDown = element.exists && element.frame.midY < surface.frame.midY
            let start = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65))
            let end = surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: scrollDown ? 0.85 : 0.45))
            start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        print("Watch accessibility hierarchy after scrolling:\n\(app.debugDescription)")
        XCTAssertTrue(element.exists && element.isHittable, "Expected visible element: \(element)",
                      file: file, line: line)
    }
}
