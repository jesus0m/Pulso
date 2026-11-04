import XCTest
@testable import Pulso

final class ResetNotifierTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func snapshot(_ provider: Provider, windows: [UsageWindow]) -> UsageSnapshot {
        UsageSnapshot(provider: provider, windows: windows, updatedAt: now, source: "test")
    }

    func testSchedulesOneAlertPerFutureWindow() {
        let pending = ResetNotifier.pending(for: [snapshot(.codex, windows: [
            UsageWindow(id: "primary", title: "Sesión · 5 h", used: 100, limit: 100,
                        resetsAt: now.addingTimeInterval(3600)),
            UsageWindow(id: "secondary", title: "Semana · 7 d", used: 50, limit: 100,
                        resetsAt: now.addingTimeInterval(86_400))
        ])], now: now)

        XCTAssertEqual(pending.map(\.id), ["reset.codex.primary", "reset.codex.secondary"])
        XCTAssertEqual(pending.map(\.fireAt), [now.addingTimeInterval(3600), now.addingTimeInterval(86_400)])
        XCTAssertTrue(pending.allSatisfy { $0.title == "Codex renovada" })
        XCTAssertEqual(pending[0].body, "Sesión · 5 h vuelve a estar al 100 %.")
    }

    func testPastAndUnknownResetsNeverProduceAnAlert() {
        let pending = ResetNotifier.pending(for: [snapshot(.claude, windows: [
            UsageWindow(id: "past", title: "Vencida", used: 10, limit: 100,
                        resetsAt: now.addingTimeInterval(-1)),
            UsageWindow(id: "exact", title: "Justo ahora", used: 10, limit: 100, resetsAt: now),
            UsageWindow(id: "unknown", title: "Sin fecha", used: 10, limit: 100, resetsAt: nil)
        ])], now: now)

        XCTAssertTrue(pending.isEmpty)
    }

    func testIdentifiersStayStablePerWindowSoARereadReplacesItsOwnAlert() {
        let windows = [UsageWindow(id: "primary", title: "Sesión", used: 10, limit: 100,
                                   resetsAt: now.addingTimeInterval(60))]
        let first = ResetNotifier.pending(for: [snapshot(.codex, windows: windows)], now: now)
        let later = ResetNotifier.pending(for: [snapshot(.codex, windows: windows)], now: now.addingTimeInterval(30))
        XCTAssertEqual(first.map(\.id), later.map(\.id))
    }

    @MainActor
    func testDeniedPermissionLeavesTheSwitchOffInsteadOfPromisingAnAlert() async {
        let suite = "reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var scheduled: [Bool] = []
        var dependencies = emptyDependencies()
        dependencies.requestNotifications = { false }
        dependencies.scheduleResetAlerts = { _, enabled in scheduled.append(enabled) }
        let store = UsageStore(dependencies: dependencies, defaults: defaults, demo: false)

        await store.setResetAlerts(true)

        XCTAssertFalse(store.resetAlerts)
        XCTAssertTrue(store.notificationsDenied)
        XCTAssertFalse(defaults.bool(forKey: "resetAlerts"))
        XCTAssertTrue(scheduled.isEmpty, "Nada que programar si iOS no lo va a mostrar")
    }

    @MainActor
    func testGrantedPermissionPersistsAndTurningItOffClearsPendingAlerts() async {
        let suite = "reset.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        var scheduled: [Bool] = []
        var dependencies = emptyDependencies()
        dependencies.requestNotifications = { true }
        dependencies.scheduleResetAlerts = { _, enabled in scheduled.append(enabled) }
        let store = UsageStore(dependencies: dependencies, defaults: defaults, demo: false)

        await store.setResetAlerts(true)
        XCTAssertTrue(store.resetAlerts)
        XCTAssertTrue(defaults.bool(forKey: "resetAlerts"))
        XCTAssertFalse(store.notificationsDenied)

        await store.setResetAlerts(false)
        XCTAssertFalse(store.resetAlerts)
        XCTAssertFalse(defaults.bool(forKey: "resetAlerts"))
        XCTAssertEqual(scheduled, [true, false], "Apagarlo debe retirar los avisos ya programados")
    }

    @MainActor
    private func emptyDependencies() -> UsageStore.Dependencies {
        UsageStore.Dependencies(
            loadSnapshots: { [] }, saveSnapshots: { _ in }, readToken: { nil },
            saveToken: { _ in }, deleteToken: {},
            fetchGitHub: { _, _, _, _ in throw UsageError.invalidResponse },
            reloadWidgets: {})
    }

    func testEachProviderGetsItsOwnIdentifierNamespace() {
        let window = UsageWindow(id: "primary", title: "Sesión", used: 10, limit: 100,
                                 resetsAt: now.addingTimeInterval(60))
        let pending = ResetNotifier.pending(for: [
            snapshot(.codex, windows: [window]),
            snapshot(.claude, windows: [window])
        ], now: now)
        XCTAssertEqual(Set(pending.map(\.id)).count, 2)
        XCTAssertEqual(pending.map(\.title), ["Codex renovada", "Claude renovada"])
    }
}
