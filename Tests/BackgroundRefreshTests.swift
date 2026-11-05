import XCTest
@testable import Pulso

final class BackgroundRefreshTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    @MainActor
    func testAcceptedSchedulingRecordsRequestAndClearsPreviousFailure() {
        let fixture = BackgroundFixture()
        fixture.defaults.set("Previous failure", forKey: "backgroundSchedulingError")
        BackgroundRefresh.schedule(defaults: fixture.defaults, now: start) { request in
            XCTAssertEqual(request.identifier, "com.jesusom.pulso.refresh")
            XCTAssertEqual(request.earliestBeginDate, start.addingTimeInterval(120))
        }
        XCTAssertEqual(fixture.defaults.object(forKey: "backgroundLastRequest") as? Date, start)
        XCTAssertEqual(fixture.defaults.object(forKey: "backgroundRequestedAfter") as? Date,
                       start.addingTimeInterval(120))
        XCTAssertNil(fixture.defaults.string(forKey: "backgroundSchedulingError"))
        XCTAssertNil(fixture.defaults.object(forKey: "backgroundLastRun"),
                     "An accepted request is not evidence that iOS ran the refresh")
    }

    @MainActor
    func testRejectedSchedulingRecordsSafeFailureWithoutClaimingAWake() {
        let fixture = BackgroundFixture()
        BackgroundRefresh.schedule(defaults: fixture.defaults, now: start) { _ in
            throw NSError(domain: "test.scheduler", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "private-fixture-detail"])
        }
        XCTAssertEqual(fixture.defaults.object(forKey: "backgroundLastRequest") as? Date, start)
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundSchedulingError"), "test.scheduler (3)")
        XCTAssertNil(fixture.defaults.object(forKey: "backgroundLastRun"))
        XCTAssertEqual(fixture.defaults.integer(forKey: "backgroundRunCount"), 0)
    }

    @MainActor
    func testAllFailuresReportFailureWithoutReplacingCache() async {
        let fixture = BackgroundFixture()
        fixture.fetch = { throw URLError(.notConnectedToInternet) }
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        await run.wait()
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundLastOutcome"), "GitHub Copilot ✗")
        XCTAssertTrue(fixture.saved.isEmpty)
    }

    @MainActor
    func testPartialSuccessCompletesSuccessfully() async {
        let fixture = BackgroundFixture()
        fixture.defaults.set(true, forKey: "codexEnabled")
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        await run.wait()
        XCTAssertEqual(completions, [true])
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundLastOutcome"), "Codex ✗ · GitHub Copilot ✓")
        run.expire()
        XCTAssertEqual(completions, [true])
    }

    @MainActor
    func testNoProvidersDoesNotReportSuccess() async {
        let fixture = BackgroundFixture()
        fixture.defaults.removeObject(forKey: "githubUsername")
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        await run.wait()
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundLastOutcome"), "Sin proveedores conectados")
    }

    @MainActor
    func testReturnedStaleReadingDoesNotCountAsSuccessfulRefresh() async {
        let fixture = BackgroundFixture()
        fixture.fetch = {
            var snapshot = fixture.snapshot()
            snapshot.updatedAt = Date(timeIntervalSince1970: 1)
            return snapshot
        }
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        await run.wait()
        XCTAssertEqual(completions, [false])
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundLastOutcome"), "GitHub Copilot ✗")
        XCTAssertEqual(store.snapshot(for: .copilot)?.updatedAt, Date(timeIntervalSince1970: 1))
    }

    @MainActor
    func testExpirationCompletesImmediatelyOnceAndRecordsWakeBeforeFetchFinishes() async {
        let fixture = BackgroundFixture()
        var pending: CheckedContinuation<UsageSnapshot, Error>?
        fixture.fetch = { try await withCheckedThrowingContinuation { pending = $0 } }
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        for _ in 0..<1000 {
            if pending != nil { break }
            await Task.yield()
        }
        XCTAssertNotNil(pending)
        XCTAssertEqual(fixture.defaults.integer(forKey: "backgroundRunCount"), 1)
        XCTAssertNotNil(fixture.defaults.object(forKey: "backgroundLastRun"))
        run.expire()
        run.expire()
        XCTAssertEqual(completions, [false], "Expiration must not await an uncooperative provider")
        await run.wait()
        XCTAssertFalse(store.refreshing)
        pending?.resume(returning: fixture.snapshot())
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(completions, [false])
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(fixture.defaults.string(forKey: "backgroundLastOutcome"), "Tiempo de ejecución agotado")
    }

    @MainActor
    func testLockedProviderIsIncludedInBackgroundDiagnostic() async {
        let fixture = BackgroundFixture()
        fixture.availability = .temporarilyUnavailable
        let store = fixture.store()
        let outcome = await BackgroundRefresh.performRefresh(store: store, defaults: fixture.defaults)
        XCTAssertEqual(outcome, "GitHub Copilot ✗")
        XCTAssertTrue(store.githubConfigured)
    }

    @MainActor
    func testExpiringBackgroundWaiterPreservesForegroundConsumer() async {
        let fixture = BackgroundFixture()
        var pending: CheckedContinuation<UsageSnapshot, Error>?
        fixture.fetch = { try await withCheckedThrowingContinuation { pending = $0 } }
        let store = fixture.store()
        var completions: [Bool] = []
        let run = BackgroundRefresh.start(store: store, defaults: fixture.defaults) { completions.append($0) }
        for _ in 0..<1000 {
            if pending != nil { break }
            await Task.yield()
        }
        var foregroundStarted = false
        let foreground = Task {
            foregroundStarted = true
            return await store.refresh()
        }
        for _ in 0..<1000 {
            if foregroundStarted { break }
            await Task.yield()
        }
        XCTAssertTrue(foregroundStarted)
        run.expire()
        XCTAssertEqual(completions, [false])
        XCTAssertTrue(store.refreshing)
        await run.wait()
        pending?.resume(returning: fixture.snapshot())
        let result = await foreground.value
        XCTAssertEqual(result.refreshed, [.copilot])
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 10)
        XCTAssertEqual(completions, [false])
    }

    func testReadingTakenDuringTheRunCountsAsRefreshed() {
        let summary = BackgroundRefresh.summary(for: [(.codex, start.addingTimeInterval(2))], since: start)
        XCTAssertEqual(summary, "Codex ✓")
    }

    @MainActor
    private final class BackgroundFixture {
        let suite = "background.lifecycle.\(UUID().uuidString)"
        let defaults: UserDefaults
        var saved: [[UsageSnapshot]] = []
        var availability = TokenVault.Availability.available("fixture-token")
        var fetch: (() async throws -> UsageSnapshot)?

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set("fixture", forKey: "githubUsername")
            defaults.set(false, forKey: "githubOrganizationPlan")
        }

        deinit { defaults.removePersistentDomain(forName: suite) }

        func snapshot() -> UsageSnapshot {
            UsageSnapshot(provider: .copilot,
                          windows: [UsageWindow(id: "month", title: "Mes", used: 10, limit: 100, resetsAt: nil)],
                          updatedAt: Date(), source: "Fixture")
        }

        func store() -> UsageStore {
            UsageStore(dependencies: .init(
                loadSnapshots: { [] }, saveSnapshots: { [self] in saved.append($0) },
                readToken: { "fixture-token" }, saveToken: { _ in }, deleteToken: {},
                fetchGitHub: { [self] _, _, _, _ in
                    if let fetch { return try await fetch() }
                    return snapshot()
                }, reloadWidgets: {}, fetchCodex: { throw CodexAuthError.signIn },
                scheduleResetAlerts: { _, _ in }, requestNotifications: { false },
                tokenAvailability: { [self] in availability }
            ), defaults: defaults, demo: false)
        }
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
