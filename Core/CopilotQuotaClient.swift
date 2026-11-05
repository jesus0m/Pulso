import Foundation

/// Experimental per-account endpoint, separate from GitHub's public billing reports.
/// Its private schema may change or omit quotas for organization-managed seats.
struct CopilotQuotaClient {
    var session: URLSession = .shared
    var clock: @Sendable () -> Date = { Date() }

    func fetch(token: String, allowance: Double? = nil) async throws -> UsageSnapshot {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw UsageError.invalidCredentials
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!,
                                 cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("PULSO/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue("2026-03-10", forHTTPHeaderField: "X-GitHub-Api-Version")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw UsageError.invalidResponse }
        #if DEBUG
        // Record field names only, never the response values or credential, for schema diagnosis.
        if response.statusCode == 200,
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let quotas = object["quota_snapshots"] as? [String: Any] ?? [:]
            let fields: [String: Any] = [
                "fields": object.keys.sorted(),
                "quotaFields": quotas.mapValues { ($0 as? [String: Any])?.keys.sorted() ?? [] },
                "tokenBasedBilling": object["token_based_billing"] as? Bool ?? false
            ]
            if let metadata = try? JSONSerialization.data(withJSONObject: fields, options: .sortedKeys) {
                try? metadata.write(to: cache.appendingPathComponent("CopilotQuotaShape.json"), options: .atomic)
            }
        }
        #endif
        switch response.statusCode {
        case 200: return try Self.parse(data, allowance: allowance, now: clock())
        case 401, 403: throw CopilotQuotaError.accessDenied(response.statusCode)
        case 404: throw CopilotQuotaError.unavailable
        default: throw CopilotQuotaError.http(response.statusCode)
        }
    }

    static func parse(_ data: Data, allowance: Double? = nil, now: Date = Date()) throws -> UsageSnapshot {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw CopilotQuotaError.unsupportedSchema
        }
        let plan = payload.copilot_plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        let planSuffix = plan.flatMap { $0.isEmpty ? nil : " · plan \($0)" } ?? ""
        if payload.token_based_billing == true {
            // Keep the balance and allowance from the same quota; never add duplicate chat credits.
            let quota = payload.quota_snapshots?.premium_interactions?.credits_used != nil
                ? payload.quota_snapshots?.premium_interactions : payload.quota_snapshots?.chat
            guard let quota, let credits = quota.credits_used else {
                throw CopilotQuotaError.noPublishedQuota
            }
            guard credits.isFinite, credits >= 0 else { throw CopilotQuotaError.unsupportedSchema }
            if let remaining = quota.remaining {
                guard remaining.isFinite, remaining >= 0 else { throw CopilotQuotaError.unsupportedSchema }
            }
            if let percent = quota.percent_remaining {
                guard percent.isFinite, (0...100).contains(percent) else { throw CopilotQuotaError.unsupportedSchema }
            }
            let limit = [quota.entitlement, allowance].compactMap { $0 }.first { $0.isFinite && $0 > 0 }
            let reset = payload.quota_reset_date.flatMap(parseResetDate)
            return UsageSnapshot(provider: .copilot,
                                 windows: [UsageWindow(id: "copilot_credits", title: "Créditos usados · cuenta",
                                                       used: credits, limit: limit, resetsAt: reset,
                                                       remaining: quota.remaining, reportedRemainingPercent: quota.percent_remaining)],
                                 updatedAt: now,
                                 source: "Copilot · créditos comunicados · cuenta experimental" + planSuffix)
        }
        let reset: Date?
        if let text = payload.quota_reset_date {
            guard let date = parseResetDate(text) else { throw CopilotQuotaError.unsupportedSchema }
            reset = date
        } else {
            reset = nil
        }
        var windows: [UsageWindow] = []
        for (id, title, quota) in [
            ("copilot_premium", "Premium · cuenta", payload.quota_snapshots?.premium_interactions),
            ("copilot_chat", "Chat · cuenta", payload.quota_snapshots?.chat)
        ] {
            guard let quota else { continue }
            guard !quota.invalidEntitlement else { throw CopilotQuotaError.unsupportedSchema }
            guard quota.unlimited != true else { continue }
            guard let entitlement = quota.entitlement, entitlement.isFinite, entitlement > 0,
                  let remaining = quota.percent_remaining else { continue }
            guard remaining.isFinite, (0...100).contains(remaining) else {
                throw CopilotQuotaError.unsupportedSchema
            }
            var used = entitlement * (1 - remaining / 100)
            if let overage = quota.overage_count {
                guard overage.isFinite, overage >= 0 else { throw CopilotQuotaError.unsupportedSchema }
                // Overage is additional to the included quota. Only combine when the
                // published percentage agrees the included quota is exhausted.
                if remaining == 0 { used += overage }
            }
            guard used.isFinite else { throw CopilotQuotaError.unsupportedSchema }
            windows.append(UsageWindow(id: id, title: title, used: used, limit: entitlement, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw CopilotQuotaError.noPublishedQuota }
        return UsageSnapshot(provider: .copilot, windows: windows, updatedAt: now,
                             source: "Copilot · cuota de cuenta experimental" + planSuffix)
    }

    private static func parseResetDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text) { return date }
        guard text.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.isLenient = false
        formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: text), formatter.string(from: date) == text else { return nil }
        return date
    }

    private struct Payload: Decodable {
        let copilot_plan: String?
        let token_based_billing: Bool?
        let quota_reset_date: String?
        let quota_snapshots: Quotas?
    }

    private struct Quotas: Decodable {
        let premium_interactions: Quota?
        let chat: Quota?
    }

    private struct Quota: Decodable {
        let entitlement: Double?
        let invalidEntitlement: Bool
        let percent_remaining: Double?
        let remaining: Double?
        let unlimited: Bool?
        let overage_count: Double?
        let credits_used: Double?

        private enum CodingKeys: String, CodingKey {
            case entitlement, percent_remaining, remaining, unlimited, overage_count, credits_used
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.container(keyedBy: CodingKeys.self)
            // Invalid entitlements may fall back to a manual limit only in the AI Credits branch.
            entitlement = try? fields.decodeIfPresent(Double.self, forKey: .entitlement)
            invalidEntitlement = entitlement == nil && (try? fields.decodeNil(forKey: .entitlement)) == false
            percent_remaining = try fields.decodeIfPresent(Double.self, forKey: .percent_remaining)
            remaining = try fields.decodeIfPresent(Double.self, forKey: .remaining)
            unlimited = try fields.decodeIfPresent(Bool.self, forKey: .unlimited)
            overage_count = try fields.decodeIfPresent(Double.self, forKey: .overage_count)
            credits_used = try fields.decodeIfPresent(Double.self, forKey: .credits_used)
        }
    }
}

enum CopilotQuotaError: Error, Equatable, LocalizedError {
    case noPublishedQuota, unsupportedSchema, accessDenied(Int), unavailable, http(Int)

    var errorDescription: String? {
        switch self {
        case .noPublishedQuota:
            return String(localized: "Copilot no publica una cuota medible para esta cuenta. No se puede calcular el uso restante.")
        case .unsupportedSchema:
            return String(localized: "Copilot devolvió un formato de cuota no compatible.")
        case .accessDenied(let status):
            return String(localized: "Copilot no permite consultar la cuota (HTTP \(status)). El token puede servir para facturación y necesitar Copilot Requests de lectura en un token personal detallado, o estar limitado por la política de tu organización.")
        case .unavailable:
            return String(localized: "La cuota de cuenta de Copilot no está disponible (HTTP 404).")
        case .http(let status):
            return String(localized: "No se pudo consultar la cuota de Copilot (HTTP \(status)).")
        }
    }
}
