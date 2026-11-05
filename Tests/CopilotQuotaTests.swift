import XCTest
@testable import Pulso

final class CopilotQuotaTests: XCTestCase {
    func testBusinessAICreditsPreservesPublishedMonthlyValuesAcrossCacheRoundTrip() throws {
        let data = Data(#"{"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":60000,"remaining":53774,"percent_remaining":89.6,"token_based_billing":true},"chat":{"credits_used":6134,"entitlement":999999,"remaining":1,"percent_remaining":1}}}"#.utf8)
        for manualLimit: Double? in [nil, 120000] {
            let snapshot = try CopilotQuotaClient.parse(data, allowance: manualLimit)
            let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(snapshot))
            let window = try XCTUnwrap(restored.windows.first)
            XCTAssertEqual(restored.windows.count, 1)
            XCTAssertEqual(window.used, 6134)
            XCTAssertEqual(window.limit, 60000)
            XCTAssertEqual(try XCTUnwrap(window.remainingPercent), 89.6, accuracy: 0.00001)
            XCTAssertEqual(window.displayedRemainingPercent, 90)
            XCTAssertEqual(window.resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
            let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(window)) as? [String: Any])
            XCTAssertEqual(saved["remaining"] as? Double, 53774,
                           "Preserve GitHub's balance, not 60000 - 6134")
        }
    }

    func testTokenBasedBillingFallsBackOnlyForMissingOrInvalidEntitlement() throws {
        for entitlement in ["null", "-1", "0", #""invalid""#, "true", "1e999"] {
            let data = Data("""
            {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":\(entitlement)}}}
            """.utf8)
            XCTAssertEqual(try CopilotQuotaClient.parse(data, allowance: 70000).windows.first?.limit, 70000)
            XCTAssertNil(try CopilotQuotaClient.parse(data).windows.first?.limit)
        }
        let missing = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134}}}"#.utf8)
        XCTAssertEqual(try CopilotQuotaClient.parse(missing, allowance: 70000).windows.first?.limit, 70000)
    }

    func testPublishedRemainingPercentageDoesNotNeedAManualLimit() throws {
        let snapshot = try parse(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":100,"remaining":0,"percent_remaining":0}}}"#)
        XCTAssertEqual(snapshot.windows.first?.remainingPercent, 0)
        XCTAssertEqual(snapshot.windows.first?.displayedRemainingPercent, 0)
        XCTAssertNil(snapshot.windows.first?.limit)
    }

    func testMalformedPublishedCreditBalancesAreRejected() {
        for fields in [
            #""remaining":-1"#, #""remaining":"53774""#, #""remaining":true"#,
            #""percent_remaining":-0.1"#, #""percent_remaining":100.1"#
        ] {
            let fixture = """
            {"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":6134,"entitlement":60000,\(fields)}}}
            """
            XCTAssertThrowsError(try parse(fixture)) { error in
                XCTAssertEqual(error as? CopilotQuotaError, .unsupportedSchema)
            }
        }
    }

    func testBusinessPremiumQuotaPreservesCountsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 123)
        let snapshot = try parse(#"{"copilot_plan":"business","quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":75,"unlimited":false},"chat":{"entitlement":-1,"percent_remaining":100,"unlimited":true}},"future_field":true}"#, now: now)
        XCTAssertEqual(snapshot.provider, .copilot)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.source, "Copilot · cuota de cuenta experimental · plan business")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "copilot_premium")
        XCTAssertEqual(snapshot.windows[0].title, "Premium · cuenta")
        XCTAssertEqual(snapshot.windows[0].used, 75)
        XCTAssertEqual(snapshot.windows[0].limit, 300)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 75)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testChatQuotaAndFractionalResetDate() throws {
        let snapshot = try parse(#"{"copilot_plan":"enterprise","quota_reset_date":"2026-12-01T02:00:00.125+02:00","quota_snapshots":{"premium_interactions":null,"chat":{"entitlement":500,"percent_remaining":20,"unlimited":false}}}"#)
        XCTAssertEqual(snapshot.windows.map(\.id), ["copilot_chat"])
        XCTAssertEqual(snapshot.windows[0].title, "Chat · cuenta")
        XCTAssertEqual(snapshot.windows[0].used, 400)
        XCTAssertEqual(snapshot.windows[0].resetsAt!.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.125, accuracy: 0.001)
    }

    func testBothQuotasPreserveIndependentCountsAndMissingReset() throws {
        let snapshot = try parse(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":0},"chat":{"entitlement":50,"percent_remaining":100}}}"#)
        XCTAssertEqual(snapshot.windows.map(\.used), [300, 0])
        XCTAssertEqual(snapshot.windows.map(\.limit), [300, 50])
        XCTAssertTrue(snapshot.windows.allSatisfy { $0.resetsAt == nil })
    }

    func testPublishedOverageIsAddedOnceAfterIncludedQuotaIsExhausted() throws {
        let snapshot = try parse(#"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":0,"overage_count":12}}}"#)
        XCTAssertEqual(snapshot.windows[0].used, 312)
        XCTAssertEqual(snapshot.windows[0].limit, 300)
    }

    func testTokenBasedBillingUsesPremiumCreditsWithoutSummingDuplicateChatCredits() throws {
        let now = Date(timeIntervalSince1970: 123)
        let snapshot = try parse(#"{"copilot_plan":"business","token_based_billing":true,"quota_reset_date":"2026-12-01","quota_snapshots":{"premium_interactions":{"credits_used":15.5,"entitlement":-1,"percent_remaining":100,"unlimited":true},"chat":{"credits_used":15.5},"completions":{"credits_used":99}}}"#, now: now)
        XCTAssertEqual(snapshot.provider, .copilot)
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.source, "Copilot · créditos comunicados · cuenta experimental · plan business")
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "copilot_credits")
        XCTAssertEqual(snapshot.windows[0].title, "Créditos usados · cuenta")
        XCTAssertEqual(snapshot.windows[0].used, 15.5)
        XCTAssertNil(snapshot.windows[0].limit)
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 100)
        XCTAssertEqual(snapshot.windows[0].resetsAt, ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z"))
    }

    func testTokenBasedBillingAppliesManualAllowanceForPercentage() throws {
        let data = Data(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":3810}}}"#.utf8)
        let window = try CopilotQuotaClient.parse(data, allowance: 60000).windows[0]
        XCTAssertEqual(window.limit, 60000)
        XCTAssertEqual(window.displayedUsedPercent, 6)
        XCTAssertNil(try CopilotQuotaClient.parse(data, allowance: -5).windows[0].limit)
    }

    func testTokenBasedBillingPreservesExplicitZeroCreditsAndDoesNotFallBackToChat() throws {
        let snapshot = try parse(#"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":0},"chat":{"credits_used":42}}}"#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].used, 0)
        XCTAssertNil(snapshot.windows[0].limit)
        XCTAssertNil(snapshot.windows[0].resetsAt)
    }

    func testTokenBasedBillingFallsBackToPublishedChatCreditsAndIgnoresUnknownResetDate() throws {
        let snapshot = try parse(#"{"token_based_billing":true,"quota_reset_date":"tomorrow","quota_snapshots":{"premium_interactions":{"credits_used":null},"chat":{"credits_used":3.25}}}"#)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].id, "copilot_credits")
        XCTAssertEqual(snapshot.windows[0].used, 3.25)
        XCTAssertNil(snapshot.windows[0].resetsAt)
        XCTAssertNil(snapshot.windows[0].limit)
    }

    func testTokenBasedBillingRequiresPublishedCreditValues() {
        for fixture in [
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":null},"chat":{"credits_used":null}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{},"chat":{},"completions":{"credits_used":10}}}"#
        ] {
            XCTAssertThrowsError(try parse(fixture)) { error in
                XCTAssertEqual(error as? CopilotQuotaError, .noPublishedQuota)
            }
        }
    }

    func testMalformedTokenBasedCreditValuesAreRejected() {
        for fixture in [
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":"15.5"}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":true}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"credits_used":-1}}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"chat":{"credits_used":1e999}}}"#
        ] {
            XCTAssertThrowsError(try parse(fixture)) { error in
                XCTAssertEqual(error as? CopilotQuotaError, .unsupportedSchema)
            }
        }
    }

    func testUnpublishedAndPlaceholderQuotasNeverProduceFakeZero() {
        for fixture in [
            #"{}"#, #"{"quota_snapshots":null}"#,
            #"{"quota_snapshots":{"future":{"entitlement":300,"percent_remaining":100}}}"#,
            #"{"quota_snapshots":{"premium_interactions":null,"chat":null}}"#,
            #"{"token_based_billing":true,"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":100}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":-1,"percent_remaining":100}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":0,"percent_remaining":100}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":100,"unlimited":true}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":300}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":null}}}"#,
            #"{"quota_snapshots":{"premium_interactions":{"percent_remaining":25}}}"#
        ] {
            XCTAssertThrowsError(try parse(fixture), fixture) { error in
                XCTAssertEqual(error as? CopilotQuotaError, .noPublishedQuota)
            }
        }
    }

    func testMalformedKnownDataIsRejected() {
        for fixture in [
            "not JSON", "[]",
            #"{"quota_snapshots":false}"#,
            #"{"quota_snapshots":{"premium_interactions":false}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":"300","percent_remaining":25}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":true}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":-1}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":101}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":1e999,"percent_remaining":25}}}"#,
            #"{"quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25,"overage_count":-1}}}"#,
            #"{"quota_reset_date":"tomorrow","quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25}}}"#,
            #"{"quota_reset_date":"2026-02-30","quota_snapshots":{"chat":{"entitlement":300,"percent_remaining":25}}}"#
        ] {
            XCTAssertThrowsError(try parse(fixture), fixture) { error in
                XCTAssertEqual(error as? CopilotQuotaError, .unsupportedSchema)
            }
        }
    }

    func testFetchUsesOnlySuppliedTokenAndTruthfulHeaders() async throws {
        let now = Date(timeIntervalSince1970: 123)
        let session = makeSession(status: 200, body: #"{"quota_snapshots":{"premium_interactions":{"entitlement":300,"percent_remaining":50}}}"#) { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.github.com/copilot_internal/user")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "token fixture-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "PULSO/1.0")
            XCTAssertEqual(request.value(forHTTPHeaderField: "X-GitHub-Api-Version"), "2026-03-10")
            XCTAssertNil(request.value(forHTTPHeaderField: "Editor-Version"))
            XCTAssertNil(request.value(forHTTPHeaderField: "Editor-Plugin-Version"))
            XCTAssertEqual(request.timeoutInterval, 20)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
        defer { session.invalidateAndCancel() }
        let snapshot = try await CopilotQuotaClient(session: session, clock: { now }).fetch(token: " fixture-token \n")
        XCTAssertEqual(snapshot.updatedAt, now)
        XCTAssertEqual(snapshot.windows[0].used, 150)
    }

    func testFetchDistinguishesAuthorizationAndEndpointAvailability() async {
        for status in [401, 403, 404, 500] {
            let session = makeSession(status: status, body: "{}")
            defer { session.invalidateAndCancel() }
            do {
                _ = try await CopilotQuotaClient(session: session).fetch(token: "fixture-token")
                XCTFail("Expected HTTP \(status) rejection")
            } catch {
                let expected: CopilotQuotaError = status == 404 ? .unavailable : (status == 401 || status == 403 ? .accessDenied(status) : .http(status))
                XCTAssertEqual(error as? CopilotQuotaError, expected)
                if status == 401 || status == 403 {
                    XCTAssertTrue(error.localizedDescription.contains("Copilot Requests"))
                    XCTAssertTrue(error.localizedDescription.contains("organización"))
                }
            }
        }
    }

    func testFetchRejectsEmptyOrWhitespaceContainingTokensBeforeNetwork() async {
        for token in ["", "  ", "token with space", "token\nheader"] {
            do {
                _ = try await CopilotQuotaClient().fetch(token: token)
                XCTFail("Expected invalid token")
            } catch {
                XCTAssertEqual(error as? UsageError, .invalidCredentials)
            }
        }
    }

    private func parse(_ fixture: String, now: Date = Date()) throws -> UsageSnapshot {
        try CopilotQuotaClient.parse(Data(fixture.utf8), now: now)
    }

    private func makeSession(status: Int, body: String, inspect: @escaping (URLRequest) -> Void = { _ in }) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CopilotQuotaURLProtocol.self]
        let identifier = UUID().uuidString
        configuration.httpAdditionalHeaders = ["X-Pulso-Test-ID": identifier]
        CopilotQuotaURLProtocol.register(identifier: identifier) { request in
            inspect(request)
            return (status, Data(body.utf8))
        }
        return URLSession(configuration: configuration)
    }
}

private final class CopilotQuotaURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> (Int, Data)] = [:]

    static func register(identifier: String, handler: @escaping (URLRequest) -> (Int, Data)) {
        lock.lock()
        defer { lock.unlock() }
        handlers[identifier] = handler
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let handler = Self.handlers.removeValue(forKey: request.value(forHTTPHeaderField: "X-Pulso-Test-ID") ?? "")
        Self.lock.unlock()
        guard let handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (status, body) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
