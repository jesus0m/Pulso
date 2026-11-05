import XCTest
@testable import Pulso

final class ClaudeQuotaClientTests: XCTestCase {
    private let organizationID = "01531D14-44AB-4DBB-9D96-02CFD19C7712"
    private let body = #"{"five_hour":{"utilization":27,"resets_at":null},"seven_day":{"utilization":42,"resets_at":"2026-11-12T12:00:00Z"}}"#

    func testCaptureSharesOnlySecureUnambiguousFirstPartySessionCookie() throws {
        let valid = cookie()
        let unrelated = cookie(name: "tracking", value: "not-shared")
        let credentials = try ClaudeWebCredentials.capture(cookies: [unrelated, valid], organizationID: organizationID)
        XCTAssertEqual(credentials.sessionKey, "sk-ant-fixture")
        for cookies in [
            [cookie(domain: "evilclaude.ai")],
            [cookie(domain: "claude.ai.example.test")],
            [cookie(domain: "other.claude.ai")],
            [cookie(secure: false)],
            [cookie(path: "/other")],
            [cookie(expires: Date(timeIntervalSince1970: 1))],
            [cookie(value: "sk-ant-fixture; injected=1")],
            [valid, cookie(value: "sk-ant-other")]
        ] {
            XCTAssertThrowsError(try ClaudeWebCredentials.capture(cookies: cookies, organizationID: organizationID))
        }
        XCTAssertThrowsError(try ClaudeWebCredentials.capture(cookies: [valid], organizationID: "../other"))
    }

    func testNativeQuotaUsesOnlySuppliedSessionAndPreservesIndependentWindows() async throws {
        let date = Date()
        let session = makeSession(status: 200, body: body) { [self] request in
            XCTAssertEqual(request.url?.absoluteString, "https://claude.ai/api/organizations/\(organizationID)/usage")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-fixture")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pulso/1.0")
        }
        defer { session.invalidateAndCancel() }
        let credentials = credentials()
        let result = try await ClaudeQuotaClient(session: session, now: { date }).fetch(credentials)
        XCTAssertEqual(result.credentials, credentials)
        XCTAssertEqual(result.snapshot.updatedAt, date)
        XCTAssertEqual(result.snapshot.windows.map(\.used), [27, 42])
        XCTAssertNil(result.snapshot.windows[0].resetsAt)
        XCTAssertNotNil(result.snapshot.windows[1].resetsAt)
    }

    func testSuccessfulResponseRenewsOnlyValidatedSessionCookie() async throws {
        let session = makeSession(status: 200, body: body, headers: [
            "Set-Cookie": "sessionKey=sk-ant-renewed; Path=/; Secure; HttpOnly; SameSite=Lax"
        ])
        defer { session.invalidateAndCancel() }
        let result = try await ClaudeQuotaClient(session: session).fetch(credentials())
        XCTAssertEqual(result.credentials.sessionKey, "sk-ant-renewed")
        XCTAssertEqual(result.credentials.organizationID, organizationID)
    }

    func testChallengeAuthenticationRateLimitAndHTMLNeverBecomeQuotaReadings() async {
        for (status, type, body, expected) in [
            (401, "application/json", "{}", ClaudeQuotaError.signIn),
            (403, "application/json", "{}", .signIn),
            (403, "text/html", "<html>Challenge</html>", .cloudflare),
            (429, "application/json", "{}", .http(429)),
            (302, "text/html", "", .http(302)),
            (200, "text/html", "<html>Login</html>", .invalidResponse)
        ] {
            let session = makeSession(status: status, body: body, headers: ["Content-Type": type])
            defer { session.invalidateAndCancel() }
            do {
                _ = try await ClaudeQuotaClient(session: session).fetch(credentials())
                XCTFail("HTTP \(status) must not produce a quota")
            } catch { XCTAssertEqual(error as? ClaudeQuotaError, expected) }
        }
    }

    func testExpiredSessionDoesNotSendNetworkRequest() async {
        let session = makeSession(status: 200, body: body) { _ in XCTFail("Expired credentials must stay local") }
        defer { session.invalidateAndCancel() }
        do {
            let expired = ClaudeWebCredentials(sessionKey: "sk-ant-fixture", organizationID: organizationID,
                                               expiresAt: .distantPast)
            _ = try await ClaudeQuotaClient(session: session).fetch(expired)
            XCTFail("Expired credential must require sign-in")
        } catch { XCTAssertEqual(error as? ClaudeQuotaError, .signIn) }
    }

    func testLiveTransportDeniesRedirectInsteadOfForwardingSessionCookie() throws {
        let client = ClaudeQuotaClient()
        defer { client.session.invalidateAndCancel() }
        let url = URL(string: "https://claude.ai/api/organizations")!
        let task = client.session.dataTask(with: url)
        let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil))
        let delegate = try XCTUnwrap(client.session.delegate as? URLSessionTaskDelegate)
        let denied = expectation(description: "Redirect denied")
        delegate.urlSession?(client.session, task: task, willPerformHTTPRedirection: response,
                             newRequest: URLRequest(url: URL(string: "https://example.test/")!)) { request in
            XCTAssertNil(request)
            denied.fulfill()
        }
        wait(for: [denied], timeout: 1)
    }

    private func credentials() -> ClaudeWebCredentials {
        ClaudeWebCredentials(sessionKey: "sk-ant-fixture", organizationID: organizationID, expiresAt: nil)
    }

    private func cookie(name: String = "sessionKey", value: String = "sk-ant-fixture",
                        domain: String = ".claude.ai", path: String = "/", secure: Bool = true,
                        expires: Date? = nil) -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return HTTPCookie(properties: properties)!
    }

    private func makeSession(status: Int, body: String, headers: [String: String] = [:],
                             inspect: @escaping (URLRequest) -> Void = { _ in }) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.protocolClasses = [ClaudeQuotaURLProtocol.self]
        let identifier = UUID().uuidString
        configuration.httpAdditionalHeaders = ["X-Pulso-Test-ID": identifier]
        ClaudeQuotaURLProtocol.register(identifier: identifier) { request in
            inspect(request)
            return (status, headers, Data(body.utf8))
        }
        return URLSession(configuration: configuration)
    }
}

private final class ClaudeQuotaURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var handlers: [String: (URLRequest) -> (Int, [String: String], Data)] = [:]

    static func register(identifier: String, handler: @escaping (URLRequest) -> (Int, [String: String], Data)) {
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
        let (status, headers, data) = handler(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
