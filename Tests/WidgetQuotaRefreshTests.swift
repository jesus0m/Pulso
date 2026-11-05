import XCTest
@testable import Pulso

final class WidgetQuotaRefreshTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)

    func testOAuthMutexSerializesIndependentRefreshConsumers() async throws {
        let tracker = RefreshTracker()
        let first = Task {
            try await SharedQuotaAccess.withOAuthLock {
                await tracker.enter()
                try await Task.sleep(for: .milliseconds(50))
                await tracker.leave()
            }
        }
        let second = Task {
            try await SharedQuotaAccess.withOAuthLock {
                await tracker.enter()
                try await Task.sleep(for: .milliseconds(50))
                await tracker.leave()
            }
        }
        try await first.value
        try await second.value
        let maximum = await tracker.maximum
        XCTAssertEqual(maximum, 1, "Rotating refresh tokens must have only one owner at a time")
    }

    func testSuccessfulRefreshMergesIndependentProvidersAndPreservesClaude() async {
        let configuration = configuration()
        var cache = [snapshot(.claude, at: now.addingTimeInterval(-600))]
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache }, reserve: { _, _, _, _ in true },
            fetch: { [self] provider, _ in snapshot(provider, at: now) },
            commit: { snapshot, _ in cache.append(snapshot); return true }, now: { self.now }))
        let result = await refresher.refresh()
        XCTAssertEqual(Set(result.map(\.provider)), [.codex, .copilot, .claude])
        XCTAssertEqual(result.first { $0.provider == .claude }?.updatedAt, now.addingTimeInterval(-600))
    }

    func testFailureKeepsOriginalReadingAndTimestamp() async {
        let configuration = configuration()
        let cache = [snapshot(.codex, at: now.addingTimeInterval(-600))]
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache }, reserve: { _, _, _, _ in true },
            fetch: { _, _ in throw URLError(.notConnectedToInternet) },
            commit: { _, _ in XCTFail("Failed networking must not overwrite cache"); return false }, now: { self.now }))
        let result = await refresher.refresh()
        XCTAssertEqual(result, cache)
    }

    func testFreshCacheDoesNotIssueRequests() async {
        let defaults = UserDefaults(suiteName: SnapshotCache.suite)!
        let executionKey = "widgetQuotaExecution.summary"
        let decisionKey = "widgetQuotaDecision.codex"
        let previousExecution = defaults.object(forKey: executionKey)
        let previousDecision = defaults.object(forKey: decisionKey)
        defer {
            defaults.set(previousExecution, forKey: executionKey)
            defaults.set(previousDecision, forKey: decisionKey)
        }
        defaults.removeObject(forKey: executionKey)
        defaults.removeObject(forKey: decisionKey)
        let configuration = configuration()
        let cache = [snapshot(.codex, at: now), snapshot(.copilot, at: now)]
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache },
            reserve: { _, _, _, _ in XCTFail("Fresh data must not consume a request"); return false },
            fetch: { _, _ in throw URLError(.badURL) }, commit: { _, _ in false }, now: { self.now }))
        let result = await refresher.refresh()
        XCTAssertEqual(result, cache)
        XCTAssertNotNil(defaults.dictionary(forKey: executionKey)?["finishedAt"] as? Date,
                        "A cache-only evaluation must remain distinguishable from iOS never invoking the provider")
        XCTAssertEqual(defaults.dictionary(forKey: decisionKey)?["reason"] as? String, "Lectura reciente")
    }

    func testMissingConfigurationStillRecordsWidgetExecution() async {
        let defaults = UserDefaults(suiteName: SnapshotCache.suite)!
        let key = "widgetQuotaExecution.codex"
        let previous = defaults.object(forKey: key)
        defer { defaults.set(previous, forKey: key) }
        defaults.removeObject(forKey: key)
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { nil }, snapshots: { [] },
            reserve: { _, _, _, _ in XCTFail("No configuration must not reserve networking"); return false },
            fetch: { _, _ in throw URLError(.badURL) }, commit: { _, _ in false }))
        _ = await refresher.refresh(providers: [.codex])
        let execution = defaults.dictionary(forKey: key)
        XCTAssertNotNil(execution?["startedAt"] as? Date)
        XCTAssertNotNil(execution?["finishedAt"] as? Date)
        XCTAssertNil(execution?["networkSuccess"], "Executing the provider is not evidence that quota networking succeeded")
    }

    func testClaudeWithoutSharedOrganizationNeverFetchesAnotherProvider() async {
        let configuration = configuration()
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { [] },
            reserve: { _, _, _, _ in XCTFail("Claude requires a shared authenticated organization"); return false },
            fetch: { _, _ in throw URLError(.badURL) }, commit: { _, _ in false }, now: { self.now }))
        let result = await refresher.refresh(providers: [.claude])
        XCTAssertTrue(result.isEmpty)
    }

    func testClaudeTimelineFetchesOnlyClaudeAndSummaryIncludesAllConfiguredProviders() async {
        var configuration = configuration()
        configuration.claudeOrganizationID = "01531D14-44AB-4DBB-9D96-02CFD19C7712"
        var cache: [UsageSnapshot] = []
        var fetched: [Provider] = []
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache }, reserve: { _, _, _, _ in true },
            fetch: { [self] provider, _ in snapshot(provider, at: now) },
            commit: { snapshot, _ in fetched.append(snapshot.provider); cache.append(snapshot); return true },
            now: { self.now }))
        _ = await refresher.refresh(providers: [.claude])
        XCTAssertEqual(fetched, [.claude])
        cache = []
        fetched = []
        _ = await refresher.refresh()
        XCTAssertEqual(Set(fetched), Set(Provider.allCases))
    }

    func testClaudeChallengeKeepsLastReadingAndRecordsFailure() async {
        var configuration = configuration()
        configuration.claudeOrganizationID = "01531D14-44AB-4DBB-9D96-02CFD19C7712"
        let cache = [snapshot(.claude, at: now.addingTimeInterval(-600))]
        var failure: ClaudeQuotaError?
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache }, reserve: { _, _, _, _ in true },
            fetch: { _, _ in throw ClaudeQuotaError.cloudflare },
            commit: { _, _ in XCTFail("Challenge must not overwrite cache"); return false },
            now: { self.now }, recordFailure: { provider, _, error in
                XCTAssertEqual(provider, .claude)
                failure = error as? ClaudeQuotaError
            }))
        let result = await refresher.refresh(providers: [.claude])
        XCTAssertEqual(result, cache)
        XCTAssertEqual(failure, .cloudflare)
    }

    func testClaudeLogoutFencesPendingWidgetResponse() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SnapshotCache.suite))
        let previous = defaults.data(forKey: "widgetQuotaConfiguration")
        let snapshots = SnapshotCache.load()
        defer {
            defaults.set(previous, forKey: "widgetQuotaConfiguration")
            defaults.synchronize()
            SnapshotCache.save(snapshots)
        }
        var configuration = configuration()
        configuration.claudeOrganizationID = "01531D14-44AB-4DBB-9D96-02CFD19C7712"
        WidgetQuotaConfiguration.save(configuration)
        let active = try XCTUnwrap(WidgetQuotaConfiguration.load())
        WidgetQuotaConfiguration.invalidate(.claude)
        XCTAssertNil(WidgetQuotaConfiguration.load()?.claudeOrganizationID)
        XCTAssertFalse(WidgetQuotaConfiguration.commit(snapshot(.claude, at: now), configuration: active))
    }

    func testWrongProviderAndOldResponseCannotOverwriteCache() async {
        let configuration = configuration()
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { [] }, reserve: { _, _, _, _ in true },
            fetch: { [self] _, _ in snapshot(.claude, at: now.addingTimeInterval(-1)) },
            commit: { _, _ in XCTFail("Invalid response must be discarded"); return false }, now: { self.now }))
        let result = await refresher.refresh()
        XCTAssertTrue(result.isEmpty)
    }

    func testLogoutRejectsLateWidgetResultAndCacheMergeDoesNotRollBackNewerReading() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SnapshotCache.suite))
        let previousConfig = defaults.data(forKey: "widgetQuotaConfiguration")
        let previousSnapshots = SnapshotCache.load()
        defer {
            defaults.set(previousConfig, forKey: "widgetQuotaConfiguration")
            defaults.synchronize()
            SnapshotCache.save(previousSnapshots)
        }
        let configuration = configuration()
        WidgetQuotaConfiguration.save(configuration)
        let active = try XCTUnwrap(WidgetQuotaConfiguration.load())
        SnapshotCache.save([])
        SnapshotCache.merge(snapshot(.codex, at: now))
        SnapshotCache.merge(snapshot(.codex, at: now.addingTimeInterval(-600)))
        XCTAssertEqual(SnapshotCache.load().first?.updatedAt, now)
        WidgetQuotaConfiguration.invalidate(.codex)
        XCTAssertFalse(WidgetQuotaConfiguration.commit(snapshot(.codex, at: now), configuration: active))
        XCTAssertFalse(SnapshotCache.load().contains { $0.provider == .codex })
    }

    func testManualRefreshUpdatesFreshCacheForOnlyTheRequestedProvider() async {
        let configuration = configuration()
        var cache = [snapshot(.codex, at: now.addingTimeInterval(-30)), snapshot(.copilot, at: now)]
        var reloads = 0
        let refresher = WidgetQuotaRefresh(dependencies: .init(
            configuration: { configuration }, snapshots: { cache },
            reserve: { provider, _, _, userInitiated in
                XCTAssertEqual(provider, .codex)
                return userInitiated
            },
            fetch: { [self] provider, _ in snapshot(provider, at: now) },
            commit: { reading, _ in
                cache.removeAll { $0.provider == reading.provider }
                cache.append(reading)
                return true
            }, now: { self.now }, reloadWidgets: { reloads += 1 }))
        let result = await refresher.refresh(providers: [.codex], userInitiated: true)
        XCTAssertEqual(result.first { $0.provider == .codex }?.updatedAt, now)
        XCTAssertEqual(result.first { $0.provider == .copilot }?.updatedAt, now)
        XCTAssertEqual(reloads, 1)
    }

    func testManualRefreshReservationAllowsRetryButPreventsRepeatedAndOverlappingRequests() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SnapshotCache.suite))
        let keys = ["widgetQuotaConfiguration", "widgetQuotaAttempt.codex"]
        let previous = keys.map { defaults.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, previous) { defaults.set(value, forKey: key) }
            defaults.synchronize()
        }
        defaults.removeObject(forKey: keys[0])
        defaults.removeObject(forKey: keys[1])
        let configuration = configuration()
        WidgetQuotaConfiguration.save(configuration)
        XCTAssertTrue(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration, now: now))
        XCTAssertFalse(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                       now: now.addingTimeInterval(30), userInitiated: true))
        WidgetQuotaConfiguration.recordFailure(.codex, configuration: configuration,
                                               error: URLError(.notConnectedToInternet))
        XCTAssertFalse(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                       now: now.addingTimeInterval(5), userInitiated: true))
        XCTAssertFalse(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                       now: now.addingTimeInterval(30)))
        XCTAssertTrue(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                      now: now.addingTimeInterval(30), userInitiated: true))
        WidgetQuotaConfiguration.recordFailure(.codex, configuration: configuration,
                                               error: URLError(.notConnectedToInternet))
        XCTAssertFalse(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                       now: now.addingTimeInterval(31), userInitiated: true))
        XCTAssertTrue(WidgetQuotaConfiguration.reserve(.codex, configuration: configuration,
                                                      now: now.addingTimeInterval(151)))
    }

    private func configuration() -> WidgetQuotaConfiguration {
        WidgetQuotaConfiguration(codexEnabled: true, username: "fixture",
                                 allowance: 100, legacy: false, organizationPlan: true)
    }

    private func snapshot(_ provider: Provider, at date: Date) -> UsageSnapshot {
        UsageSnapshot(provider: provider,
                      windows: [UsageWindow(id: "fixture", title: "Quota", used: 10, limit: 100, resetsAt: nil)],
                      updatedAt: date, source: "Fixture")
    }

    private actor RefreshTracker {
        var maximum = 0
        private var active = 0
        func enter() {
            active += 1
            maximum = max(maximum, active)
        }
        func leave() { active -= 1 }
    }
}
