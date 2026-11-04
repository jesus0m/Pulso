import Foundation

/// User reports cover personally billed plans only, not organization-managed seats.
/// https://docs.github.com/en/rest/billing/usage
struct GitHubUsageClient {
    var session: URLSession = .shared
    var clock: @Sendable () -> Date = { Date() }

    func fetch(username: String, token: String, allowance: Double?, legacy: Bool) async throws -> UsageSnapshot {
        let username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !username.isEmpty, username.count <= 39,
              username.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", options: .regularExpression) != nil,
              !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw UsageError.invalidCredentials
        }
        try Self.validateAllowance(allowance)
        let now = clock()
        let calendar = Self.utcCalendar
        let parts = calendar.dateComponents([.year, .month], from: now)
        let endpoint = legacy ? "premium_request" : "ai_credit"
        var url = URLComponents(string: "https://api.github.com/users/\(username)/settings/billing/\(endpoint)/usage")!
        url.queryItems = [URLQueryItem(name: "year", value: String(parts.year!)),
                          URLQueryItem(name: "month", value: String(parts.month!))]
        var request = URLRequest(url: url.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        guard response.statusCode == 200 else { throw UsageError.http(response.statusCode) }
        return try Self.parse(data, allowance: allowance, legacy: legacy, now: now)
    }

    static func parse(_ data: Data, allowance: Double?, legacy: Bool, now: Date = Date()) throws -> UsageSnapshot {
        try validateAllowance(allowance)
        guard let payload = try? JSONDecoder().decode(Report.self, from: data) else { throw UsageError.unsupportedSchema }
        var used: Double = 0
        var matchingRows = 0
        for row in payload.usageItems {
            let product = row.product.lowercased()
            guard product == "copilot" || product == "copilot ai credits" else { continue }
            let validUnit = legacy ? row.unitType.lowercased() == "requests"
                : ["ai-credits", "credits"].contains(row.unitType.lowercased())
            guard validUnit, row.grossQuantity.isFinite, row.grossQuantity >= 0 else {
                throw UsageError.unsupportedSchema
            }
            matchingRows += 1
            used += row.grossQuantity
        }
        guard matchingRows > 0 else { throw UsageError.noUsageData }
        guard used.isFinite else { throw UsageError.unsupportedSchema }
        let calendar = utcCalendar
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: now))!
        let reset = calendar.date(byAdding: .month, value: 1, to: start)
        let unit = legacy ? "solicitudes premium" : "créditos IA"
        return UsageSnapshot(provider: .copilot,
                             windows: [UsageWindow(id: legacy ? "premium_requests" : "ai_credits",
                                                   title: "Mes · \(unit)", used: used, limit: allowance, resetsAt: reset)],
                             updatedAt: now,
                             source: "GitHub API · uso bruto · " + (allowance == nil ? "límite desconocido" : "límite manual"))
    }

    private static func validateAllowance(_ allowance: Double?) throws {
        if let allowance, !allowance.isFinite || allowance <= 0 { throw UsageError.invalidAllowance }
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private struct Report: Decodable { let usageItems: [Row] }
    private struct Row: Decodable {
        let product: String
        let unitType: String
        let grossQuantity: Double
    }
}
