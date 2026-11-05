import Foundation
import UserNotifications

/// Each reading already carries the exact reset instant, so the alert is scheduled
/// for that moment rather than waiting for a later refresh to notice it passed.
enum ResetNotifier {
    private static let prefix = "reset."
    private static let foregroundDelegate = ForegroundNotificationDelegate()

    static func configureForegroundPresentation() {
        UNUserNotificationCenter.current().delegate = foregroundDelegate
    }

    struct Pending: Equatable {
        let id: String
        let title: String
        let body: String
        let fireAt: Date
    }

    private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }

    /// Only future resets, newest reading wins, and one alert per window.
    static func pending(for snapshots: [UsageSnapshot], now: Date) -> [Pending] {
        snapshots.flatMap { snapshot in
            snapshot.windows.compactMap { window -> Pending? in
                guard let reset = window.resetsAt, reset > now else { return nil }
                return Pending(id: "\(prefix)\(snapshot.provider.rawValue).\(window.id)",
                               title: String(localized: "\(snapshot.provider.title) renovada"),
                               body: String(localized: "\(window.localizedTitle) vuelve a estar al 100 %."),
                               fireAt: reset)
            }
        }
    }

    static func reschedule(for snapshots: [UsageSnapshot], enabled: Bool,
                           now: Date = Date(), center: UNUserNotificationCenter = .current()) {
        center.getPendingNotificationRequests { requests in
            let mine = requests.map(\.identifier).filter { $0.hasPrefix(prefix) }
            center.removePendingNotificationRequests(withIdentifiers: mine)
            guard enabled else { return }
            for item in pending(for: snapshots, now: now) {
                let content = UNMutableNotificationContent()
                content.title = item.title
                content.body = item.body
                content.sound = .default
                let components = Calendar.current.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: item.fireAt)
                let request = UNNotificationRequest(
                    identifier: item.id, content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
                center.add(request)
            }
        }
    }

    static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])) ?? false
    }
}
