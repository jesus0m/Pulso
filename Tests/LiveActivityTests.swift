import XCTest
import UIKit
@testable import Pulso

@MainActor
final class LiveActivityTests: XCTestCase {
    func testProviderLogosAreAvailableInsideLiveActivityExtension() throws {
        let plugins = try XCTUnwrap(Bundle.main.builtInPlugInsURL)
        let widgets = try XCTUnwrap(Bundle(url: plugins.appendingPathComponent("PulsoWidgets.appex")))
        for provider in [Provider.claude, .copilot] {
            let asset = try XCTUnwrap(provider.logoAsset)
            XCTAssertNotNil(UIImage(named: asset, in: widgets, compatibleWith: nil),
                            "\(provider.title)'s in-app logo must also ship in the Live Activity extension")
        }
    }

    func testPayloadPreservesIndependentlyReportedQuotaValues() throws {
        let fixture = ActivityFixture()
        var snapshot = fixture.snapshot()
        snapshot.windows = [
            UsageWindow(id: "copilot_credits", title: "Private account label", used: 6134, limit: 60000,
                        resetsAt: fixture.date.addingTimeInterval(60), remaining: 53774,
                        reportedRemainingPercent: 89.6)
        ]
        let state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        let primary = try XCTUnwrap(state.primary)
        XCTAssertEqual(primary.usedPercent, 10)
        XCTAssertEqual(primary.remainingPercent, 90)
        XCTAssertEqual(primary.remaining, 53774)
        XCTAssertEqual(primary.used, 6134)
        XCTAssertEqual(primary.kind, .credits)
        XCTAssertFalse(state.showsUsed)
    }

    func testUnknownLimitsDoNotBecomeInventedPercentagesOrBalances() throws {
        let fixture = ActivityFixture()
        var snapshot = fixture.snapshot()
        snapshot.windows = [UsageWindow(id: "ai_credits", title: "Credits", used: 39, limit: nil, resetsAt: nil)]
        let state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .used))
        let primary = try XCTUnwrap(state.primary)
        XCTAssertTrue(state.showsUsed)
        XCTAssertNil(primary.usedPercent)
        XCTAssertNil(primary.remainingPercent)
        XCTAssertNil(primary.remaining)
        XCTAssertNil(primary.limit)
        XCTAssertEqual(primary.used, 39)
    }

    func testPayloadSanitizesUntrustedStringsAndNonFiniteAmounts() throws {
        let fixture = ActivityFixture()
        var snapshot = fixture.snapshot()
        snapshot.source = "secret-token@example.com"
        snapshot.windows = [
            UsageWindow(id: "secret-id", title: "private-account@example.com", used: .nan, limit: .infinity,
                        resetsAt: nil, remaining: -.infinity, reportedRemainingPercent: .nan)
        ]
        let state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        let data = try JSONEncoder().encode(state)
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.contains("secret"))
        XCTAssertFalse(encoded.contains("private-account"))
        XCTAssertEqual(state.primary?.kind, .quota)
        XCTAssertNil(state.primary?.used)
        XCTAssertNil(state.primary?.remaining)
        XCTAssertEqual(try JSONDecoder().decode(QuotaActivityAttributes.ContentState.self, from: data), state)
    }

    func testAllProviderWindowsSurviveRoundTripWithinActivityBudget() throws {
        let fixture = ActivityFixture()
        var snapshot = fixture.snapshot(provider: .claude)
        snapshot.windows = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"].enumerated().map {
            UsageWindow(id: $0.element, title: "Not copied", used: Double($0.offset * 10), limit: 100,
                        resetsAt: fixture.date.addingTimeInterval(Double(($0.offset + 1) * 3600)))
        }
        let state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        XCTAssertEqual(state.windows.map(\.kind), [.session, .week, .opus, .sonnet])
        XCTAssertEqual(state.windows.map(\.remainingPercent), [100, 90, 80, 70])
        let data = try JSONEncoder().encode(state)
        XCTAssertLessThan(data.count, 3500)
        XCTAssertEqual(try JSONDecoder().decode(QuotaActivityAttributes.ContentState.self, from: data), state)
    }

    func testStalenessUsesReadingAgeAndEarliestResetNotUpdateTime() throws {
        let fixture = ActivityFixture()
        var snapshot = fixture.snapshot()
        snapshot.updatedAt = fixture.date.addingTimeInterval(-240)
        var state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        XCTAssertEqual(state.staleDate(now: fixture.date), fixture.date.addingTimeInterval(60))
        snapshot.windows[0].resetsAt = fixture.date.addingTimeInterval(20)
        state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        XCTAssertEqual(state.staleDate(now: fixture.date), fixture.date.addingTimeInterval(20))
        state.refreshFailed = true
        XCTAssertEqual(state.staleDate(now: fixture.date), fixture.date)
        snapshot.windows[0].resetsAt = fixture.date.addingTimeInterval(-10)
        state = try XCTUnwrap(QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: .remaining))
        XCTAssertLessThan(state.staleDate(now: fixture.date), fixture.date)
    }

    func testStartRequiresOptInAuthorizationRealDataAndNonDemoMode() {
        let fixture = ActivityFixture()
        let controller = fixture.controller()
        fixture.start(controller)
        XCTAssertEqual(fixture.requests, 0)
        controller.setEnabled(true)
        fixture.authorized = false
        fixture.start(controller)
        XCTAssertNotNil(controller.message)
        fixture.authorized = true
        controller.start(snapshot: fixture.snapshot(), configured: true, demo: true, display: .remaining)
        XCTAssertNotNil(controller.message)
        controller.start(snapshot: nil, configured: true, demo: false, display: .remaining)
        XCTAssertNotNil(controller.message)
        XCTAssertEqual(fixture.requests, 0)
        fixture.start(controller)
        XCTAssertTrue(controller.isRunning)
        XCTAssertNil(controller.message)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testRequestFailureDoesNotClaimActivityIsRunning() {
        let fixture = ActivityFixture()
        fixture.requestError = UsageError.invalidResponse
        let controller = fixture.controller()
        controller.setEnabled(true)
        fixture.start(controller)
        XCTAssertFalse(controller.isRunning)
        XCTAssertNil(fixture.defaults.string(forKey: "liveActivityID"))
        XCTAssertNotNil(controller.message)
    }

    func testDismissalAndRelaunchNeverAutomaticallyResurrectActivity() {
        let fixture = ActivityFixture()
        let controller = fixture.controller()
        controller.setEnabled(true)
        fixture.start(controller)
        fixture.sessions.removeAll()
        fixture.reconcile(controller)
        XCTAssertFalse(controller.isRunning)
        XCTAssertTrue(controller.enabled)
        XCTAssertEqual(fixture.requests, 1)
        let restored = fixture.controller()
        fixture.reconcile(restored)
        XCTAssertTrue(restored.enabled)
        XCTAssertFalse(restored.isRunning)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testProviderChangeTerminatesOldSessionAndRequiresExplicitRestart() async {
        let fixture = ActivityFixture()
        let controller = fixture.controller()
        controller.setEnabled(true)
        fixture.start(controller)
        fixture.reconcile(controller)
        controller.selectProvider(.claude)
        await fixture.waitUntil { !fixture.ended.isEmpty }
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(fixture.ended, ["activity-1"])
        XCTAssertTrue(fixture.updates.isEmpty, "Queued old-provider update must be invalidated")
        let restored = fixture.controller()
        XCTAssertEqual(restored.provider, .claude)
        fixture.reconcile(restored, provider: .claude)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testRestoredActiveSessionUpdatesWithoutStartingAnotherAndExpires() async throws {
        let fixture = ActivityFixture()
        let original = fixture.controller()
        original.setEnabled(true)
        fixture.start(original)
        let restored = fixture.controller()
        fixture.reconcile(restored)
        await fixture.waitUntil { fixture.updates.count == 1 }
        XCTAssertTrue(restored.isRunning)
        XCTAssertEqual(fixture.requests, 1)
        fixture.date = fixture.date.addingTimeInterval(8 * 3600)
        fixture.reconcile(restored)
        await fixture.waitUntil { fixture.ended.count == 1 }
        XCTAssertFalse(restored.isRunning)
        XCTAssertNotNil(restored.message)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testTransientFailureKeepsTimestampAndMarksLastReadingImmediatelyStale() async throws {
        let fixture = ActivityFixture()
        let controller = fixture.controller()
        controller.setEnabled(true)
        fixture.start(controller)
        let readingDate = fixture.date
        fixture.date = fixture.date.addingTimeInterval(40)
        controller.reconcile(snapshot: fixture.snapshot(at: readingDate), configured: true, demo: false,
                             display: .used, refreshFailed: true)
        await fixture.waitUntil { fixture.updates.count == 1 }
        let update = try XCTUnwrap(fixture.updates.first)
        XCTAssertEqual(update.state.updatedAt, readingDate)
        XCTAssertTrue(update.state.refreshFailed)
        XCTAssertTrue(update.state.showsUsed)
        XCTAssertEqual(update.staleDate, fixture.date)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(fixture.requests, 1)
    }

    func testOptOutDuringSuspendedUpdateEndsAfterUpdateWithoutResurrection() async {
        let fixture = ActivityFixture()
        let controller = fixture.controller()
        controller.setEnabled(true)
        fixture.start(controller)
        fixture.suspendUpdate = true
        fixture.reconcile(controller)
        await fixture.waitUntil { fixture.updateContinuation != nil }
        controller.setEnabled(false)
        fixture.reconcile(controller)
        XCTAssertFalse(controller.isRunning)
        fixture.updateContinuation?.resume()
        fixture.updateContinuation = nil
        await fixture.waitUntil { !fixture.ended.isEmpty }
        XCTAssertFalse(controller.enabled)
        XCTAssertFalse(controller.isRunning)
        XCTAssertEqual(fixture.requests, 1)
        XCTAssertFalse(fixture.defaults.bool(forKey: "liveActivityEnabled"))
    }

    func testDisconnectedAndAuthoritativelyUnavailableDataEndSessions() async {
        for unavailable in [false, true] {
            let fixture = ActivityFixture()
            let controller = fixture.controller()
            controller.setEnabled(true)
            fixture.start(controller)
            controller.reconcile(snapshot: fixture.snapshot(), configured: unavailable, demo: false,
                                 display: .remaining, unavailable: unavailable)
            await fixture.waitUntil { fixture.ended.count == 1 }
            XCTAssertFalse(controller.isRunning)
            XCTAssertEqual(fixture.requests, 1)
        }
    }

    func testUsageStoreDemoAndRefreshFailuresUseOnlyRealReadings() async throws {
        let fixture = ActivityFixture()
        fixture.defaults.set(true, forKey: "codexEnabled")
        var failure: Error? = URLError(.notConnectedToInternet)
        let dependencies = UsageStore.Dependencies(
            loadSnapshots: { [fixture.snapshot()] }, saveSnapshots: { _ in },
            readToken: { nil }, saveToken: { _ in }, deleteToken: {},
            fetchGitHub: { _, _, _, _ in throw UsageError.noUsageData }, reloadWidgets: {},
            fetchCodex: {
                if let failure { throw failure }
                return fixture.snapshot()
            },
            scheduleResetAlerts: { _, _ in }, requestNotifications: { false }
        )
        let controller = fixture.controller()
        let store = UsageStore(dependencies: dependencies, defaults: fixture.defaults, demo: false,
                               liveActivity: controller)
        controller.setEnabled(true)
        store.startLiveActivity()
        await store.refresh()
        await fixture.waitUntil { !fixture.updates.isEmpty }
        XCTAssertTrue(controller.isRunning)
        XCTAssertTrue(try XCTUnwrap(fixture.updates.last).state.refreshFailed)
        failure = UsageError.unsupportedSchema
        await store.refresh()
        await fixture.waitUntil { !fixture.ended.isEmpty }
        XCTAssertFalse(controller.isRunning)
        store.startLiveActivity()
        XCTAssertEqual(fixture.requests, 1, "An old cached reading must not bypass an authoritative failure")
        failure = nil
        await store.refresh()
        store.startLiveActivity()
        XCTAssertEqual(fixture.requests, 2)
        store.demo = true
        await fixture.waitUntil { fixture.ended.count == 2 }
        XCTAssertFalse(controller.isRunning)
        store.startLiveActivity()
        XCTAssertEqual(fixture.requests, 2)
        XCTAssertEqual(fixture.requestedStates.map(\.updatedAt), [fixture.date, fixture.date])
    }
}

@MainActor
private final class ActivityFixture {
    struct Update {
        let state: QuotaActivityAttributes.ContentState
        let staleDate: Date
    }

    let suite = "com.jesusom.pulso.liveactivity.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var date = Date(timeIntervalSince1970: 1_800_000_000)
    var authorized = true
    var requestError: Error?
    var requests = 0
    var sessions: [LiveActivityController.Session] = []
    var requestedStates: [QuotaActivityAttributes.ContentState] = []
    var updates: [Update] = []
    var ended: [String] = []
    var suspendUpdate = false
    var updateContinuation: CheckedContinuation<Void, Never>?

    init() { defaults = UserDefaults(suiteName: suite)! }
    deinit { defaults.removePersistentDomain(forName: suite) }

    func snapshot(provider: Provider = .codex, at date: Date? = nil) -> UsageSnapshot {
        UsageSnapshot(provider: provider,
                      windows: [UsageWindow(id: "primary", title: "Session", used: 28, limit: 100,
                                            resetsAt: self.date.addingTimeInterval(3600))],
                      updatedAt: date ?? self.date, source: "Never shared")
    }

    func controller() -> LiveActivityController {
        let backend = LiveActivityController.Backend(
            isAuthorized: { [self] in authorized },
            sessions: { [self] in sessions },
            request: { [self] attributes, state, _ in
                requests += 1
                if let requestError { throw requestError }
                requestedStates.append(state)
                let id = "activity-\(requests)"
                let session = LiveActivityController.Session(
                    id: id, provider: attributes.provider, startedAt: attributes.startedAt,
                    update: { [weak self] state, staleDate in
                        guard let self else { return }
                        updates.append(Update(state: state, staleDate: staleDate))
                        if suspendUpdate {
                            await withCheckedContinuation { self.updateContinuation = $0 }
                        }
                    }, end: { [weak self] in
                        self?.ended.append(id)
                        self?.sessions.removeAll { $0.id == id }
                    }
                )
                sessions.append(session)
                return session
            }
        )
        return LiveActivityController(defaults: defaults, backend: backend, now: { [self] in date })
    }

    func start(_ controller: LiveActivityController) {
        controller.start(snapshot: snapshot(provider: controller.provider), configured: true, demo: false, display: .remaining)
    }

    func reconcile(_ controller: LiveActivityController, provider: Provider = .codex) {
        controller.reconcile(snapshot: snapshot(provider: provider), configured: true, demo: false, display: .remaining)
    }

    func waitUntil(_ predicate: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if predicate() { return }
            await Task.yield()
        }
        XCTFail("Expected Live Activity operation did not complete", file: file, line: line)
    }
}
