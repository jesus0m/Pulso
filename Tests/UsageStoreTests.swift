import XCTest
@testable import Pulso

@MainActor
final class UsageStoreTests: XCTestCase {
    func testLogoutInvalidatesWidgetBeforeDeletingCredentialAndPublishesDisconnectedState() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        fixture.widgetEvents.removeAll()
        await store.disconnect(.copilot)
        XCTAssertEqual(fixture.widgetEvents, ["invalidate", "delete", "publish"])
        XCTAssertEqual(fixture.widgetConfigurations.last?.username, "")
    }

    func testSavedAccountPublishesNewWidgetConfigurationBeforeFetching() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let save = Task {
            await store.saveGitHub(username: "second", allowanceText: "200", legacy: true, token: "new-fixture",
                                   organizationPlan: false)
        }
        await waitForRequests(1, fixture: fixture)
        XCTAssertEqual(fixture.widgetConfigurations.last?.username, "second")
        XCTAssertEqual(fixture.widgetConfigurations.last?.allowance, 200)
        XCTAssertEqual(fixture.widgetConfigurations.last?.legacy, true)
        fixture.complete(0, used: 20)
        await save.value
    }

    func testCancellingOnlyWaiterReleasesRefreshAndDiscardsLateResponse() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let cancelled = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
        cancelled.cancel()
        let result = await cancelled.value
        XCTAssertTrue(result.cancelled)
        XCTAssertFalse(store.refreshing)

        let replacement = Task { await store.refresh() }
        await waitForRequests(2, fixture: fixture)
        fixture.complete(0, used: 90)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 12)
        XCTAssertTrue(fixture.saved.isEmpty)
        fixture.complete(1, used: 25)
        await replacement.value
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 25)
        XCTAssertFalse(fixture.saved.flatMap { $0 }.contains { $0.windows.first?.used == 90 })
    }

    func testCancelledWaiterDoesNotCancelSharedForegroundRefresh() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let background = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
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
        background.cancel()
        let cancelled = await background.value
        XCTAssertTrue(cancelled.cancelled)
        XCTAssertTrue(store.refreshing)
        XCTAssertEqual(fixture.requests.count, 1)

        fixture.complete(0, used: 42)
        let result = await foreground.value
        XCTAssertEqual(result.refreshed, [.copilot])
        XCTAssertFalse(result.cancelled)
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 42)
    }

    func testCancellingRefreshPropagatesToCancellableProvider() async {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "githubOrganizationPlan")
        let started = expectation(description: "Provider started")
        let cancelled = expectation(description: "Provider cancelled")
        fixture.quotaFetch = {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
                throw UsageError.noUsageData
            } catch {
                if Task.isCancelled { cancelled.fulfill() }
                throw error
            }
        }
        let store = fixture.makeStore()
        let refresh = Task { await store.refresh() }
        await fulfillment(of: [started], timeout: 1)
        refresh.cancel()
        await refresh.value
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertTrue(fixture.saved.isEmpty)
    }

    func testTemporarilyLockedPATRemainsConfiguredAndPreservesActivity() async {
        let fixture = StoreFixture()
        var ended = 0
        let session = LiveActivityController.Session(
            id: "copilot-activity", provider: .copilot, startedAt: Date(),
            update: { _, _ in }, end: { ended += 1 }
        )
        fixture.defaults.set(true, forKey: "liveActivityEnabled")
        fixture.defaults.set("copilot", forKey: "liveActivityProvider")
        fixture.defaults.set(session.id, forKey: "liveActivityID")
        let controller = LiveActivityController(
            defaults: fixture.defaults,
            backend: .init(isAuthorized: { true }, sessions: { [session] },
                           request: { _, _, _ in session })
        )
        fixture.availability = .temporarilyUnavailable
        let store = fixture.makeStore(liveActivity: controller)
        let before = store.snapshot(for: .copilot)
        let result = await store.refresh()
        XCTAssertTrue(store.githubConfigured)
        XCTAssertEqual(result.attempted, [.copilot])
        XCTAssertEqual(result.failed, [.copilot])
        XCTAssertTrue(result.refreshed.isEmpty)
        XCTAssertEqual(store.snapshot(for: .copilot), before)
        XCTAssertNotNil(store.errors[.copilot])
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(ended, 0)
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertTrue(fixture.requests.isEmpty)
    }

    func testWatchReceivesDisplayAndVisibilityChangesWithoutRemovingPhoneReadings() throws {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let previousDisplay = store.quotaDisplay
        defer { store.quotaDisplay = previousDisplay }
        store.quotaDisplay = .used
        store.setProviderVisible(.copilot, false)
        let state = try XCTUnwrap(fixture.watchStates.last)
        XCTAssertEqual(state.quotaDisplay, .used)
        XCTAssertEqual(state.visibleProviders, [.codex, .claude])
        XCTAssertNil(state.snapshot(for: .copilot))
        XCTAssertNotNil(store.snapshot(for: .copilot))
        XCTAssertEqual(fixture.token, "original-token")
    }

    func testWatchReceivesRefreshAndLogoutInsteadOfRetainingDisconnectedQuota() async throws {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "githubOrganizationPlan")
        let store = fixture.makeStore()
        await store.refresh()
        let state = try XCTUnwrap(fixture.watchStates.last)
        XCTAssertEqual(state.snapshot(for: .copilot)?.windows.first?.used, 42)
        XCTAssertEqual(state.snapshot(for: .copilot)?.source, "")
        await store.disconnect(.copilot)
        XCTAssertNil(fixture.watchStates.last?.snapshot(for: .copilot))
        XCTAssertTrue(fixture.watchStates.last?.visibleProviders.contains(.copilot) == true)
    }

    func testWatchKeepsLastReadingAndMarksFailedFetchWithoutSendingErrorText() async {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "githubOrganizationPlan")
        fixture.quotaError = UsageError.http(403)
        let store = fixture.makeStore()
        await store.refresh()
        XCTAssertEqual(fixture.watchStates.last?.failedProviders, [.copilot])
        XCTAssertEqual(fixture.watchStates.last?.snapshot(for: .copilot)?.windows.first?.used, 12)
        XCTAssertNotNil(store.errors[.copilot])
    }

    func testProviderVisibilityRestoresAndIgnoresUnknownProviders() {
        let fixture = StoreFixture()
        fixture.defaults.set(["copilot", "unknown-provider"], forKey: "hiddenProviders")
        let store = fixture.makeStore()
        XCTAssertEqual(store.hiddenProviders, [.copilot])
        XCTAssertEqual(store.visibleProviders, [.codex, .claude])
        XCTAssertFalse(store.isProviderVisible(.copilot))

        store.setProviderVisible(.claude, false)
        let restored = fixture.makeStore()
        XCTAssertEqual(restored.hiddenProviders, [.copilot, .claude])
        XCTAssertEqual(restored.visibleProviders, [.codex])

        restored.setProviderVisible(.copilot, true)
        XCTAssertEqual(fixture.makeStore().visibleProviders, [.codex, .copilot])
    }

    func testAllProvidersCanBeHiddenAndRestoredInStableOrder() {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        XCTAssertEqual(store.visibleProviders, [.codex, .copilot, .claude])
        for provider in Provider.allCases { store.setProviderVisible(provider, false) }
        let restored = fixture.makeStore()
        XCTAssertTrue(restored.visibleProviders.isEmpty)
        restored.setProviderVisible(.claude, true)
        restored.setProviderVisible(.codex, true)
        restored.setProviderVisible(.copilot, true)
        XCTAssertEqual(fixture.makeStore().visibleProviders, [.codex, .copilot, .claude])
    }

    func testHidingProvidersPreservesConnectionsCredentialsAndSnapshots() {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "codexEnabled")
        fixture.defaults.set(true, forKey: "claudeEnabled")
        fixture.initialSnapshots = [fixture.snapshot(used: 12), fixture.snapshot(used: 25, provider: .codex),
                                    fixture.snapshot(used: 37, provider: .claude)]
        let store = fixture.makeStore()
        let original = store.snapshots

        for provider in Provider.allCases { store.setProviderVisible(provider, false) }

        XCTAssertTrue(store.githubConfigured)
        XCTAssertTrue(store.codexConfigured)
        XCTAssertTrue(store.claudeConfigured)
        XCTAssertEqual(fixture.token, "original-token")
        XCTAssertEqual(store.snapshots, original)
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(fixture.clearCodexCalls, 0)
        XCTAssertEqual(fixture.clearClaudeCalls, 0)
        XCTAssertEqual(fixture.deleteTokenCalls, 0)
    }

    func testPanelOrderPersistsNormalizesAndDrivesEveryConsumer() {
        let fixture = StoreFixture()
        fixture.defaults.set(["claude", "bogus", "claude", "codex"], forKey: "providerOrder")
        let store = fixture.makeStore()
        XCTAssertEqual(store.providerOrder, [.claude, .codex, .copilot], "Unknown and repeated entries drop; new providers append")
        XCTAssertEqual(store.visibleProviders, [.claude, .codex, .copilot])
        XCTAssertEqual(fixture.summaryPublications.last, [.claude, .codex, .copilot])

        store.moveProvider(.copilot, by: -1)
        XCTAssertEqual(store.providerOrder, [.claude, .copilot, .codex])
        XCTAssertEqual(fixture.makeStore().providerOrder, [.claude, .copilot, .codex])
        XCTAssertEqual(fixture.watchStates.last?.visibleProviders, [.claude, .copilot, .codex])
        XCTAssertEqual(fixture.summaryPublications.last, [.claude, .copilot, .codex])

        store.moveProvider(.claude, by: -1)
        store.moveProvider(.codex, by: 1)
        XCTAssertEqual(store.providerOrder, [.claude, .copilot, .codex], "Moves past either end are ignored")
        XCTAssertFalse(store.canMoveProvider(.claude, by: -1))
        XCTAssertTrue(store.canMoveProvider(.codex, by: -1))
    }

    func testHiddenPanelsLeaveTheSummaryButKeepOrderAndAccounts() {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "codexEnabled")
        let store = fixture.makeStore()
        store.moveProvider(.claude, by: -1)
        store.moveProvider(.claude, by: -1)
        store.setProviderVisible(.copilot, false)
        XCTAssertEqual(fixture.summaryPublications.last, [.claude, .codex])
        XCTAssertEqual(store.providerOrder, [.claude, .codex, .copilot], "Hiding never reorders")
        XCTAssertTrue(store.codexConfigured)
        store.setProviderVisible(.copilot, true)
        XCTAssertEqual(fixture.summaryPublications.last, [.claude, .codex, .copilot])
        for provider in Provider.allCases { store.setProviderVisible(provider, false) }
        XCTAssertEqual(fixture.summaryPublications.last, [])
    }

    func testHiddenProviderContinuesRefreshing() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        store.setProviderVisible(.copilot, false)
        let refresh = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
        fixture.complete(0, used: 42)
        await refresh.value
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 42)
        XCTAssertFalse(store.isProviderVisible(.copilot))
    }

    func testGitHubConfigurationAndCredentialRestoreInAnotherStore() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let save = Task {
            await store.saveGitHub(username: "saved-account", allowanceText: "250", legacy: true, token: "saved-token")
        }
        await waitForRequests(1, fixture: fixture)
        fixture.complete(0, used: 15)
        await save.value

        let restored = fixture.makeStore()
        XCTAssertEqual(restored.username, "saved-account")
        XCTAssertEqual(restored.allowanceText, "250")
        XCTAssertEqual(restored.allowance, 250)
        XCTAssertTrue(restored.legacy)
        XCTAssertTrue(restored.githubConfigured)
        XCTAssertEqual(fixture.token, "saved-token")
    }

    func testBlankReplacementTokenRetainsSavedCredentialWithoutWritingAgain() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let save = Task {
            await store.saveGitHub(username: "original", allowanceText: "200", legacy: true, token: "  \n")
        }
        await waitForRequests(1, fixture: fixture)
        XCTAssertEqual(fixture.requests[0].token, "original-token")
        fixture.complete(0, used: 15)
        await save.value

        XCTAssertEqual(fixture.token, "original-token")
        XCTAssertEqual(fixture.saveTokenCalls, 0)
        XCTAssertTrue(fixture.makeStore().githubConfigured)
    }

    func testUnsavedDraftDoesNotChangeConfiguredAccountOrUnits() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        var draft = store.githubDraft
        draft.username = "unsaved"
        draft.allowanceText = "999"
        draft.legacy = true
        XCTAssertEqual(store.username, "original")
        XCTAssertEqual(store.allowance, 100)
        XCTAssertFalse(store.legacy)
        XCTAssertEqual(fixture.defaults.string(forKey: "githubUsername"), "original")
    }

    func testSaveQueriesNewAccountWhileOldRefreshIsStillPending() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let oldRefresh = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
        let save = Task {
            await store.saveGitHub(username: "new-account", allowanceText: "200", legacy: true, token: "new-token")
        }
        await waitForRequests(2, fixture: fixture)
        XCTAssertNil(store.snapshot(for: .copilot), "Previous account's cache must be cleared before new data arrives")
        XCTAssertEqual(fixture.requests[1].username, "new-account")
        XCTAssertEqual(fixture.requests[1].token, "new-token")
        XCTAssertEqual(fixture.requests[1].allowance, 200)
        XCTAssertTrue(fixture.requests[1].legacy)
        fixture.complete(0, used: 90)
        await oldRefresh.value
        XCTAssertNil(store.snapshot(for: .copilot), "Late original account response must be discarded")
        fixture.complete(1, used: 25)
        await save.value
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 25)
        XCTAssertFalse(store.refreshing)
        XCTAssertFalse(fixture.saved.flatMap { $0 }.contains { $0.windows.first?.used == 90 })
    }

    func testLogoutDoesNotRestoreInflightSnapshot() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let refresh = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
        await store.disconnect(.copilot)
        fixture.complete(0, used: 90)
        await refresh.value
        XCTAssertNil(store.snapshot(for: .copilot))
        XCTAssertFalse(store.githubConfigured)
        XCTAssertNil(fixture.token)
        XCTAssertEqual(fixture.saved.last, [])
    }

    func testDemoNeverFetchesOrPersistsExampleSnapshots() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore(demo: true)
        XCTAssertEqual(store.snapshot(for: .copilot)?.source, "Datos de ejemplo")
        XCTAssertEqual(store.snapshot(for: .claude)?.source, "Datos de ejemplo")
        XCTAssertEqual(store.snapshot(for: .claude)?.windows.first?.used, 37)
        await store.refresh()
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertTrue(fixture.saved.isEmpty)
        XCTAssertEqual(fixture.watchStates.last?.isDemo, true)
        store.demo = false
        XCTAssertEqual(fixture.watchStates.last?.isDemo, false)
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 12)
    }

    func testCodexCanClearSessionWithoutConfiguredConnection() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        XCTAssertFalse(store.codexConfigured)
        await store.disconnect(.codex)
        XCTAssertEqual(fixture.clearCodexCalls, 1)
    }

    func testClaudeRefreshAndLogoutPreserveOtherProviderSnapshots() async {
        let fixture = StoreFixture()
        fixture.defaults.removeObject(forKey: "githubUsername")
        fixture.defaults.set(true, forKey: "claudeEnabled")
        fixture.initialSnapshots = [fixture.snapshot(used: 12, provider: .codex)]
        let store = fixture.makeStore()
        let refresh = Task { await store.refresh() }
        await waitForClaudeRequest(fixture)
        fixture.claudeRequests[0].resume(returning: fixture.snapshot(used: 37, provider: .claude))
        await refresh.value
        XCTAssertEqual(store.snapshot(for: .claude)?.windows.first?.used, 37)
        XCTAssertNotNil(store.snapshot(for: .codex))
        fixture.widgetEvents.removeAll()
        await store.disconnect(.claude)
        XCTAssertNil(store.snapshot(for: .claude))
        XCTAssertNotNil(store.snapshot(for: .codex))
        XCTAssertEqual(fixture.clearClaudeCalls, 1)
        XCTAssertEqual(fixture.clearCodexCalls, 0)
        XCTAssertEqual(fixture.deleteClaudeCredentialsCalls, 1)
        XCTAssertEqual(fixture.widgetEvents, ["invalidate", "delete-claude", "publish"])
        XCTAssertFalse(store.claudeConfigured)
        XCTAssertEqual(fixture.saved.last?.map(\.provider), [.codex])
    }

    func testClaudeLogoutDiscardsInflightResponse() async {
        let fixture = StoreFixture()
        fixture.defaults.removeObject(forKey: "githubUsername")
        fixture.defaults.set(true, forKey: "claudeEnabled")
        let store = fixture.makeStore()
        let refresh = Task { await store.refresh() }
        await waitForClaudeRequest(fixture)
        await store.disconnect(.claude)
        fixture.claudeRequests[0].resume(returning: fixture.snapshot(used: 37, provider: .claude))
        await refresh.value
        XCTAssertNil(store.snapshot(for: .claude))
        XCTAssertFalse(fixture.saved.flatMap { $0 }.contains { $0.provider == .claude })
    }

    func testClaudeFailureKeepsLastReadingAndTimestamp() async {
        let fixture = StoreFixture()
        fixture.defaults.removeObject(forKey: "githubUsername")
        fixture.defaults.set(true, forKey: "claudeEnabled")
        let original = fixture.snapshot(used: 37, provider: .claude)
        fixture.initialSnapshots = [original]
        let store = fixture.makeStore()
        let refresh = Task { await store.refresh() }
        await waitForClaudeRequest(fixture)
        fixture.claudeRequests[0].resume(throwing: UsageError.http(403))
        await refresh.value
        XCTAssertEqual(store.snapshot(for: .claude), original)
        XCTAssertNotNil(store.errors[.claude])
        XCTAssertTrue(fixture.saved.isEmpty)
    }

    func testClaudeCanClearSessionBeforeConnectionIsEnabled() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        await store.disconnect(.claude)
        XCTAssertEqual(fixture.clearClaudeCalls, 1)
        XCTAssertEqual(fixture.clearCodexCalls, 0)
        XCTAssertFalse(store.claudeConfigured)
    }

    func testOrganizationAccountUsesQuotaInsteadOfPersonalBilling() async {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "githubOrganizationPlan")
        let store = fixture.makeStore()
        await store.refresh()
        XCTAssertEqual(fixture.quotaCalls, 1)
        XCTAssertEqual(fixture.quotaToken, "original-token")
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 42)
    }

    func testNewOrganizationModeDropsMisleadingPersonalBillingCacheOnly() {
        let fixture = StoreFixture()
        fixture.defaults.removeObject(forKey: "githubOrganizationPlan")
        var personal = fixture.snapshot(used: 0)
        personal.source = "GitHub API · uso bruto · límite desconocido"
        fixture.initialSnapshots = [personal, fixture.snapshot(used: 27, provider: .codex)]
        let store = fixture.makeStore()
        XCTAssertTrue(store.organizationPlan)
        XCTAssertNil(store.snapshot(for: .copilot))
        XCTAssertNotNil(store.snapshot(for: .codex))
        XCTAssertEqual(fixture.saved.last?.map(\.provider), [.codex])
    }

    func testQuotaPermissionFailureDoesNotOverwriteLastValidReading() async {
        let fixture = StoreFixture()
        fixture.defaults.set(true, forKey: "githubOrganizationPlan")
        fixture.quotaError = UsageError.http(403)
        let original = fixture.snapshot(used: 12)
        fixture.initialSnapshots = [original]
        let store = fixture.makeStore()
        await store.refresh()
        XCTAssertEqual(store.snapshot(for: .copilot), original)
        XCTAssertNotNil(store.errors[.copilot])
        XCTAssertTrue(fixture.saved.isEmpty)
    }

    func testSwitchToOrganizationDiscardsLatePersonalBillingResponse() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        let old = Task { await store.refresh() }
        await waitForRequests(1, fixture: fixture)
        await store.saveGitHub(username: "original", allowanceText: "", legacy: false, token: "", organizationPlan: true)
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 42)
        fixture.complete(0, used: 90)
        await old.value
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 42)
        XCTAssertTrue(fixture.makeStore().organizationPlan)
    }

    private func waitForClaudeRequest(_ fixture: StoreFixture) async {
        for _ in 0..<1000 {
            if !fixture.claudeRequests.isEmpty { return }
            await Task.yield()
        }
        XCTFail("Expected Claude quota request")
    }

    private func waitForRequests(_ count: Int, fixture: StoreFixture) async {
        for _ in 0..<1000 {
            if fixture.requests.count >= count { return }
            await Task.yield()
        }
        XCTFail("Expected \(count) requests, received \(fixture.requests.count)")
    }
}

@MainActor
private final class StoreFixture {
    struct Request {
        let username: String
        let token: String
        let allowance: Double?
        let legacy: Bool
        let continuation: CheckedContinuation<UsageSnapshot, Error>
    }
    let suite = "com.jesusom.pulso.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var token: String? = "original-token"
    var requests: [Request] = []
    var saved: [[UsageSnapshot]] = []
    var clearCodexCalls = 0
    var clearClaudeCalls = 0
    var deleteClaudeCredentialsCalls = 0
    var saveTokenCalls = 0
    var deleteTokenCalls = 0
    var claudeRequests: [CheckedContinuation<UsageSnapshot, Error>] = []
    var initialSnapshots: [UsageSnapshot]?
    var quotaCalls = 0
    var quotaToken: String?
    var quotaError: Error?
    var quotaFetch: (() async throws -> UsageSnapshot)?
    var availability: TokenVault.Availability?
    var watchStates: [WatchQuotaState] = []
    var widgetConfigurations: [WidgetQuotaConfiguration] = []
    var widgetEvents: [String] = []
    var summaryPublications: [[Provider]] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "githubOrganizationPlan")
        defaults.set("original", forKey: "githubUsername")
        defaults.set("100", forKey: "githubAllowance")
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func makeStore(demo: Bool = false, liveActivity: LiveActivityController? = nil) -> UsageStore {
        let dependencies = UsageStore.Dependencies(
            loadSnapshots: { [self] in initialSnapshots ?? [snapshot(used: 12)] },
            saveSnapshots: { [self] in saved.append($0) },
            readToken: { [self] in token },
            saveToken: { [self] in saveTokenCalls += 1; token = $0 },
            deleteToken: { [self] in deleteTokenCalls += 1; token = nil; widgetEvents.append("delete") },
            fetchGitHub: { [self] username, token, allowance, legacy in
                try await withCheckedThrowingContinuation { continuation in
                    requests.append(Request(username: username, token: token, allowance: allowance, legacy: legacy, continuation: continuation))
                }
            },
            reloadWidgets: {}, clearCodex: { [self] in clearCodexCalls += 1 },
            fetchClaude: { [self] in
                try await withCheckedThrowingContinuation { claudeRequests.append($0) }
            }, clearClaude: { [self] in clearClaudeCalls += 1 },
            fetchCopilotQuota: { [self] token in
                quotaCalls += 1
                quotaToken = token
                if let quotaFetch { return try await quotaFetch() }
                if let quotaError { throw quotaError }
                return snapshot(used: 42)
            },
            syncWatch: { [self] in watchStates.append($0) },
            tokenAvailability: { [self] in availability ?? token.map(TokenVault.Availability.available) ?? .missing },
            publishWidgetConfiguration: { [self] in widgetConfigurations.append($0); widgetEvents.append("publish") },
            invalidateWidgetConfiguration: { [self] _ in widgetEvents.append("invalidate") },
            deleteClaudeCredentials: { [self] in deleteClaudeCredentialsCalls += 1; widgetEvents.append("delete-claude") },
            publishSummaryProviders: { [self] in summaryPublications.append($0) }
        )
        return UsageStore(dependencies: dependencies, defaults: defaults, demo: demo, liveActivity: liveActivity)
    }

    func complete(_ index: Int, used: Double) {
        requests[index].continuation.resume(returning: snapshot(used: used))
    }

    func snapshot(used: Double, provider: Provider = .copilot) -> UsageSnapshot {
        UsageSnapshot(provider: provider, windows: [UsageWindow(id: "month", title: "Mes", used: used, limit: 100, resetsAt: nil)], updatedAt: Date(), source: "Fixture")
    }
}
