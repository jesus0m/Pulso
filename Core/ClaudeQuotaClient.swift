import Foundation

struct ClaudeWebCredentials: Codable, Equatable, Sendable {
    let sessionKey: String
    let organizationID: String
    let expiresAt: Date?

    func validate(at now: Date) throws {
        guard UUID(uuidString: organizationID) != nil, sessionKey.hasPrefix("sk-ant-"),
              sessionKey.utf8.allSatisfy({ (33...126).contains($0) && ![34, 44, 59, 92].contains($0) }),
              expiresAt.map({ $0 > now }) ?? true else { throw ClaudeQuotaError.signIn }
    }

    static func capture(cookies: [HTTPCookie], organizationID: String, now: Date = Date()) throws -> Self {
        let matches = cookies.filter {
            $0.name == "sessionKey" && ["claude.ai", ".claude.ai"].contains($0.domain.lowercased())
                && $0.path == "/" && $0.isSecure && ($0.expiresDate.map { $0 > now } ?? true)
        }
        guard let cookie = matches.first, Set(matches.map(\.value)).count == 1 else { throw ClaudeQuotaError.signIn }
        let credentials = Self(sessionKey: cookie.value, organizationID: organizationID, expiresAt: cookie.expiresDate)
        try credentials.validate(at: now)
        return credentials
    }
}

struct ClaudeCredentialVault {
    static let shared = Self()
    var keychain = SharedKeychain(service: "com.jesusom.pulso.claude", account: "web-session", legacyGroup: nil)

    func load() throws -> ClaudeWebCredentials? {
        try SharedQuotaAccess.transaction {
            guard let data = try keychain.load() else { return nil }
            return try JSONDecoder().decode(ClaudeWebCredentials.self, from: data)
        }
    }

    func save(_ credentials: ClaudeWebCredentials) throws {
        try credentials.validate(at: Date())
        try SharedQuotaAccess.transaction { try keychain.save(JSONEncoder().encode(credentials)) }
    }

    func replace(_ credentials: ClaudeWebCredentials, matching previous: ClaudeWebCredentials) throws {
        try SharedQuotaAccess.transaction {
            guard try load() == previous else { throw CancellationError() }
            try save(credentials)
        }
    }

    func delete() throws {
        try SharedQuotaAccess.transaction { try keychain.delete() }
    }
}

enum ClaudeQuotaError: LocalizedError, Equatable {
    case signIn, cloudflare, invalidResponse, http(Int)

    var errorDescription: String? {
        switch self {
        case .signIn: return String(localized: "Abre la sesión de Claude en Pulso para renovar el acceso del widget.")
        case .cloudflare: return String(localized: "Claude pide una comprobación web. Abre su sesión en Pulso; el widget conserva la última lectura.")
        case .invalidResponse: return String(localized: "Claude ha devuelto una respuesta de cuota no compatible.")
        case .http(let status): return String(localized: "No se pudo consultar la cuota de Claude (HTTP \(status)).")
        }
    }
}

struct ClaudeQuotaClient {
    struct Reading {
        let snapshot: UsageSnapshot
        let credentials: ClaudeWebCredentials
    }

    let session: URLSession
    var now: () -> Date

    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        self.session = session ?? URLSession(configuration: configuration, delegate: ClaudeQuotaRedirectPolicy(), delegateQueue: nil)
        self.now = now
    }

    func fetch(_ credentials: ClaudeWebCredentials) async throws -> Reading {
        try credentials.validate(at: now())
        // Same private web endpoint used by Claude's usage page and CodexBar's cookie client.
        let url = URL(string: "https://claude.ai/api/organizations/\(credentials.organizationID)/usage")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        request.httpShouldHandleCookies = false
        request.setValue("sessionKey=\(credentials.sessionKey)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pulso/1.0", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse, http.url == url else { throw ClaudeQuotaError.invalidResponse }
        let headers = http.allHeaderFields.reduce(into: [String: String]()) { result, field in
            result[String(describing: field.key)] = String(describing: field.value)
        }
        let contentType = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
        if http.value(forHTTPHeaderField: "cf-mitigated")?.lowercased() == "challenge"
            || (http.statusCode == 403 && contentType.contains("text/html")) {
            throw ClaudeQuotaError.cloudflare
        }
        if http.statusCode == 401 || http.statusCode == 403 { throw ClaudeQuotaError.signIn }
        guard http.statusCode == 200 else { throw ClaudeQuotaError.http(http.statusCode) }
        guard !contentType.contains("text/html"), data.count <= 256_000 else { throw ClaudeQuotaError.invalidResponse }
        let snapshot = try ClaudeUsageParser.parse(data, now: now())
        var updated = credentials
        let cookies = HTTPCookie.cookies(withResponseHeaderFields: headers, for: url).filter { $0.name == "sessionKey" }
        if !cookies.isEmpty {
            updated = try ClaudeWebCredentials.capture(cookies: cookies, organizationID: credentials.organizationID, now: now())
        }
        return Reading(snapshot: snapshot, credentials: updated)
    }
}

private final class ClaudeQuotaRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
