import XCTest
import WebKit
@testable import Pulso

final class ClaudeUsageTests: XCTestCase {
    func testKnownWindowsKeepIndependentResetDatesAndPercentages() throws {
        let now = Date(timeIntervalSince1970: 100)
        let snapshot = try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":27.5,"resets_at":"2026-11-04T12:00:00Z"},"seven_day":{"utilization":100,"resets_at":"2026-11-10T00:00:00.123Z"},"seven_day_opus":{"utilization":0,"resets_at":"2026-11-11T00:00:00Z"},"seven_day_sonnet":{"utilization":12,"resets_at":"2026-11-12T00:00:00Z"},"extra_usage":{"utilization":999,"monthly_limit":1000}}"#.utf8), now: now)
        XCTAssertEqual(snapshot.provider, .claude)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.source, "Claude · sesión web experimental")
        XCTAssertEqual(snapshot.windows.map(\.id), ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"])
        XCTAssertEqual(snapshot.windows.map(\.title), ["Sesión · 5 h", "Semana", "Semana · Opus", "Semana · Sonnet"])
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [72.5, 0, 100, 88])
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-11-04T12:00:00Z"))
        XCTAssertNotEqual(snapshot.windows[1].resetsAt, snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows[1].resetsAt!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.123, accuracy: 0.001)
    }

    @MainActor
    final class ClaudeEmailLoginTests: XCTestCase, WKNavigationDelegate {
        private var loaded: XCTestExpectation?

        func testEmailIsPassedAsDataAndOnlyEmailFormIsSubmitted() async throws {
            let view = await page("""
            <form action="/login">
              <input type="email">
              <button type="submit">Continue</button>
            </form>
            <script>
            document.querySelector('form').addEventListener('submit', event => {
              event.preventDefault();
              document.body.dataset.submitted = document.querySelector('input').value;
            });
            </script>
            """)
            let email = "o'hara@example.test"
            let result = try await view.callAsyncJavaScript(
                ClaudeWebSession.emailLoginScript, arguments: ["email": email], in: nil, contentWorld: .page
            )
            XCTAssertEqual(result as? String, "submitted")
            let submitted = try await view.evaluateJavaScript("document.body.dataset.submitted")
            XCTAssertEqual(submitted as? String, email)
        }

        func testForeignOriginAndForeignFormActionAreNotFilledOrSubmitted() async throws {
            for (origin, action) in [
                ("https://example.test", "/login"),
                ("https://claude.ai", "https://example.test/login")
            ] {
                let view = await page(
                    #"<form action="\#(action)"><input type="email"><button>Continue</button></form>"#,
                    origin: origin
                )
                let result = try await view.callAsyncJavaScript(
                    ClaudeWebSession.emailLoginScript, arguments: ["email": "test@example.test"],
                    in: nil, contentWorld: .page
                )
                XCTAssertEqual(result as? String, "manual")
                let value = try await view.evaluateJavaScript("document.querySelector('input').value")
                XCTAssertEqual(value as? String, "")
            }
        }

        func testConsentAndVerificationFormsRemainManual() async throws {
            for extra in [
                #"<input type="checkbox" required>"#,
                #"<input type="password">"#,
                #"<input autocomplete="one-time-code">"#
            ] {
                let view = await page("""
                <form><input type="email">\(extra)<button>Continue</button></form>
                """)
                let result = try await view.callAsyncJavaScript(
                    ClaudeWebSession.emailLoginScript, arguments: ["email": "test@example.test"],
                    in: nil, contentWorld: .page
                )
                XCTAssertEqual(result as? String, "manual")
                let value = try await view.evaluateJavaScript("document.querySelector('input[type=email]').value")
                XCTAssertEqual(value as? String, "")
            }
        }

        private func page(_ html: String, origin: String = "https://claude.ai") async -> WKWebView {
            loaded = expectation(description: "Login fixture loaded")
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            let view = WKWebView(frame: .zero, configuration: configuration)
            view.navigationDelegate = self
            view.loadHTMLString(html, baseURL: URL(string: origin)!)
            await fulfillment(of: [loaded!], timeout: 5)
            return view
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            loaded?.fulfill()
            loaded = nil
        }
    }

    func testNullOptionalWindowsAndUnknownFieldsAreSkipped() throws {
        let snapshot = try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":0,"resets_at":"2026-11-04T12:00:00+01:00"},"seven_day":null,"seven_day_opus":null,"seven_day_sonnet":null,"future_window":{"bad":true}}"#.utf8))
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100)
    }

    func testNullResetPreservesValidZeroUsageAndIndependentWeeklyReset() throws {
        let snapshot = try ClaudeUsageParser.parse(Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":{"utilization":45,"resets_at":"2026-11-10T00:00:00Z"}}"#.utf8))
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100)
        XCTAssertEqual(snapshot.windows[1].remainingPercent!, 55, accuracy: 0.001)
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertEqual(snapshot.windows[1].resetsAt, ISO8601DateFormatter().date(from: "2026-11-10T00:00:00Z"))
    }

    func testMissingAndMalformedKnownWindowsAreRejected() {
        for fixture in [
            #"{}"#, #"[]"#, #"{"five_hour":null}"#,
            #"{"future_window":{"utilization":30,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"extra_usage":{"utilization":30,"monthly_limit":100}}"#,
            #"{"five_hour":{"utilization":-1,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":100.1,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":"30","resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":null,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"seven_day_sonnet":false}"#,
            #"{"five_hour":{"utilization":true,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":1e999,"resets_at":"2026-11-04T12:00:00Z"}}"#,
            #"{"five_hour":{"utilization":30,"resets_at":"tomorrow"}}"#,
            #"{"five_hour":{"utilization":30,"resets_at":"2026-11-04"}}"#,
            #"{"five_hour":{"utilization":30,"resets_at":1793764800}}"#,
            #"{"five_hour":{"utilization":30,"resets_at":"2026-11-04T12:00:00Z"},"seven_day_opus":{"utilization":2}}"#
        ] {
            XCTAssertThrowsError(try ClaudeUsageParser.parse(Data(fixture.utf8)), fixture) { error in
                XCTAssertEqual(error as? UsageError, .unsupportedSchema)
            }
        }
    }
}
