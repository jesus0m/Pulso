import Foundation

/// Experimental ChatGPT same-origin schema; this is not a public OpenAI API.
enum CodexUsageParser {
    static func parse(_ data: Data, now: Date = Date()) throws -> UsageSnapshot {
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              let rate = payload.rate_limit else { throw UsageError.unsupportedSchema }
        var windows: [UsageWindow] = []
        for (id, raw) in [("primary", rate.primary_window), ("secondary", rate.secondary_window)] {
            guard let raw else { continue }
            guard raw.used_percent.isFinite, (0...100).contains(raw.used_percent),
                  raw.reset_at.isFinite, raw.reset_at > 0,
                  raw.limit_window_seconds > 0 else { throw UsageError.unsupportedSchema }
            let seconds = raw.limit_window_seconds
            let duration: String
            if seconds % 86_400 == 0 { duration = "\(seconds / 86_400) d" }
            else if seconds % 3_600 == 0 { duration = "\(seconds / 3_600) h" }
            else { duration = "\(seconds) s" }
            // Matches Claude's "Sesión"/"Semana" labelling so both providers read the same way.
            let title = id == "primary" ? "Sesión · \(duration)" : "Semana · \(duration)"
            windows.append(UsageWindow(id: id, title: title, used: raw.used_percent, limit: 100,
                                       resetsAt: Date(timeIntervalSince1970: raw.reset_at)))
        }
        guard !windows.isEmpty else { throw UsageError.unsupportedSchema }
        return UsageSnapshot(provider: .codex, windows: windows, updatedAt: now,
                             source: "ChatGPT · sesión web experimental")
    }

    private struct Payload: Decodable { let rate_limit: RateLimit? }
    private struct RateLimit: Decodable { let primary_window: Window?; let secondary_window: Window? }
    private struct Window: Decodable {
        let used_percent: Double
        let reset_at: Double
        let limit_window_seconds: Int
    }
}
