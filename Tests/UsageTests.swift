import XCTest
@testable import Pulso

final class UsageTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_750_400)

    func testPreviouslyCachedWindowsKeepDerivedPercentagesWithoutReportedBalances() throws {
        let data = Data(#"{"id":"session","title":"Sesión","used":55,"limit":100}"#.utf8)
        let window = try JSONDecoder().decode(UsageWindow.self, from: data)
        XCTAssertNil(window.remaining)
        XCTAssertNil(window.reportedRemainingPercent)
        XCTAssertEqual(window.displayedUsedPercent, 55)
        XCTAssertEqual(window.displayedRemainingPercent, 45)
    }

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

final class CodexPastedTokenTests: XCTestCase {
    func testExtractsTokenFromSessionJSONOrBareJWT() {
        let jwt = "aaa.bbb.ccc"
        XCTAssertEqual(CodexPastedToken.extractToken(from: #"{"user":{"email":"a@b.c"},"accessToken":"aaa.bbb.ccc"}"#), jwt)
        XCTAssertEqual(CodexPastedToken.extractToken(from: "Bearer \(jwt)\n"), jwt)
        XCTAssertNil(CodexPastedToken.extractToken(from: "hola"))
        XCTAssertNil(CodexPastedToken.extractToken(from: #"{"accessToken":"no-es-jwt"}"#))
    }
}

@MainActor
final class CodexNativeOAuthTests: XCTestCase {
    func testNativeAuthorizationUsesPKCEAndExactLoopbackRedirect() throws {
        let attempt = try CodexOAuth.makeAttempt()
        let redirect = URL(string: "http://localhost:1457/auth/callback")!
        let url = CodexOAuth.authorizationURL(redirect: redirect, attempt: attempt)
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        XCTAssertEqual(url.host, "auth.openai.com")
        XCTAssertEqual(url.path, "/oauth/authorize")
        XCTAssertEqual(value("redirect_uri"), redirect.absoluteString)
        XCTAssertEqual(value("state"), attempt.state)
        XCTAssertEqual(value("code_challenge"), CodexOAuth.challenge(attempt.verifier))
        XCTAssertEqual(value("code_challenge_method"), "S256")
        XCTAssertEqual(CodexOAuth.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
                       "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    func testCallbackRejectsWrongStateHostPathAndDuplicateParameters() throws {
        let redirect = URL(string: "http://localhost:1455/auth/callback")!
        let good = URL(string: "\(redirect)?state=expected&code=valid")!
        XCTAssertEqual(try CodexOAuth.authorizationCode(callback: good, redirect: redirect, state: "expected"), "valid")
        for value in [
            "\(redirect)?state=wrong&code=valid",
            "\(redirect)?state=expected&state=expected&code=valid",
            "\(redirect)?state=expected&code=valid&code=other",
            "http://localhost:1455/auth/callback/other?state=expected&code=valid",
            "http://other.example:1455/auth/callback?state=expected&code=valid",
            "\(redirect)?state=expected&error=access_denied"
        ] {
            XCTAssertThrowsError(try CodexOAuth.authorizationCode(callback: URL(string: value)!,
                                                                  redirect: redirect, state: "expected"))
        }
    }

    func testLocalListenerReceivesCallbackWithoutBrowserDeepLink() async throws {
        let server = try await CodexCallbackServer.start(state: "expected", ports: [0])
        defer { server.cancel() }
        let http = URLSession(configuration: .ephemeral)
        defer { http.invalidateAndCancel() }
        let unrelated = URL(string: "/favicon.ico", relativeTo: server.redirect)!.absoluteURL
        let (_, rejected) = try await http.data(from: unrelated)
        XCTAssertEqual((rejected as? HTTPURLResponse)?.statusCode, 400)
        async let callback = server.wait(timeout: .seconds(3))
        let url = URL(string: "\(server.redirect)?state=expected&code=received")!
        let (_, response) = try await http.data(from: url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let received = try await callback
        XCTAssertEqual(try CodexOAuth.authorizationCode(callback: received, redirect: server.redirect,
                                                       state: "expected"), "received")
    }

    func testWaitingForCallbackCanBeCancelled() async throws {
        let server = try await CodexCallbackServer.start(state: "expected", ports: [0])
        defer { server.cancel() }
        let task = Task { try await server.wait() }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("Cancelled login must not wait for the timeout")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCodeExchangeEncodesValuesAndQuotaPreservesIndependentWindows() async throws {
        let client = makeClient()
        let redirect = URL(string: "http://localhost:1455/auth/callback")!
        let credentials = try await client.exchange(code: "code+&=", redirect: redirect, verifier: "verifier")
        let exchange = try XCTUnwrap(CodexHTTPStub.recorded.first)
        let body = String(decoding: exchange.httpBody ?? Data(), as: UTF8.self)
        XCTAssertTrue(body.contains("code=code%2B%26%3D"))
        XCTAssertTrue(body.contains("redirect_uri=http%3A%2F%2Flocalhost%3A1455%2Fauth%2Fcallback"))
        XCTAssertFalse(exchange.httpShouldHandleCookies)
        XCTAssertEqual(credentials.refreshToken, "rotated-refresh")
        let snapshot = try await client.fetchUsage(credentials)
        XCTAssertEqual(snapshot.windows.map(\.displayedUsedPercent), [27, 46])
        XCTAssertEqual(snapshot.windows.map(\.displayedRemainingPercent), [73, 54])
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_768_400))
    }

    func testConcurrentQuotaReadsShareOneRefreshAndPersistRotation() async throws {
        let client = makeClient()
        var stored: CodexCredentials? = oldCredentials(expiry: .distantPast)
        let session = CodexSession(client: client, load: { stored }, save: { stored = $0 }, delete: { stored = nil },
                                   legacyToken: { nil })
        async let first = session.fetchUsage()
        async let second = session.fetchUsage()
        _ = try await (first, second)
        XCTAssertEqual(CodexHTTPStub.recorded.filter { $0.url?.path == "/oauth/token" }.count, 1)
        XCTAssertEqual(stored?.accessToken, "renewed-access")
        XCTAssertEqual(stored?.refreshToken, "rotated-refresh")
        let usage = CodexHTTPStub.recorded.filter { $0.url?.path.hasSuffix("/wham/usage") == true }
        XCTAssertEqual(usage.count, 2)
        XCTAssertTrue(usage.allSatisfy { $0.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "account-1" })
    }

    func testUnauthorizedQuotaRenewsOnceAndRetries() async throws {
        let client = makeClient(rejectOldToken: true)
        var stored: CodexCredentials? = oldCredentials(expiry: .distantFuture)
        let session = CodexSession(client: client, load: { stored }, save: { stored = $0 }, delete: { stored = nil },
                                   legacyToken: { nil })
        _ = try await session.fetchUsage()
        XCTAssertEqual(CodexHTTPStub.recorded.map { $0.url!.path },
                       ["/backend-api/wham/usage", "/oauth/token", "/backend-api/wham/usage"])
    }

    func testFailedKeychainWriteDoesNotUseUnpersistedRefresh() async {
        let client = makeClient()
        let stored = oldCredentials(expiry: .distantPast)
        let session = CodexSession(client: client, load: { stored },
                                   save: { _ in throw CodexAuthError.keychain(-1) }, delete: {}, legacyToken: { nil })
        do {
            _ = try await session.fetchUsage()
            XCTFail("A failed token write must be surfaced")
        } catch { XCTAssertEqual(error as? CodexAuthError, .keychain(-1)) }
        XCTAssertEqual(CodexHTTPStub.recorded.count, 1)
    }

    func testDisconnectDuringRefreshDoesNotRestoreCredentials() async throws {
        let client = makeClient()
        var stored: CodexCredentials? = oldCredentials(expiry: .distantPast)
        let session = CodexSession(client: client, load: { stored }, save: { stored = $0 }, delete: { stored = nil },
                                   legacyToken: { nil })
        let fetch = Task { try await session.fetchUsage() }
        for _ in 0..<100 {
            if !CodexHTTPStub.recorded.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(CodexHTTPStub.recorded.isEmpty)
        try session.clearSession()
        do {
            _ = try await fetch.value
            XCTFail("Disconnect must invalidate an in-flight refresh")
        } catch {}
        XCTAssertNil(stored)
    }

    private func oldCredentials(expiry: Date) -> CodexCredentials {
        CodexCredentials(accessToken: "old-access", refreshToken: "old-refresh", idToken: nil,
                         accountID: "account-1", email: nil, expiresAt: expiry)
    }

    private func makeClient(rejectOldToken: Bool = false) -> CodexOAuthClient {
        CodexHTTPStub.reset(rejectOldToken: rejectOldToken)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CodexHTTPStub.self]
        return CodexOAuthClient(session: URLSession(configuration: config))
    }
}

private final class CodexHTTPStub: URLProtocol {
    private static let lock = NSLock()
    private static var requests: [URLRequest] = []
    private static var rejectOldToken = false
    static var recorded: [URLRequest] { lock.withLock { requests } }

    static func reset(rejectOldToken: Bool) {
        lock.withLock {
            requests = []
            self.rejectOldToken = rejectOldToken
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = body
        }
        let rejected = Self.lock.withLock {
            Self.requests.append(captured)
            return Self.rejectOldToken && request.value(forHTTPHeaderField: "Authorization") == "Bearer old-access"
        }
        let isToken = request.url?.path == "/oauth/token"
        let body = isToken
            ? #"{"access_token":"renewed-access","refresh_token":"rotated-refresh","expires_in":3600}"#
            : #"{"rate_limit":{"primary_window":{"used_percent":27,"reset_at":1793768400,"limit_window_seconds":18000},"secondary_window":{"used_percent":46,"reset_at":1794000000,"limit_window_seconds":604800}}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: rejected ? 401 : 200,
                                       httpVersion: nil, headerFields: nil)!
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.03) { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
