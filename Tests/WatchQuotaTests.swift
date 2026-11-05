import XCTest
import WatchConnectivity
@testable import Pulso

final class WatchQuotaTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor
    func testAppRegistersAndRetainsPhoneConnectivityDelegate() throws {
        guard WCSession.isSupported() else { throw XCTSkip("WatchConnectivity is unavailable") }
        XCTAssertTrue(WCSession.default.delegate === PhoneWatchSync.shared)
    }

    func testContextTransfersIndependentBalancesButNotSourceOrHiddenProviders() throws {
        let state = WatchQuotaState(snapshots: [
            snapshot(provider: .copilot), snapshot(provider: .codex)
        ], visibleProviders: [.copilot], quotaDisplay: .remaining, sentAt: now)

        let context = try state.context()
        let decoded = try XCTUnwrap(WatchQuotaState(context: context))
        let window = try XCTUnwrap(decoded.snapshot(for: .copilot)?.windows.first)
        XCTAssertEqual(window.used, 6134)
        XCTAssertEqual(window.limit, 60000)
        XCTAssertEqual(window.remaining, 53774)
        XCTAssertEqual(window.reportedRemainingPercent, 89.6)
        XCTAssertEqual(window.displayedPercent(decoded.quotaDisplay), 90)
        XCTAssertEqual(decoded.snapshots.map(\.provider), [.copilot])
        XCTAssertEqual(decoded.snapshots.first?.source, "")
        let encoded = try XCTUnwrap(context[WatchQuotaState.contextKey] as? Data)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("private-source-metadata"))
    }

    func testUsedPreferenceAppliesToWeeklyWindowsAndUnknownQuotaStaysUnknown() throws {
        let reading = UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "session", title: "Sesión", used: 28, limit: 100),
            UsageWindow(id: "week", title: "Semana", used: 46, limit: 100),
            UsageWindow(id: "unknown", title: "Sin límite", used: 12, limit: nil)
        ], updatedAt: now, source: "")
        let state = WatchQuotaState(snapshots: [reading], visibleProviders: [.codex],
                                   quotaDisplay: .used, sentAt: now)
        let decoded = try XCTUnwrap(WatchQuotaState(context: state.context()))
        XCTAssertEqual(decoded.snapshots[0].windows.map { $0.displayedPercent(decoded.quotaDisplay) }, [28, 46, nil])
        XCTAssertEqual(decoded.snapshots[0].windows.map { $0.complementPercent(decoded.quotaDisplay) }, [72, 54, nil])
    }

    func testOfflineCacheRetainsNewerStateAndLogoutCannotBeUndoneByDelayedReply() throws {
        let suite = "com.jesusom.pulso.watch.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = WatchQuotaCache(defaults: defaults)
        let initial = WatchQuotaState(snapshots: [snapshot()], visibleProviders: [.copilot],
                                     quotaDisplay: .remaining, sentAt: now)
        XCTAssertTrue(cache.save(initial))
        XCTAssertEqual(WatchQuotaCache(defaults: defaults).load(), initial)

        let disconnected = WatchQuotaState(snapshots: [], visibleProviders: [.copilot],
                                          quotaDisplay: .used, sentAt: now.addingTimeInterval(1))
        XCTAssertTrue(cache.save(disconnected))
        XCTAssertFalse(cache.save(initial))
        XCTAssertEqual(cache.load(), disconnected)
        XCTAssertNil(cache.load()?.snapshot(for: .copilot))
    }

    func testStalenessReflectsReadingAgeFailedFetchAndExpiredReset() {
        let fresh = WatchQuotaState(snapshots: [snapshot()], visibleProviders: [.copilot], quotaDisplay: .remaining)
        XCTAssertFalse(fresh.isStale(.copilot, now: now))
        XCTAssertTrue(fresh.isStale(.copilot, now: now.addingTimeInterval(301)))
        XCTAssertTrue(fresh.isStale(.codex, now: now))

        let failed = WatchQuotaState(snapshots: [snapshot()], visibleProviders: [.copilot],
                                    quotaDisplay: .remaining, failedProviders: [.copilot])
        XCTAssertTrue(failed.isStale(.copilot, now: now))
        var expiredReading = snapshot()
        expiredReading.windows[0].resetsAt = now
        let expired = WatchQuotaState(snapshots: [expiredReading], visibleProviders: [.copilot], quotaDisplay: .remaining)
        XCTAssertTrue(expired.isStale(.copilot, now: now))
        XCTAssertEqual(expired.snapshot(for: .copilot)?.windows.first?.remaining, 53774)
    }

    func testMalformedAndFutureVersionContextsAreIgnored() throws {
        XCTAssertNil(WatchQuotaState(context: [:]))
        XCTAssertNil(WatchQuotaState(context: [WatchQuotaState.contextKey: Data("invalid".utf8)]))
        let state = WatchQuotaState(snapshots: [snapshot()], visibleProviders: [.copilot], quotaDisplay: .remaining)
        let data = try JSONEncoder().encode(state)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["version"] = 2
        XCTAssertNil(WatchQuotaState(context: [
            WatchQuotaState.contextKey: try JSONSerialization.data(withJSONObject: object)
        ]))
    }

    func testWidgetTimelineIncludesEachWindowResetAndStalenessWithoutDuplicates() {
        var reading = snapshot()
        reading.windows += [
            UsageWindow(id: "week", title: "Semana", used: 20, limit: 100,
                        resetsAt: now.addingTimeInterval(7200)),
            UsageWindow(id: "duplicate", title: "Otra ventana", used: 30, limit: 100,
                        resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(id: "expired", title: "Pendiente", used: 50, limit: 100,
                        resetsAt: now.addingTimeInterval(-1))
        ]
        XCTAssertEqual(QuotaTimeline.transitionDates(for: reading, after: now),
                       [301, 3600, 7200].map { now.addingTimeInterval($0) })
        XCTAssertEqual(QuotaTimeline.transitionDates(for: reading, after: now.addingTimeInterval(4000)),
                       [now.addingTimeInterval(7200)])
        XCTAssertTrue(QuotaTimeline.transitionDates(for: nil, after: now).isEmpty)
    }

    private func snapshot(provider: Provider = .copilot) -> UsageSnapshot {
        UsageSnapshot(provider: provider, windows: [
            UsageWindow(id: "copilot_credits", title: "Mes", used: 6134, limit: 60000,
                        resetsAt: now.addingTimeInterval(3600), remaining: 53774, reportedRemainingPercent: 89.6)
        ], updatedAt: now, source: "private-source-metadata")
    }
}
