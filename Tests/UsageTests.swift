import XCTest
@testable import Pulso

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_400)

    func testRemainingPercentageClampsExhaustedAndRejectsUnknownAllowance() {
        XCTAssertEqual(UsageWindow(id: "a", title: "A", used: 125, limit: 100, resetsAt: nil).remainingPercent, 0)
        XCTAssertNil(UsageWindow(id: "a", title: "A", used: 0, limit: nil, resetsAt: nil).remainingPercent)
        XCTAssertNil(UsageWindow(id: "a", title: "A", used: 0, limit: 0, resetsAt: nil).remainingPercent)
    }

    func testUsedAndAvailablePercentagesMatchIDEInterpretation() {
        let session = UsageWindow(id: "session", title: "Sesión", used: 55, limit: 100, resetsAt: nil)
        XCTAssertEqual(session.displayedUsedPercent, 55)
        XCTAssertEqual(session.displayedRemainingPercent, 45)
        let later = UsageWindow(id: "session", title: "Sesión", used: 57, limit: 100, resetsAt: nil)
        XCTAssertEqual(later.displayedUsedPercent, 57)
        XCTAssertEqual(later.displayedRemainingPercent, 43)
        let weekly = UsageWindow(id: "week", title: "Semana", used: 47, limit: 100, resetsAt: nil)
        XCTAssertEqual(weekly.displayedUsedPercent, 47)
        XCTAssertEqual(weekly.displayedRemainingPercent, 53)
        let fractional = UsageWindow(id: "month", title: "Mes", used: 18.4, limit: 100, resetsAt: nil)
        XCTAssertEqual(fractional.displayedUsedPercent! + fractional.displayedRemainingPercent!, 100)
        XCTAssertNil(UsageWindow(id: "unknown", title: "Mes", used: 1, limit: nil, resetsAt: nil).displayedUsedPercent)
    }

    func testQuotaDisplayPreferenceSwapsHeadlineAndComplementWithoutLosingEitherFigure() {
        let window = UsageWindow(id: "s", title: "Sesión", used: 72, limit: 100, resetsAt: nil)
        XCTAssertEqual(window.displayedPercent(.remaining), 28)
        XCTAssertEqual(window.complementPercent(.remaining), 72)
        XCTAssertEqual(window.displayedPercent(.used), 72)
        XCTAssertEqual(window.complementPercent(.used), 28)
        for display in QuotaDisplay.allCases {
            XCTAssertEqual(window.displayedPercent(display)! + window.complementPercent(display)!, 100)
        }
    }

    func testQuotaDisplayLeavesUnknownQuotaUnrepresented() {
        let window = UsageWindow(id: "c", title: "Créditos", used: 3251, limit: nil, resetsAt: nil)
        for display in QuotaDisplay.allCases {
            XCTAssertNil(window.displayedPercent(display))
            XCTAssertNil(window.complementPercent(display))
        }
    }

    func testCodexParsesActualIndependentWindows() throws {
        let data = Data(#"{"plan_type":"plus","rate_limit":{"allowed":true,"limit_reached":false,"primary_window":{"used_percent":27,"reset_at":1793768400,"limit_window_seconds":18000},"secondary_window":{"used_percent":100,"reset_at":1794000000,"limit_window_seconds":604800}}}"#.utf8)
        let snapshot = try CodexUsageParser.parse(data, now: now)
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.windows.map(\.remainingPercent), [73, 0])
        XCTAssertEqual(snapshot.windows.map(\.title), ["Sesión · 5 h", "Semana · 7 d"])
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_768_400))
    }

    func testCodexRejectsMissingMalformedAndOutOfRangeWindows() {
        for fixture in [
            #"{}"#, #"{"rate_limit":null}"#,
            #"{"rate_limit":{"primary_window":null}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":-1,"reset_at":1793768400,"limit_window_seconds":18000}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":101,"reset_at":1793768400,"limit_window_seconds":18000}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":"27","reset_at":1793768400,"limit_window_seconds":18000}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":0,"limit_window_seconds":18000}}}"#,
            #"{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":1793768400}}}"#
        ] {
            XCTAssertThrowsError(try CodexUsageParser.parse(Data(fixture.utf8)), fixture)
        }
    }

    func testCodexPermitsOneKnownWindowWithoutInventingSecondQuota() throws {
        let data = Data(#"{"rate_limit":{"primary_window":{"used_percent":0,"reset_at":1793768400,"limit_window_seconds":18000},"secondary_window":null}}"#.utf8)
        XCTAssertEqual(try CodexUsageParser.parse(data).windows.count, 1)
    }

    func testGitHubUsesGrossUsageAndFiltersOtherProducts() throws {
        let fixture = #"{"timePeriod":{"year":2026,"month":11},"user":"monalisa","usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","model":"GPT-5","unitType":"ai-credits","grossQuantity":100,"discountQuantity":100,"netQuantity":0},{"product":"Copilot AI Credits","sku":"AI Credit","model":"Other","unitType":"ai-credits","grossQuantity":25},{"product":"Spark","sku":"Spark AI Credits","unitType":"ai-credits","grossQuantity":900}]}"#
        let snapshot = try GitHubUsageClient.parse(Data(fixture.utf8), allowance: 500, legacy: false, now: now)
        XCTAssertEqual(snapshot.windows[0].used, 125)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 75)
        XCTAssertTrue(snapshot.source.contains("manual"))
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testGitHubLegacyDoesNotInferEntitlement() throws {
        let data = Data(#"{"usageItems":[{"product":"Copilot","sku":"Copilot Premium Request","unitType":"requests","grossQuantity":300,"netQuantity":0}]}"#.utf8)
        let snapshot = try GitHubUsageClient.parse(data, allowance: nil, legacy: true, now: now)
        XCTAssertEqual(snapshot.windows[0].used, 300)
        XCTAssertNil(snapshot.windows[0].limit)
        XCTAssertNil(snapshot.windows[0].remainingPercent)
    }

    func testGitHubRejectsMalformedRowsUnitsAndAllowance() {
        for fixture in [#"{}"#, #"{"usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","unitType":"dollars","grossQuantity":2}]}"#, #"{"usageItems":[{"product":"Copilot AI Credits","sku":"AI Credit","unitType":"ai-credits","grossQuantity":-1}]}"#] {
            XCTAssertThrowsError(try GitHubUsageClient.parse(Data(fixture.utf8), allowance: nil, legacy: false, now: now))
        }
        XCTAssertThrowsError(try GitHubUsageClient.parse(Data(#"{"usageItems":[]}"#.utf8), allowance: 0, legacy: false, now: now))
    }

    func testGitHubEmptyReportDoesNotClaimZeroConsumption() {
        XCTAssertThrowsError(try GitHubUsageClient.parse(Data(#"{"usageItems":[]}"#.utf8), allowance: nil, legacy: false, now: now)) {
            XCTAssertEqual($0 as? UsageError, .noUsageData)
        }
    }

    func testGitHubExplicitZeroConsumptionIsStillValid() throws {
        let data = Data(#"{"usageItems":[{"product":"Copilot","unitType":"credits","grossQuantity":0}]}"#.utf8)
        XCTAssertEqual(try GitHubUsageClient.parse(data, allowance: 100, legacy: false).windows.first?.used, 0)
    }

    func testTokenVaultRejectsEmptyTokenWithoutWritingCredentials() {
        XCTAssertThrowsError(try TokenVault.save("  ")) { error in
            XCTAssertEqual(error as? UsageError, .invalidCredentials)
        }
    }

    func testGitHubRequestsCurrentUTCMonthAndUsesSelectedEndpoint() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [BillingURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let boundary = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!
        let client = GitHubUsageClient(session: session, clock: { boundary })
        let snapshot = try await client.fetch(username: "monalisa", token: "test-token", allowance: nil, legacy: false)
        XCTAssertEqual(snapshot.windows[0].used, 45)
        XCTAssertEqual(snapshot.updatedAt, boundary)
        do {
            _ = try await client.fetch(username: "denied", token: "test-token", allowance: nil, legacy: true)
            XCTFail("Unauthorized HTTP response must not create a usage snapshot")
        } catch { XCTAssertEqual(error as? UsageError, .http(401)) }
    }

    func testGitHubRejectsEmptyCredentialsBeforeNetworking() async {
        do {
            _ = try await GitHubUsageClient().fetch(username: "valid", token: "", allowance: nil, legacy: false)
            XCTFail("Expected invalid credentials")
        } catch { XCTAssertEqual(error as? UsageError, .invalidCredentials) }
        do {
            _ = try await GitHubUsageClient().fetch(username: "../bad", token: "token", allowance: nil, legacy: false)
            XCTFail("Expected invalid credentials")
        } catch { XCTAssertEqual(error as? UsageError, .invalidCredentials) }
    }
}

/// Intercepts the HTTP transport only; request construction and parsing remain real.
private final class BillingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.contains("/users/denied/") {
            let response = HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let values = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        let valid = url.host == "api.github.com"
            && url.path == "/users/monalisa/settings/billing/ai_credit/usage"
            && values["year"] == "2026" && values["month"] == "12"
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token"
        let response = HTTPURLResponse(url: url, statusCode: valid ? 200 : 400, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"usageItems":[{"product":"Copilot AI Credits","unitType":"ai-credits","grossQuantity":45}]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
