import Foundation
import Security

/// Device-bound credentials shared only with the iOS widget extension.
enum TokenVault {
    enum Availability {
        case available(String)
        case missing
        case temporarilyUnavailable
    }

    private static let item = SharedKeychain(service: "com.jesusom.pulso.github", account: "personal-token")

    static func save(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError.invalidCredentials }
        try item.save(Data(token.utf8))
    }

    static func read() -> String? {
        guard case let .available(token) = availability() else { return nil }
        return token
    }

    static func availability() -> Availability {
        do {
            guard let data = try item.load() else { return .missing }
            guard let token = String(data: data, encoding: .utf8), !token.isEmpty else { return .temporarilyUnavailable }
            return .available(token)
        } catch { return .temporarilyUnavailable }
    }

    static func delete() throws {
        try item.delete()
    }
}
