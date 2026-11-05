import Foundation

struct WatchQuotaState: Codable, Equatable, Sendable {
    static let contextKey = "pulso.quotas"
    static let refreshRequest = "pulso.refresh"

    private(set) var version = 1
    let sentAt: Date
    let snapshots: [UsageSnapshot]
    let visibleProviders: [Provider]
    let quotaDisplay: QuotaDisplay
    let isDemo: Bool
    let failedProviders: [Provider]

    init(snapshots: [UsageSnapshot], visibleProviders: [Provider], quotaDisplay: QuotaDisplay,
         isDemo: Bool = false, failedProviders: [Provider] = [], sentAt: Date = .now) {
        self.sentAt = sentAt
        self.visibleProviders = visibleProviders
        self.quotaDisplay = quotaDisplay
        self.isDemo = isDemo
        self.failedProviders = failedProviders.filter { visibleProviders.contains($0) }
        // Only quota readings cross devices, never account or authentication metadata.
        self.snapshots = snapshots.filter { visibleProviders.contains($0.provider) }.map {
            UsageSnapshot(provider: $0.provider, windows: $0.windows, updatedAt: $0.updatedAt, source: "")
        }
    }

    init?(context: [String: Any]) {
        guard let data = context[Self.contextKey] as? Data,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1 else { return nil }
        self = value
    }

    func context() throws -> [String: Any] {
        [Self.contextKey: try JSONEncoder().encode(self)]
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        snapshots.first { $0.provider == provider }
    }

    func isStale(_ provider: Provider, now: Date) -> Bool {
        guard let snapshot = snapshot(for: provider) else { return true }
        return failedProviders.contains(provider) || now.timeIntervalSince(snapshot.updatedAt) > 300
            || snapshot.windows.contains { ($0.resetsAt ?? .distantFuture) <= now }
    }
}

struct WatchQuotaCache {
    private let defaults: UserDefaults
    private let key = "watchQuotaState"

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults ?? UserDefaults(suiteName: SnapshotCache.suite) ?? .standard
    }

    func load() -> WatchQuotaState? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return WatchQuotaState(context: [WatchQuotaState.contextKey: data])
    }

    @discardableResult
    func save(_ state: WatchQuotaState) -> Bool {
        guard state.version == 1, load().map({ $0.sentAt <= state.sentAt }) ?? true,
              let data = try? JSONEncoder().encode(state) else { return false }
        defaults.set(data, forKey: key)
        return true
    }

    func clear() {
        defaults.removeObject(forKey: key)
    }
}
