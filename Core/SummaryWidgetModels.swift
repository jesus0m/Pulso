import Foundation

enum SummaryQuotaValue: Equatable {
    case percent(Int)
    case amount(Double)
    case unavailable
}

struct SummaryProviderReading: Identifiable {
    let provider: Provider
    let windows: [UsageWindow]
    let updatedAt: Date?

    var id: Provider { provider }

    func isStale(at date: Date) -> Bool {
        guard let updatedAt, !windows.isEmpty else { return true }
        return updatedAt > date || date.timeIntervalSince(updatedAt) > 300 ||
            windows.contains { $0.resetsAt.map { $0 <= date } ?? false }
    }

    func value(for window: UsageWindow?, display: QuotaDisplay) -> SummaryQuotaValue {
        guard let window else { return .unavailable }
        if let percent = window.displayedPercent(display) { return .percent(percent) }
        let amount = display == .used ? window.used : window.remaining
        guard let amount, amount.isFinite, amount >= 0 else { return .unavailable }
        return .amount(amount)
    }
}

struct SummaryWidgetState {
    let readings: [SummaryProviderReading]
    let display: QuotaDisplay

    init(snapshots: [UsageSnapshot], display: QuotaDisplay) {
        self.display = display
        readings = Provider.allCases.map { provider in
            let snapshot = snapshots.filter { $0.provider == provider }
                .max { $0.updatedAt < $1.updatedAt }
            return SummaryProviderReading(provider: provider, windows: snapshot?.windows ?? [],
                                          updatedAt: snapshot?.updatedAt)
        }
    }

    func transitionDates(after date: Date) -> [Date] {
        let dates = readings.flatMap { reading -> [Date] in
            guard let updatedAt = reading.updatedAt else { return [] }
            let snapshot = UsageSnapshot(provider: reading.provider, windows: reading.windows,
                                         updatedAt: updatedAt, source: "")
            return QuotaTimeline.transitionDates(for: snapshot, after: date)
        }
        return Set(dates).sorted()
    }
}
