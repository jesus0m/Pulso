import XCTest
@testable import Pulso

final class BackgroundRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testReadingTakenDuringTheRunCountsAsRefreshed() {
        let summary = BackgroundRefresh.summary(for: [(.codex, start.addingTimeInterval(2))], since: start)
        XCTAssertEqual(summary, "Codex ✓")
    }

    func testStaleCacheIsNeverReportedAsRefreshed() {
        let summary = BackgroundRefresh.summary(for: [
            (.codex, start.addingTimeInterval(-1)),
            (.claude, nil)
        ], since: start)
        XCTAssertEqual(summary, "Codex ✗ · Claude ✗")
    }

    func testMixedOutcomesKeepProviderOrderAndSeparator() {
        let summary = BackgroundRefresh.summary(for: [
            (.codex, start),
            (.copilot, start.addingTimeInterval(-600)),
            (.claude, start.addingTimeInterval(5))
        ], since: start)
        XCTAssertEqual(summary, "Codex ✓ · GitHub Copilot ✗ · Claude ✓")
    }

    func testNoConnectedProvidersIsDistinctFromFailure() {
        XCTAssertEqual(BackgroundRefresh.summary(for: [], since: start), "Sin proveedores conectados")
    }

    @MainActor
    func testRunFetchesQuotaAndRecordsItForTheConnectionsScreen() async {
        let suite = "background.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("monalisa", forKey: "githubUsername")
        // Personal plan keeps the fetch on the injected dependency instead of the live endpoint.
        defaults.set(false, forKey: "githubOrganizationPlan")
        var reloadedWidgets = 0
        let store = UsageStore(dependencies: makeDependencies(reloaded: { reloadedWidgets += 1 }),
                               defaults: defaults, demo: false)

        let outcome = await BackgroundRefresh.performRefresh(store: store, defaults: defaults, start: start)

        XCTAssertEqual(outcome, "GitHub Copilot ✓")
        XCTAssertEqual(defaults.object(forKey: "backgroundLastRun") as? Date, start)
        XCTAssertEqual(defaults.string(forKey: "backgroundLastOutcome"), "GitHub Copilot ✓")
        XCTAssertEqual(defaults.integer(forKey: "backgroundRunCount"), 1)
        XCTAssertEqual(reloadedWidgets, 1, "El widget solo cambia si se recarga su timeline")
    }

    @MainActor
    func testRepeatedRunsAccumulateSoWakeFrequencyIsMeasurable() async {
        let suite = "background.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        defaults.set("monalisa", forKey: "githubUsername")
        // Personal plan keeps the fetch on the injected dependency instead of the live endpoint.
        defaults.set(false, forKey: "githubOrganizationPlan")
        let store = UsageStore(dependencies: makeDependencies(reloaded: {}), defaults: defaults, demo: false)

        await BackgroundRefresh.performRefresh(store: store, defaults: defaults, start: start)
        await BackgroundRefresh.performRefresh(store: store, defaults: defaults, start: start.addingTimeInterval(900))

        XCTAssertEqual(defaults.integer(forKey: "backgroundRunCount"), 2)
        XCTAssertEqual(defaults.object(forKey: "backgroundLastRun") as? Date, start.addingTimeInterval(900))
    }

    @MainActor
    private func makeDependencies(reloaded: @escaping () -> Void) -> UsageStore.Dependencies {
        UsageStore.Dependencies(
            loadSnapshots: { [] }, saveSnapshots: { _ in }, readToken: { "token" },
            saveToken: { _ in }, deleteToken: {},
            fetchGitHub: { _, _, _, _ in
                UsageSnapshot(provider: .copilot,
                              windows: [UsageWindow(id: "w", title: "Mes", used: 10, limit: 100, resetsAt: nil)],
                              updatedAt: Date(), source: "test")
            },
            reloadWidgets: reloaded)
    }
}
