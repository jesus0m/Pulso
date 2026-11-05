import CryptoKit
import Foundation
import Security

struct CodexCredentials: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String?
    let idToken: String?
    let accountID: String?
    let email: String?
    let expiresAt: Date?

    func needsRefresh(at now: Date) -> Bool {
        expiresAt.map { $0 <= now.addingTimeInterval(300) } ?? false
    }
}

enum CodexAuthError: LocalizedError, Equatable {
    case random, callback, denied, listener, timeout, browser, invalidResponse, signIn, forbidden
    case http(Int), keychain(Int32)

    var errorDescription: String? {
        switch self {
        case .random: return String(localized: "No se pudo preparar un inicio de sesión seguro.")
        case .callback: return String(localized: "No se pudo verificar la respuesta del inicio de sesión.")
        case .denied: return String(localized: "No se ha autorizado la conexión con ChatGPT.")
        case .listener: return String(localized: "No se pudo abrir el receptor local del inicio de sesión. Vuelve a intentarlo.")
        case .timeout: return String(localized: "El inicio de sesión ha tardado demasiado. Vuelve a intentarlo.")
        case .browser: return String(localized: "No se pudo abrir la ventana segura de ChatGPT.")
        case .invalidResponse: return String(localized: "ChatGPT devolvió una respuesta de autenticación no compatible.")
        case .signIn: return String(localized: "La sesión de Codex ha caducado o no es válida. Vuelve a entrar con ChatGPT.")
        case .forbidden: return String(localized: "ChatGPT no permite consultar la cuota de Codex con esta cuenta.")
        case .http(let code): return String(localized: "No se pudo consultar ChatGPT (HTTP \(code)).")
        case .keychain(let status): return String(localized: "No se pudo acceder al llavero del iPhone (\(status)).")
        }
    }
}

enum CodexOAuth {
    // Public Codex registration, not a Pulso-issued client. Quota access is experimental.
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!

    struct Attempt {
        let state: String
        let verifier: String
    }

    static func makeAttempt() throws -> Attempt {
        func random(_ count: Int) throws -> String {
            var bytes = [UInt8](repeating: 0, count: count)
            guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else {
                throw CodexAuthError.random
            }
            return base64URL(Data(bytes))
        }
        return try Attempt(state: random(32), verifier: random(64))
    }

    static func challenge(_ verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func authorizationURL(redirect: URL, attempt: Attempt) -> URL {
        var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
        url.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirect.absoluteString),
            .init(name: "response_type", value: "code"),
            .init(name: "scope", value: "openid profile email offline_access"),
            .init(name: "state", value: attempt.state),
            .init(name: "code_challenge", value: challenge(attempt.verifier)),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "id_token_add_organizations", value: "true"),
            .init(name: "codex_cli_simplified_flow", value: "true"),
            .init(name: "originator", value: "codex_cli_rs")
        ]
        return url.url!
    }

    static func authorizationCode(callback: URL, redirect: URL, state: String) throws -> String {
        guard callback.scheme == redirect.scheme, callback.host == redirect.host,
              callback.port == redirect.port, callback.path == redirect.path,
              let query = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems else {
            throw CodexAuthError.callback
        }
        func values(_ name: String) -> [String] {
            query.filter { $0.name == name }.map { $0.value ?? "" }
        }
        guard values("state") == [state] else { throw CodexAuthError.callback }
        guard values("error").isEmpty else { throw CodexAuthError.denied }
        let codes = values("code")
        guard codes.count == 1, !codes[0].isEmpty else { throw CodexAuthError.callback }
        return codes[0]
    }
}

struct CodexOAuthClient {
    let session: URLSession
    var now: () -> Date = Date.init

    init(session: URLSession? = nil, now: @escaping () -> Date = Date.init) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        self.session = session ?? URLSession(configuration: configuration, delegate: CodexOAuthRedirectPolicy(), delegateQueue: nil)
        self.now = now
    }

    func exchange(code: String, redirect: URL, verifier: String) async throws -> CodexCredentials {
        try await tokens([
            ("grant_type", "authorization_code"), ("code", code),
            ("redirect_uri", redirect.absoluteString), ("code_verifier", verifier)
        ], previous: nil)
    }

    func refresh(_ credentials: CodexCredentials) async throws -> CodexCredentials {
        guard let refresh = credentials.refreshToken, !refresh.isEmpty else { throw CodexAuthError.signIn }
        return try await tokens([("grant_type", "refresh_token"), ("refresh_token", refresh)], previous: credentials)
    }

    private func tokens(_ fields: [(String, String)], previous: CodexCredentials?) async throws -> CodexCredentials {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = (fields + [("client_id", CodexOAuth.clientID)]).map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
        }.joined(separator: "&")
        var request = URLRequest(url: CodexOAuth.tokenURL, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        let data = try await perform(request)
        guard let reply = try? JSONDecoder().decode(TokenReply.self, from: data),
              !reply.access_token.isEmpty else { throw CodexAuthError.invalidResponse }
        let idToken = reply.id_token ?? previous?.idToken
        // Claims are display/routing hints only, never proof of a verified identity.
        let claims = payload(reply.access_token)
        let identity = idToken.map(payload) ?? [:]
        let account = (identity["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            ?? (claims["https://api.openai.com/auth"] as? [String: Any])?["chatgpt_account_id"] as? String
            ?? previous?.accountID
        let expiry = reply.expires_in.map { now().addingTimeInterval($0) }
            ?? (claims["exp"] as? Double).map(Date.init(timeIntervalSince1970:))
        return CodexCredentials(accessToken: reply.access_token, refreshToken: reply.refresh_token ?? previous?.refreshToken,
                                idToken: idToken, accountID: account,
                                email: identity["email"] as? String ?? previous?.email, expiresAt: expiry)
    }

    func fetchUsage(_ credentials: CodexCredentials) async throws -> UsageSnapshot {
        // Private ChatGPT backend, not a public quota API for third-party clients.
        var request = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Pulso", forHTTPHeaderField: "User-Agent")
        if let accountID = credentials.accountID, !accountID.isEmpty {
            request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-Id")
        }
        var snapshot = try CodexUsageParser.parse(await perform(request), now: now())
        snapshot.source = "Codex · OAuth experimental · API no pública"
        return snapshot
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw CodexAuthError.invalidResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401: throw CodexAuthError.signIn
        case 403: throw CodexAuthError.forbidden
        default: throw CodexAuthError.http(http.statusCode)
        }
    }

    private func payload(_ jwt: String) -> [String: Any] {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return [:] }
        var text = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        guard let data = Data(base64Encoded: text),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    private struct TokenReply: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let expires_in: Double?
    }
}

private final class CodexOAuthRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum CodexCredentialVault {
    private static let item = SharedKeychain(service: "com.jesusom.pulso.codex", account: "oauth")

    static func load() throws -> CodexCredentials? {
        guard let data = try item.load() else { return nil }
        return try JSONDecoder().decode(CodexCredentials.self, from: data)
    }

    static func save(_ credentials: CodexCredentials) throws {
        try SharedQuotaAccess.transaction { try item.save(JSONEncoder().encode(credentials)) }
    }

    static func delete() throws {
        try SharedQuotaAccess.transaction { try item.delete() }
    }

    static func replace(_ credentials: CodexCredentials, matching previous: CodexCredentials) throws {
        try SharedQuotaAccess.transaction {
            guard try load() == previous else { throw CancellationError() }
            try save(credentials)
        }
    }
}
