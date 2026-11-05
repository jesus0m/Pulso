import ActivityKit
import Foundation

struct QuotaActivityAttributes: ActivityAttributes {
    let providerID: String
    let startedAt: Date

    var provider: Provider { Provider(rawValue: providerID) ?? .codex }

    struct ContentState: Codable, Hashable {
        let windows: [Window]
        let updatedAt: Date
        let showsUsed: Bool
        var refreshFailed: Bool

        var primary: Window? { windows.first }

        func staleDate(now: Date) -> Date {
            let ageBoundary = min(updatedAt, now).addingTimeInterval(300)
            let resetBoundary = windows.compactMap(\.resetsAt).min() ?? ageBoundary
            return refreshFailed ? now : min(ageBoundary, resetBoundary)
        }

        static func make(snapshot: UsageSnapshot, display: QuotaDisplay, refreshFailed: Bool = false) -> Self? {
            guard !snapshot.windows.isEmpty, snapshot.updatedAt.timeIntervalSince1970.isFinite else { return nil }
            let windows = snapshot.windows.map { window in
                Window(
                    kind: Window.Kind(windowID: window.id),
                    usedPercent: window.displayedUsedPercent,
                    remainingPercent: window.displayedRemainingPercent,
                    used: validAmount(window.used),
                    remaining: validAmount(window.remaining) ?? derivedRemaining(window),
                    limit: window.limit.flatMap { $0 > 0 ? validAmount($0) : nil },
                    resetsAt: window.resetsAt.flatMap { $0.timeIntervalSince1970.isFinite ? $0 : nil }
                )
            }
            return Self(windows: windows, updatedAt: snapshot.updatedAt,
                        showsUsed: display == .used, refreshFailed: refreshFailed)
        }

        private static func validAmount(_ value: Double?) -> Double? {
            value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        }

        private static func derivedRemaining(_ window: UsageWindow) -> Double? {
            guard let limit = window.limit, limit.isFinite, limit > 0,
                  window.used.isFinite, window.used >= 0 else { return nil }
            return max(0, limit - window.used)
        }
    }

    struct Window: Codable, Hashable {
        enum Kind: String, Codable, Hashable {
            case session, week, opus, sonnet, month, credits, premium, chat, quota

            init(windowID: String) {
                switch windowID {
                case "primary", "session", "five_hour": self = .session
                case "secondary", "week", "seven_day": self = .week
                case "seven_day_opus": self = .opus
                case "seven_day_sonnet": self = .sonnet
                case "month": self = .month
                case "copilot_credits", "ai_credits": self = .credits
                case "premium_interactions", "premium_requests": self = .premium
                case "chat": self = .chat
                default: self = .quota
                }
            }

            var title: String {
                switch self {
                case .session: return String(localized: "Sesión")
                case .week: return String(localized: "Semana")
                case .opus: return String(localized: "Semana · Opus")
                case .sonnet: return String(localized: "Semana · Sonnet")
                case .month: return String(localized: "Mes")
                case .credits: return String(localized: "Créditos del mes")
                case .premium: return String(localized: "Peticiones premium")
                case .chat: return "Chat"
                case .quota: return String(localized: "Cuota")
                }
            }
        }

        let kind: Kind
        let usedPercent: Int?
        let remainingPercent: Int?
        let used: Double?
        let remaining: Double?
        let limit: Double?
        let resetsAt: Date?

        func percent(showsUsed: Bool) -> Int? { showsUsed ? usedPercent : remainingPercent }
    }
}
