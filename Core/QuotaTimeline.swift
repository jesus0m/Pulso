import Foundation

enum QuotaTimeline {
    static func transitionDates(for snapshot: UsageSnapshot?, after now: Date) -> [Date] {
        guard let snapshot else { return [] }
        let dates = [snapshot.updatedAt.addingTimeInterval(301)] + snapshot.windows.compactMap(\.resetsAt)
        return Set(dates.filter { $0 > now }).sorted()
    }
}
