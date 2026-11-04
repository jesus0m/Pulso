import BackgroundTasks
import Foundation

/// iOS decides whether and when these run, and a detached WKWebView may not
/// survive long enough for the web-session providers. Every attempt is recorded
/// so "never woken" stays distinguishable from "woken but the provider failed".
enum BackgroundRefresh {
    static let identifier = "com.jesusom.pulso.refresh"
    private static let interval: TimeInterval = 15 * 60
    private static let runKey = "backgroundLastRun"
    private static let outcomeKey = "backgroundLastOutcome"
    private static let countKey = "backgroundRunCount"

    struct Report {
        var lastRun: Date?
        var outcome: String?
        var count: Int
    }

    static var report: Report {
        let defaults = UserDefaults.standard
        return Report(lastRun: defaults.object(forKey: runKey) as? Date,
                      outcome: defaults.string(forKey: outcomeKey),
                      count: defaults.integer(forKey: countKey))
    }

    /// A provider counts as refreshed only if its reading is newer than this run,
    /// so a stale cache can never be reported as a success.
    static func summary(for providers: [(Provider, Date?)], since start: Date) -> String {
        guard !providers.isEmpty else { return "Sin proveedores conectados" }
        return providers.map { provider, updatedAt in
            "\(provider.title) \((updatedAt ?? .distantPast) >= start ? "✓" : "✗")"
        }.joined(separator: " · ")
    }

    @MainActor
    static func register(store: UsageStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in await run(task: task, store: store) }
        }
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    @MainActor
    @discardableResult
    static func performRefresh(store: UsageStore, defaults: UserDefaults = .standard,
                               start: Date = Date()) async -> String {
        await store.refresh()
        let outcome = summary(for: Provider.allCases.filter(store.isConfigured)
            .map { ($0, store.snapshot(for: $0)?.updatedAt) }, since: start)
        defaults.set(start, forKey: runKey)
        defaults.set(outcome, forKey: outcomeKey)
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
        return outcome
    }

    @MainActor
    private static func run(task: BGTask, store: UsageStore) async {
        // Submit the next request first: a crash or expiry below must not end the chain.
        schedule()
        let work = Task { @MainActor in await performRefresh(store: store) }
        task.expirationHandler = { work.cancel() }
        _ = await work.value
        task.setTaskCompleted(success: !work.isCancelled)
    }
}
