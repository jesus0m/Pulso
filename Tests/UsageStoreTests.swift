import XCTest
@testable import Pulso

@MainActor
final class UsageStoreTests: XCTestCase {
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
        await store.refresh()
        XCTAssertTrue(fixture.requests.isEmpty)
        XCTAssertTrue(fixture.saved.isEmpty)
        store.demo = false
        XCTAssertEqual(store.snapshot(for: .copilot)?.windows.first?.used, 12)
    }

    func testCodexCanClearSessionWithoutConfiguredConnection() async {
        let fixture = StoreFixture()
        let store = fixture.makeStore()
        XCTAssertFalse(store.codexConfigured)
        await store.disconnect(.codex)
        XCTAssertEqual(fixture.clearCodexCalls, 1)
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

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set("original", forKey: "githubUsername")
        defaults.set("100", forKey: "githubAllowance")
    }

    deinit { defaults.removePersistentDomain(forName: suite) }

    func makeStore(demo: Bool = false) -> UsageStore {
        let dependencies = UsageStore.Dependencies(
            loadSnapshots: { [self] in [snapshot(used: 12)] },
            saveSnapshots: { [self] in saved.append($0) },
            readToken: { [self] in token },
            saveToken: { [self] in token = $0 },
            deleteToken: { [self] in token = nil },
            fetchGitHub: { [self] username, token, allowance, legacy in
                try await withCheckedThrowingContinuation { continuation in
                    requests.append(Request(username: username, token: token, allowance: allowance, legacy: legacy, continuation: continuation))
                }
            },
            reloadWidgets: {}, clearCodex: { [self] in clearCodexCalls += 1 }
        )
        return UsageStore(dependencies: dependencies, defaults: defaults, demo: demo)
    }

    func complete(_ index: Int, used: Double) {
        requests[index].continuation.resume(returning: snapshot(used: used))
    }

    private func snapshot(used: Double) -> UsageSnapshot {
        UsageSnapshot(provider: .copilot, windows: [UsageWindow(id: "month", title: "Mes", used: used, limit: 100, resetsAt: nil)], updatedAt: Date(), source: "Fixture")
    }
}
