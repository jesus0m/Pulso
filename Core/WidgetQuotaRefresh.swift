import Foundation
import WidgetKit

enum WidgetQuotaDiagnostics {
    private static let queue = DispatchQueue(label: "com.jesusom.pulso.widget-diagnostics")

    static func begin(scope: String) -> UUID {
        let id = UUID()
        write {
            let key = "widgetQuotaExecution.\(scope)"
            let count = ($0.dictionary(forKey: key)?["count"] as? Int ?? 0) + 1
            $0.set(["id": id.uuidString, "startedAt": Date(), "count": count], forKey: key)
        }
        return id
    }

    static func finish(scope: String, id: UUID) {
        write {
            let key = "widgetQuotaExecution.\(scope)"
            guard var report = $0.dictionary(forKey: key), report["id"] as? String == id.uuidString else { return }
            report["finishedAt"] = Date()
            $0.set(report, forKey: key)
        }
    }

    static func decision(_ provider: Provider, _ reason: String) {
        write { $0.set(["date": Date(), "reason": reason], forKey: "widgetQuotaDecision.\(provider.rawValue)") }
    }

    static func timeline(scope: String, requestedAfter: Date, entryCount: Int) {
        write {
            $0.set(["date": Date(), "requestedAfter": requestedAfter, "entryCount": entryCount],
                   forKey: "widgetTimeline.\(scope)")
        }
    }

    private static func write(_ operation: (UserDefaults) -> Void) {
        // Keep this trace independent of quota-storage locks so a blocked reader is observable.
        queue.sync {
            guard let defaults = UserDefaults(suiteName: SnapshotCache.suite) else { return }
            defaults.synchronize()
            operation(defaults)
            defaults.synchronize()
        }
    }
}

struct WidgetQuotaConfiguration: Codable, Equatable, Sendable {
    var revision = UUID()
    var codexEnabled: Bool
    var username: String
    var allowance: Double?
    var legacy: Bool
    var organizationPlan: Bool
    var claudeOrganizationID: String? = nil

    static func load() -> Self? {
        let defaults = UserDefaults(suiteName: SnapshotCache.suite)
        defaults?.synchronize()
        guard let data = defaults?.data(forKey: "widgetQuotaConfiguration") else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    static func save(_ configuration: Self) {
        try? SharedQuotaAccess.transaction {
            var comparable = configuration
            if let current = load() {
                comparable.revision = current.revision
                if comparable == current { return }
            }
            persist(configuration)
        }
    }

    static func invalidate(_ provider: Provider) {
        try? SharedQuotaAccess.transaction {
            guard var configuration = load() else { return }
            configuration.revision = UUID()
            if provider == .codex { configuration.codexEnabled = false }
            if provider == .copilot { configuration.username = "" }
            if provider == .claude { configuration.claudeOrganizationID = nil }
            persist(configuration)
            SnapshotCache.remove(provider)
        }
    }

    private static func persist(_ configuration: Self) {
        guard let defaults = UserDefaults(suiteName: SnapshotCache.suite),
              let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: "widgetQuotaConfiguration")
        defaults.synchronize()
    }

    static func reserve(_ provider: Provider, configuration: Self, now: Date, userInitiated: Bool = false) -> Bool {
        (try? SharedQuotaAccess.transaction {
            guard load() == configuration, let defaults = UserDefaults(suiteName: SnapshotCache.suite) else { return false }
            let key = "widgetQuotaAttempt.\(provider.rawValue)"
            let previousAttempt = defaults.dictionary(forKey: key)
            if previousAttempt?["revision"] as? String == configuration.revision.uuidString,
               let previous = previousAttempt?["date"] as? Date {
                let elapsed = now.timeIntervalSince(previous)
                if elapsed < (userInitiated ? 10 : 120) ||
                    (elapsed < 120 && previousAttempt?["result"] as? String == "En curso") { return false }
            }
            defaults.set(["revision": configuration.revision.uuidString, "date": now, "result": "En curso"], forKey: key)
            defaults.synchronize()
            return true
        }) ?? false
    }

    static func commit(_ snapshot: UsageSnapshot, configuration: Self) -> Bool {
        (try? SharedQuotaAccess.transaction {
            guard load() == configuration else { return false }
            SnapshotCache.merge(snapshot)
            let saved = SnapshotCache.load().contains { $0.provider == snapshot.provider && $0.updatedAt >= snapshot.updatedAt }
            if saved { recordResult(snapshot.provider, configuration: configuration, result: "Actualizado") }
            return saved
        }) ?? false
    }

    static func recordFailure(_ provider: Provider, configuration: Self, error: Error) {
        let failure = error as NSError
        recordResult(provider, configuration: configuration, result: "Error \(failure.domain) (\(failure.code))")
    }

    private static func recordResult(_ provider: Provider, configuration: Self, result: String) {
        try? SharedQuotaAccess.transaction {
            guard load() == configuration, let defaults = UserDefaults(suiteName: SnapshotCache.suite) else { return }
            let key = "widgetQuotaAttempt.\(provider.rawValue)"
            guard var attempt = defaults.dictionary(forKey: key),
                  attempt["revision"] as? String == configuration.revision.uuidString else { return }
            attempt["result"] = result
            defaults.set(attempt, forKey: key)
            defaults.synchronize()
        }
    }
}

struct WidgetQuotaRefresh {
    struct Dependencies {
        var configuration: () -> WidgetQuotaConfiguration?
        var snapshots: () -> [UsageSnapshot]
        var reserve: (Provider, WidgetQuotaConfiguration, Date, Bool) -> Bool
        var fetch: (Provider, WidgetQuotaConfiguration) async throws -> UsageSnapshot
        var commit: (UsageSnapshot, WidgetQuotaConfiguration) -> Bool
        var now: () -> Date = Date.init
        var reloadWidgets: () -> Void = {}
        var recordFailure: (Provider, WidgetQuotaConfiguration, Error) -> Void = { _, _, _ in }

        static var live: Self {
            Self(configuration: WidgetQuotaConfiguration.load, snapshots: SnapshotCache.load,
                 reserve: WidgetQuotaConfiguration.reserve,
                 fetch: WidgetQuotaRefresh.fetch,
                 commit: WidgetQuotaConfiguration.commit,
                 reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
                 recordFailure: WidgetQuotaConfiguration.recordFailure)
        }
    }

    var dependencies: Dependencies = .live

    func refresh(providers requestedProviders: Set<Provider> = Set(Provider.allCases),
                 userInitiated: Bool = false) async -> [UsageSnapshot] {
        let scope = requestedProviders.count == 1 ? requestedProviders.first!.rawValue : "summary"
        let executionID = WidgetQuotaDiagnostics.begin(scope: scope)
        defer { WidgetQuotaDiagnostics.finish(scope: scope, id: executionID) }
        guard let configuration = dependencies.configuration() else {
            for provider in requestedProviders { WidgetQuotaDiagnostics.decision(provider, "Sin configuración") }
            return dependencies.snapshots()
        }
        let now = dependencies.now()
        let cached = dependencies.snapshots()
        let providers = Provider.allCases.filter { provider in
            guard requestedProviders.contains(provider) else { return false }
            let configured: Bool
            switch provider {
            case .codex: configured = configuration.codexEnabled
            case .copilot: configured = !configuration.username.isEmpty
            case .claude: configured = configuration.claudeOrganizationID != nil
            }
            guard configured else {
                WidgetQuotaDiagnostics.decision(provider, "Proveedor desconectado")
                return false
            }
            if !userInitiated, let snapshot = cached.first(where: { $0.provider == provider }),
               now.timeIntervalSince(snapshot.updatedAt) < 120,
               !snapshot.windows.contains(where: { ($0.resetsAt ?? .distantFuture) <= now }) {
                WidgetQuotaDiagnostics.decision(provider, "Lectura reciente")
                return false
            }
            let reserved = dependencies.reserve(provider, configuration, now, userInitiated)
            WidgetQuotaDiagnostics.decision(provider, reserved ? "Consultando proveedor" : "Reserva no disponible")
            return reserved
        }
        var changed = false
        await withTaskGroup(of: UsageSnapshot?.self) { group in
            for provider in providers {
                group.addTask {
                    do {
                        let snapshot = try await dependencies.fetch(provider, configuration)
                        guard !Task.isCancelled, snapshot.provider == provider, snapshot.updatedAt >= now else {
                            WidgetQuotaDiagnostics.decision(provider, "Respuesta descartada")
                            return nil
                        }
                        return snapshot
                    } catch {
                        if !Task.isCancelled { dependencies.recordFailure(provider, configuration, error) }
                        WidgetQuotaDiagnostics.decision(provider, Task.isCancelled ? "Consulta cancelada" : "Error de consulta")
                        return nil
                    }
                }
            }
            for await snapshot in group {
                guard !Task.isCancelled, let snapshot else { continue }
                if dependencies.commit(snapshot, configuration) {
                    changed = true
                    WidgetQuotaDiagnostics.decision(snapshot.provider, "Lectura guardada")
                } else {
                    WidgetQuotaDiagnostics.decision(snapshot.provider, "Lectura descartada al guardar")
                }
            }
        }
        if changed { dependencies.reloadWidgets() }
        return dependencies.snapshots()
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 8
        configuration.timeoutIntervalForResource = 8
        return URLSession(configuration: configuration, delegate: WidgetRedirectPolicy(), delegateQueue: nil)
    }

    private static func fetch(_ provider: Provider, configuration: WidgetQuotaConfiguration) async throws -> UsageSnapshot {
        let session = session()
        defer { session.finishTasksAndInvalidate() }
        if provider == .claude {
            guard let credentials = try ClaudeCredentialVault.shared.load(),
                  credentials.organizationID == configuration.claudeOrganizationID else { throw ClaudeQuotaError.signIn }
            let reading = try await ClaudeQuotaClient(session: session).fetch(credentials)
            try ClaudeCredentialVault.shared.replace(reading.credentials, matching: credentials)
            return reading.snapshot
        }
        if provider == .copilot {
            guard let token = TokenVault.read() else { throw UsageError.invalidCredentials }
            if configuration.organizationPlan {
                return try await CopilotQuotaClient(session: session).fetch(token: token, allowance: configuration.allowance)
            }
            return try await GitHubUsageClient(session: session).fetch(
                username: configuration.username, token: token, allowance: configuration.allowance, legacy: configuration.legacy)
        }
        let client = CodexOAuthClient(session: session)
        guard var credentials = try CodexCredentialVault.load() ?? CodexPastedToken.load().map({
            CodexCredentials(accessToken: $0, refreshToken: nil, idToken: nil, accountID: nil, email: nil, expiresAt: nil)
        }) else { throw CodexAuthError.signIn }
        var renewed = false
        if credentials.needsRefresh(at: Date()), credentials.refreshToken != nil {
            credentials = try await renew(credentials, client: client)
            renewed = true
        }
        do { return try await client.fetchUsage(credentials) }
        catch CodexAuthError.signIn where !renewed && credentials.refreshToken != nil {
            credentials = try await renew(credentials, client: client)
            return try await client.fetchUsage(credentials)
        }
    }

    private static func renew(_ credentials: CodexCredentials, client: CodexOAuthClient) async throws -> CodexCredentials {
        // Rotation must finish saving even if the requesting timeline is cancelled.
        let work = Task {
            try await SharedQuotaAccess.withOAuthLock(wait: 4) {
                guard let current = try CodexCredentialVault.load() else { throw CancellationError() }
                if current != credentials { return current }
                let updated = try await client.refresh(current)
                try CodexCredentialVault.replace(updated, matching: current)
                return updated
            }
        }
        return try await work.value
    }
}

private final class WidgetRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
