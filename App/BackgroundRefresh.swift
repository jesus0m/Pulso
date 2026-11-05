import BackgroundTasks
import Foundation
import UIKit

/// iOS decides whether and when these run, and a detached WKWebView may not
/// survive long enough for the web-session providers. Every attempt is recorded
/// so "never woken" stays distinguishable from "woken but the provider failed".
enum BackgroundRefresh {
    static let identifier = "com.jesusom.pulso.refresh"
    private static let interval: TimeInterval = 2 * 60
    private static let runKey = "backgroundLastRun"
    private static let outcomeKey = "backgroundLastOutcome"
    private static let countKey = "backgroundRunCount"
    private static let requestKey = "backgroundLastRequest"
    private static let requestedAfterKey = "backgroundRequestedAfter"
    private static let schedulingErrorKey = "backgroundSchedulingError"

    struct Report {
        var lastRun: Date?
        var outcome: String?
        var count: Int
        var lastRequest: Date?
        var requestedAfter: Date?
        var schedulingError: String?
    }

    @MainActor
    final class Run {
        private let store: UsageStore
        private let waiterID = UUID()
        private let defaults: UserDefaults
        private let completion: (Bool) -> Void
        private var work: Task<Void, Never>?
        private var completed = false

        fileprivate init(store: UsageStore, defaults: UserDefaults, start: Date,
                         completion: @escaping (Bool) -> Void) {
            self.store = store
            self.defaults = defaults
            self.completion = completion
            BackgroundRefresh.recordStart(defaults: defaults, start: start)
            work = Task {
                let result = await store.refresh(waiterID: waiterID)
                guard !completed else { return }
                defaults.set(BackgroundRefresh.summary(for: result), forKey: outcomeKey)
                finish(success: result.succeeded)
            }
        }

        func expire() {
            guard !completed else { return }
            work?.cancel()
            store.cancelRefresh(waiterID: waiterID)
            defaults.set("Tiempo de ejecución agotado", forKey: outcomeKey)
            finish(success: false)
        }

        func wait() async { await work?.value }

        private func finish(success: Bool) {
            guard !completed else { return }
            completed = true
            completion(success)
        }
    }

    static var report: Report {
        let defaults = UserDefaults.standard
        return Report(lastRun: defaults.object(forKey: runKey) as? Date,
                      outcome: defaults.string(forKey: outcomeKey),
                      count: defaults.integer(forKey: countKey),
                      lastRequest: defaults.object(forKey: requestKey) as? Date,
                      requestedAfter: defaults.object(forKey: requestedAfterKey) as? Date,
                      schedulingError: defaults.string(forKey: schedulingErrorKey))
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
    private static func summary(for result: UsageStore.RefreshResult) -> String {
        let providers = Provider.allCases.filter { result.attempted.contains($0) }
        guard !providers.isEmpty else { return "Sin proveedores conectados" }
        return providers.map {
            "\($0.title) \(result.refreshed.contains($0) ? "✓" : "✗")"
        }.joined(separator: " · ")
    }

    private static func recordStart(defaults: UserDefaults, start: Date) {
        defaults.set(start, forKey: runKey)
        defaults.set("En curso", forKey: outcomeKey)
        defaults.set(defaults.integer(forKey: countKey) + 1, forKey: countKey)
    }

    @MainActor
    static func register(store: UsageStore) {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { task in
            Task { @MainActor in await run(task: task, store: store) }
        }
    }

    @MainActor
    static func schedule(defaults: UserDefaults = .standard, now: Date = Date(),
                         submit: (BGAppRefreshTaskRequest) throws -> Void = { try BGTaskScheduler.shared.submit($0) }) {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = now.addingTimeInterval(interval)
        defaults.set(now, forKey: requestKey)
        defaults.set(request.earliestBeginDate, forKey: requestedAfterKey)
        defaults.set(UIApplication.shared.backgroundRefreshStatus.rawValue, forKey: "backgroundRefreshStatus")
        defaults.set(ProcessInfo.processInfo.isLowPowerModeEnabled, forKey: "backgroundLowPowerMode")
        do {
            try submit(request)
            defaults.removeObject(forKey: schedulingErrorKey)
        } catch {
            let failure = error as NSError
            defaults.set("\(failure.domain) (\(failure.code))", forKey: schedulingErrorKey)
        }
    }

    @MainActor
    @discardableResult
    static func performRefresh(store: UsageStore, defaults: UserDefaults = .standard,
                               start: Date = Date()) async -> String {
        recordStart(defaults: defaults, start: start)
        let result = await store.refresh()
        let outcome = summary(for: result)
        defaults.set(outcome, forKey: outcomeKey)
        return outcome
    }

    @MainActor
    static func start(store: UsageStore, defaults: UserDefaults = .standard,
                      start: Date = Date(), completion: @escaping (Bool) -> Void) -> Run {
        Run(store: store, defaults: defaults, start: start, completion: completion)
    }

    @MainActor
    private static func run(task: BGTask, store: UsageStore) async {
        // Submit the next request first: a crash or expiry below must not end the chain.
        schedule()
        let run = start(store: store) {
            task.expirationHandler = nil
            task.setTaskCompleted(success: $0)
        }
        task.expirationHandler = { Task { @MainActor in run.expire() } }
        await run.wait()
        task.expirationHandler = nil
    }
}
