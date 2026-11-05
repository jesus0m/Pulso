import XCTest
@testable import Pulso

final class SummaryWidgetTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testMixedReadingsKeepEveryProviderInStableOrderAndMissingQuotaUnknown() {
        let state = SummaryWidgetState(snapshots: [
            snapshot(.claude, used: 23),
            snapshot(.codex, used: 61, updatedAt: now.addingTimeInterval(-60)),
            snapshot(.codex, used: 19)
        ], display: .remaining)

        XCTAssertEqual(state.readings.map(\.provider), Provider.allCases)
        XCTAssertEqual(value(state.readings[0], in: state), .percent(81))
        XCTAssertEqual(value(state.readings[1], in: state), .unavailable)
        XCTAssertEqual(value(state.readings[2], in: state), .percent(77))
        XCTAssertNil(state.readings[1].updatedAt)
        XCTAssertTrue(state.readings[1].isStale(at: now))
    }

    func testPreferenceAppliesToAllWindowsWithoutInventingUnknownRemainingBalances() {
        let reading = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "session", title: "Sesión", used: 28, limit: 100),
            UsageWindow(id: "week", title: "Semana", used: 46, limit: 100),
            UsageWindow(id: "unknown", title: "Límite desconocido", used: 12, limit: nil),
            UsageWindow(id: "balance", title: "Saldo", used: 5, limit: nil, remaining: 17),
            UsageWindow(id: "invalid", title: "Inválida", used: .nan, limit: nil, remaining: .infinity)
        ], updatedAt: now, source: "")
        let used = SummaryWidgetState(snapshots: [reading], display: .used)
        let remaining = SummaryWidgetState(snapshots: [reading], display: .remaining)
        let row = used.readings[0]

        XCTAssertEqual(row.windows.map { row.value(for: $0, display: used.display) },
                       [.percent(28), .percent(46), .amount(12), .amount(5), .unavailable])
        XCTAssertEqual(row.windows.map { row.value(for: $0, display: remaining.display) },
                       [.percent(72), .percent(54), .unavailable, .amount(17), .unavailable])
    }

    func testCopilotIndependentBalancesSurviveAlongsideOtherProviderQuotas() throws {
        let credits = UsageWindow(id: "copilot_credits", title: "Mes", used: 6134, limit: 60000,
                                  remaining: 53774, reportedRemainingPercent: 89.6)
        let state = SummaryWidgetState(snapshots: [
            snapshot(.codex, used: 40),
            UsageSnapshot(provider: .copilot, windows: [credits], updatedAt: now, source: "private metadata"),
            snapshot(.claude, used: 70)
        ], display: .remaining)
        let row = state.readings[1]
        let copied = try XCTUnwrap(row.windows.first)
        XCTAssertEqual(copied.used, 6134)
        XCTAssertEqual(copied.limit, 60000)
        XCTAssertEqual(copied.remaining, 53774)
        XCTAssertEqual(copied.reportedRemainingPercent, 89.6)
        XCTAssertEqual(row.value(for: copied, display: .remaining), .percent(90))
        XCTAssertEqual(row.value(for: copied, display: .used), .percent(10))
        XCTAssertEqual(state.readings.map { value($0, in: state) },
                       [.percent(60), .percent(90), .percent(30)])
    }

    func testMergedTimelineIncludesEveryProviderAndWindowWithoutDuplicatesOrPastDates() {
        var codex = snapshot(.codex, used: 28)
        codex.windows[0].resetsAt = now.addingTimeInterval(120)
        codex.windows.append(UsageWindow(id: "week", title: "Semana", used: 40, limit: 100,
                                        resetsAt: now.addingTimeInterval(7200)))
        var copilot = snapshot(.copilot, used: 10, updatedAt: now.addingTimeInterval(-30))
        copilot.windows[0].resetsAt = now.addingTimeInterval(120)
        var claude = snapshot(.claude, used: 90)
        claude.windows[0].resetsAt = now.addingTimeInterval(-1)
        let state = SummaryWidgetState(snapshots: [claude, copilot, codex], display: .used)

        XCTAssertEqual(state.transitionDates(after: now),
                       [120, 271, 301, 7200].map { now.addingTimeInterval($0) })
        XCTAssertEqual(state.transitionDates(after: now.addingTimeInterval(301)),
                       [now.addingTimeInterval(7200)])
        XCTAssertTrue(SummaryWidgetState(snapshots: [], display: .used).transitionDates(after: now).isEmpty)
    }

    func testAgeAndExpiredResetsMarkOriginalReadingStaleWithoutRefillingQuota() {
        var reading = snapshot(.codex, used: 84)
        reading.windows[0].resetsAt = now.addingTimeInterval(60)
        let state = SummaryWidgetState(snapshots: [reading], display: .remaining)
        let row = state.readings[0]
        XCTAssertFalse(row.isStale(at: now))
        XCTAssertTrue(row.isStale(at: now.addingTimeInterval(60)))
        XCTAssertEqual(value(row, in: state), .percent(16))
        XCTAssertEqual(row.updatedAt, now)

        let ageOnly = SummaryWidgetState(snapshots: [snapshot(.claude, used: 20)], display: .remaining).readings[2]
        XCTAssertFalse(ageOnly.isStale(at: now.addingTimeInterval(300)))
        XCTAssertTrue(ageOnly.isStale(at: now.addingTimeInterval(301)))
        XCTAssertTrue(ageOnly.isStale(at: now.addingTimeInterval(-1)))
        let empty = UsageSnapshot(provider: .copilot, windows: [], updatedAt: now, source: "")
        XCTAssertTrue(SummaryWidgetState(snapshots: [empty], display: .used).readings[1].isStale(at: now))
    }

    private func value(_ reading: SummaryProviderReading, in state: SummaryWidgetState) -> SummaryQuotaValue {
        reading.value(for: reading.windows.first, display: state.display)
    }

    private func snapshot(_ provider: Provider, used: Double, updatedAt: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: provider, windows: [
            UsageWindow(id: "session", title: "Sesión", used: used, limit: 100)
        ], updatedAt: updatedAt ?? now, source: "")
    }
}
