import Foundation

/// Experimental Claude same-origin schema; this is not Anthropic's public API.
enum ClaudeUsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw UsageError.unsupportedSchema
        }
        let standard = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var windows: [UsageWindow] = []
        for (id, title, raw) in [
            ("five_hour", "Sesión · 5 h", payload.five_hour),
            ("seven_day", "Semana", payload.seven_day),
            ("seven_day_opus", "Semana · Opus", payload.seven_day_opus),
            ("seven_day_sonnet", "Semana · Sonnet", payload.seven_day_sonnet)
        ] {
            guard let raw else { continue }
            guard raw.utilization.isFinite, (0...100).contains(raw.utilization) else {
                throw UsageError.unsupportedSchema
            }
            let reset: Date?
            if let text = raw.resets_at {
                guard let parsed = fractional.date(from: text) ?? standard.date(from: text) else {
                    throw UsageError.unsupportedSchema
                }
                reset = parsed
            } else {
                reset = nil
            }
            windows.append(UsageWindow(id: id, title: title, used: raw.utilization, limit: 100, resetsAt: reset))
        }
        guard !windows.isEmpty else { throw UsageError.unsupportedSchema }
        return UsageSnapshot(provider: .claude, windows: windows, updatedAt: now,
                             source: "Claude · sesión web experimental")
    }

    private struct Payload: Decodable {
        let five_hour: Window?
        let seven_day: Window?
        let seven_day_opus: Window?
        let seven_day_sonnet: Window?
    }

    private struct Window: Decodable {
        let utilization: Double
        let resets_at: String?

        private enum CodingKeys: String, CodingKey { case utilization, resets_at }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            utilization = try values.decode(Double.self, forKey: .utilization)
            // A present null means the renewal is unknown; a missing field is schema drift.
            resets_at = try values.decode(String?.self, forKey: .resets_at)
        }
    }
}
