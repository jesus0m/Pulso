import Foundation
import Security

/// Access token copied by the user from chatgpt.com/api/auth/session in regular Safari.
enum CodexPastedToken {
    enum TokenError: LocalizedError {
        case notFound, expired, unavailable
        var errorDescription: String? {
            switch self {
            case .notFound: return String(localized: "No se ha encontrado un token de ChatGPT en el texto copiado.")
            case .expired: return String(localized: "El token de ChatGPT ha caducado. Abre la sesión en Safari y pega uno nuevo.")
            case .unavailable: return String(localized: "No se ha podido consultar Codex. Comprueba la conexión.")
            }
        }
    }

    static let sessionURL = URL(string: "https://chatgpt.com/api/auth/session")!
    private static let usageURL = URL(string: "https://chatgpt.com/backend-api/wham/usage")!

    /// Accepts the whole session JSON or a bare JWT.
    static func extractToken(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = object["accessToken"] as? String, looksLikeJWT(token) { return token }
        let bare = trimmed.replacingOccurrences(of: "Bearer ", with: "")
        return looksLikeJWT(bare) ? bare : nil
    }

    static func email(from text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let user = object["user"] as? [String: Any] else { return nil }
        return user["email"] as? String
    }

    static func fetchUsage(token: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: usageURL, timeoutInterval: 15)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let data: Data, response: URLResponse
        do { (data, response) = try await URLSession.shared.data(for: request) }
        catch { throw TokenError.unavailable }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw TokenError.unavailable }
        if status == 401 || status == 403 { throw TokenError.expired }
        guard status == 200 else { throw TokenError.unavailable }
        return try CodexUsageParser.parse(data)
    }

    private static func looksLikeJWT(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty } && !value.contains(where: \.isWhitespace)
    }

    // MARK: Keychain

    private static let item = SharedKeychain(service: "com.jesusom.pulso.codex-token", account: "access-token")

    static func save(_ token: String) throws {
        try item.save(Data(token.utf8))
    }

    static func load() -> String? {
        guard let data = try? item.load() else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() throws { try item.delete() }
}
