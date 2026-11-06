import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class UsageStore {
    struct RefreshResult: Sendable {
        var attempted: [Provider] = []
        var refreshed: [Provider] = []
        var failed: [Provider] = []
        var cancelled = false

        var succeeded: Bool { !cancelled && !refreshed.isEmpty }
    }

    @MainActor
    private final class RefreshOperation {
        let id = UUID()
        var task: Task<Void, Never>?
        var waiters: [UUID: CheckedContinuation<RefreshResult, Never>] = [:]
    }

    struct GitHubDraft: Equatable {
        var username = ""
        var allowanceText = ""
        var legacy = false
        var organizationPlan = true
    }

    struct Dependencies {
        var loadSnapshots: () -> [UsageSnapshot]
        var saveSnapshots: ([UsageSnapshot]) -> Void
        var readToken: () -> String?
        var saveToken: (String) throws -> Void
        var deleteToken: () throws -> Void
        var fetchGitHub: (String, String, Double?, Bool) async throws -> UsageSnapshot
        var reloadWidgets: () -> Void
        var fetchCodex: (() async throws -> UsageSnapshot)? = nil
        var clearCodex: (() async -> Void)? = nil
        var fetchClaude: (() async throws -> UsageSnapshot)? = nil
        var clearClaude: (() async -> Void)? = nil
        var fetchCopilotQuota: ((String) async throws -> UsageSnapshot)? = nil
        var scheduleResetAlerts: ([UsageSnapshot], Bool) -> Void = { snapshots, enabled in
            ResetNotifier.reschedule(for: snapshots, enabled: enabled)
        }
        var requestNotifications: () async -> Bool = ResetNotifier.requestAuthorization
        var syncWatch: @MainActor (WatchQuotaState) -> Void = { _ in }
        var tokenAvailability: (() -> TokenVault.Availability)? = nil
        var publishWidgetConfiguration: (WidgetQuotaConfiguration) -> Void = { _ in }
        var invalidateWidgetConfiguration: (Provider) -> Void = { _ in }
        var mergeCachedSnapshot: ((UsageSnapshot) -> Void)? = nil
        var removeCachedSnapshot: ((Provider) -> Void)? = nil
        var deleteClaudeCredentials: () throws -> Void = {}
        var publishSummaryProviders: ([Provider]) -> Void = { _ in }

        static var live: Self {
            Self(loadSnapshots: SnapshotCache.load, saveSnapshots: SnapshotCache.save,
                 readToken: TokenVault.read, saveToken: TokenVault.save, deleteToken: TokenVault.delete,
                 fetchGitHub: { name, token, allowance, legacy in
                     try await GitHubUsageClient().fetch(username: name, token: token, allowance: allowance, legacy: legacy)
                 }, reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() },
                 syncWatch: { PhoneWatchSync.shared.publish($0) },
                 tokenAvailability: TokenVault.availability,
                 publishWidgetConfiguration: { configuration in
                     if !configuration.username.isEmpty { _ = TokenVault.availability() }
                     if configuration.codexEnabled, (try? CodexCredentialVault.load()) == nil {
                         _ = CodexPastedToken.load()
                     }
                     WidgetQuotaConfiguration.save(configuration)
                 },
                 invalidateWidgetConfiguration: WidgetQuotaConfiguration.invalidate,
                 mergeCachedSnapshot: SnapshotCache.merge, removeCachedSnapshot: SnapshotCache.remove,
                 deleteClaudeCredentials: ClaudeCredentialVault.shared.delete,
                 publishSummaryProviders: { SnapshotCache.summaryProviders = $0 })
        }
    }

    private(set) var snapshots: [UsageSnapshot]
    private(set) var errors: [Provider: String] = [:]
    private(set) var refreshing = false
    private(set) var hiddenProviders: Set<Provider>
    /// One display order shared by the dashboard, summary widget, watch and live-activity picker.
    private(set) var providerOrder: [Provider]
    #if DEBUG
    var demo: Bool {
        didSet {
            if demo != oldValue {
                publishWatchState()
                reconcileLiveActivity()
            }
        }
    }
    #else
    var demo: Bool {
        get { false }
        set {}
    }
    #endif
    var deskMode = false
    var nightMode = false
    private(set) var username: String
    private(set) var allowanceText: String
    private(set) var legacy: Bool
    private(set) var organizationPlan: Bool
    private(set) var resetAlerts: Bool
    private(set) var notificationsDenied = false
    var quotaDisplay: QuotaDisplay = SnapshotCache.quotaDisplay {
        didSet {
            guard quotaDisplay != oldValue else { return }
            SnapshotCache.quotaDisplay = quotaDisplay
            dependencies.reloadWidgets()
            publishWatchState()
            reconcileLiveActivity()
        }
    }
    let codex = CodexSession()
    let claude = ClaudeWebSession()
    let liveActivity: LiveActivityController
    private var revision = 0
    private var unavailableActivityProviders: Set<Provider> = []
    @ObservationIgnored private var activeRefresh: RefreshOperation?
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let defaults: UserDefaults

    init(dependencies: Dependencies = .live, defaults: UserDefaults = .standard, demo: Bool? = nil,
         liveActivity: LiveActivityController? = nil) {
        self.dependencies = dependencies
        self.defaults = defaults
        self.liveActivity = liveActivity ?? LiveActivityController(defaults: defaults)
        snapshots = dependencies.loadSnapshots()
        username = defaults.string(forKey: "githubUsername") ?? ""
        allowanceText = defaults.string(forKey: "githubAllowance") ?? ""
        legacy = defaults.bool(forKey: "githubLegacy")
        organizationPlan = defaults.object(forKey: "githubOrganizationPlan") as? Bool ?? true
        resetAlerts = defaults.bool(forKey: "resetAlerts")
        hiddenProviders = Set((defaults.stringArray(forKey: "hiddenProviders") ?? []).compactMap(Provider.init(rawValue:)))
        providerOrder = Provider.ordered(from: defaults.stringArray(forKey: "providerOrder") ?? [])
        #if DEBUG
        self.demo = demo ?? ProcessInfo.processInfo.arguments.contains("--demo")
        // UI tests share one simulator: without this, a failed run leaves hidden
        // panels or a flipped preference behind and poisons every later test.
        if ProcessInfo.processInfo.arguments.contains("--reset-preferences") {
            hiddenProviders = []
            defaults.removeObject(forKey: "hiddenProviders")
            providerOrder = Provider.allCases
            defaults.removeObject(forKey: "providerOrder")
            quotaDisplay = .remaining
            SnapshotCache.quotaDisplay = .remaining
            self.liveActivity.setEnabled(false)
            self.liveActivity.selectProvider(.codex)
        }
        #endif
        // Remove the old personal billing report when this account is organization-paid.
        if organizationPlan, snapshots.contains(where: { $0.provider == .copilot && $0.source.hasPrefix("GitHub API") }) {
            snapshots.removeAll { $0.provider == .copilot }
            if let remove = dependencies.removeCachedSnapshot { remove(.copilot) }
            else { dependencies.saveSnapshots(snapshots) }
            dependencies.reloadWidgets()
        }
        publishWatchState()
        reconcileLiveActivity()
        publishWidgetConfiguration()
        dependencies.publishSummaryProviders(visibleProviders)
    }

    private func publishWidgetConfiguration() {
        guard !demo else { return }
        dependencies.publishWidgetConfiguration(WidgetQuotaConfiguration(
            codexEnabled: codexConfigured, username: username, allowance: allowance,
            legacy: legacy, organizationPlan: organizationPlan,
            claudeOrganizationID: claudeConfigured ? claude.selectedOrganizationID : nil))
    }

    func reconcileLiveActivity() {
        let provider = liveActivity.provider
        liveActivity.reconcile(
            snapshot: snapshots.first { $0.provider == provider },
            configured: isConfigured(provider), demo: demo, display: quotaDisplay,
            refreshFailed: errors[provider] != nil,
            unavailable: unavailableActivityProviders.contains(provider)
        )
    }

    func startLiveActivity() {
        let provider = liveActivity.provider
        liveActivity.start(
            snapshot: snapshots.first { $0.provider == provider },
            configured: isConfigured(provider), demo: demo, display: quotaDisplay,
            refreshFailed: errors[provider] != nil,
            unavailable: unavailableActivityProviders.contains(provider)
        )
    }

    func selectLiveActivityProvider(_ provider: Provider) {
        liveActivity.selectProvider(provider)
        reconcileLiveActivity()
    }

    private var githubTokenAvailability: TokenVault.Availability {
        if let availability = dependencies.tokenAvailability { return availability() }
        return dependencies.readToken().map(TokenVault.Availability.available) ?? .missing
    }

    var githubConfigured: Bool {
        guard !username.isEmpty else { return false }
        if case .missing = githubTokenAvailability { return false }
        return true
    }
    var codexConfigured: Bool { defaults.bool(forKey: "codexEnabled") }
    var claudeConfigured: Bool { defaults.bool(forKey: "claudeEnabled") }

    /// Denied permission leaves the switch off: it must not promise an alert iOS will never show.
    func setResetAlerts(_ enabled: Bool) async {
        guard enabled else {
            resetAlerts = false
            defaults.set(false, forKey: "resetAlerts")
            dependencies.scheduleResetAlerts(snapshots, false)
            return
        }
        guard await dependencies.requestNotifications() else {
            resetAlerts = false
            defaults.set(false, forKey: "resetAlerts")
            notificationsDenied = true
            return
        }
        notificationsDenied = false
        resetAlerts = true
        defaults.set(true, forKey: "resetAlerts")
        dependencies.scheduleResetAlerts(snapshots, true)
    }

    func isConfigured(_ provider: Provider) -> Bool {
        switch provider {
        case .codex: return codexConfigured
        case .copilot: return githubConfigured
        case .claude: return claudeConfigured
        }
    }
    var githubDraft: GitHubDraft { GitHubDraft(username: username, allowanceText: allowanceText, legacy: legacy, organizationPlan: organizationPlan) }
    var allowance: Double? { Self.parseAllowance(allowanceText) }
    var visibleProviders: [Provider] { providerOrder.filter { isProviderVisible($0) } }

    func isProviderVisible(_ provider: Provider) -> Bool { !hiddenProviders.contains(provider) }

    func setProviderVisible(_ provider: Provider, _ visible: Bool) {
        if visible { hiddenProviders.remove(provider) }
        else { hiddenProviders.insert(provider) }
        defaults.set(Provider.allCases.filter { hiddenProviders.contains($0) }.map(\.rawValue), forKey: "hiddenProviders")
        layoutChanged()
    }

    func canMoveProvider(_ provider: Provider, by offset: Int) -> Bool {
        guard let index = providerOrder.firstIndex(of: provider) else { return false }
        return providerOrder.indices.contains(index + offset)
    }

    /// Moves a panel one step up (-1) or down (+1); a move past either end is ignored.
    func moveProvider(_ provider: Provider, by offset: Int) {
        guard canMoveProvider(provider, by: offset), let index = providerOrder.firstIndex(of: provider) else { return }
        providerOrder.swapAt(index, index + offset)
        defaults.set(providerOrder.map(\.rawValue), forKey: "providerOrder")
        layoutChanged()
    }

    private func layoutChanged() {
        publishWatchState()
        dependencies.publishSummaryProviders(visibleProviders)
        dependencies.reloadWidgets()
    }

    private static func parseAllowance(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        #if DEBUG
        if demo { return Self.demoSnapshots.first { $0.provider == provider } }
        #endif
        return snapshots.first { $0.provider == provider }
    }

    private func publishWatchState() {
        dependencies.syncWatch(WatchQuotaState(
            snapshots: visibleProviders.compactMap { snapshot(for: $0) },
            visibleProviders: visibleProviders, quotaDisplay: quotaDisplay, isDemo: demo,
            failedProviders: demo ? [] : Provider.allCases.filter { errors[$0] != nil }
        ))
    }

    func saveGitHub(username: String, allowanceText: String, legacy: Bool, token: String, organizationPlan: Bool? = nil) async {
        defer { publishWidgetConfiguration() }
        do {
            let organizationPlan = organizationPlan ?? self.organizationPlan
            let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowanceText = allowanceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ConfigurationError.missingUsername }
            if !organizationPlan && !allowanceText.isEmpty && Self.parseAllowance(allowanceText) == nil { throw ConfigurationError.invalidAllowance }
            dependencies.invalidateWidgetConfiguration(.copilot)
            if !token.isEmpty { try dependencies.saveToken(token) }
            guard dependencies.readToken() != nil else { throw ConfigurationError.missingToken }
            invalidateRefresh()
            removeSnapshot(.copilot)
            self.username = name
            self.allowanceText = allowanceText
            self.legacy = legacy
            self.organizationPlan = organizationPlan
            defaults.set(organizationPlan, forKey: "githubOrganizationPlan")
            defaults.set(name, forKey: "githubUsername")
            defaults.set(allowanceText, forKey: "githubAllowance")
            defaults.set(legacy, forKey: "githubLegacy")
            errors[.copilot] = nil
            demo = false
            publishWidgetConfiguration()
            await refresh()
        } catch { errors[.copilot] = error.localizedDescription }
    }

    func signInCodex() async {
        dependencies.invalidateWidgetConfiguration(.codex)
        defer { publishWidgetConfiguration() }
        do {
            try await codex.signIn()
            invalidateRefresh()
            removeSnapshot(.codex)
            await enableCodex()
        } catch is CancellationError {
            return
        } catch {
            errors[.codex] = error.localizedDescription
        }
    }

    func enableCodex() async {
        invalidateRefresh()
        defaults.set(true, forKey: "codexEnabled")
        demo = false
        publishWidgetConfiguration()
        await refresh()
    }

    func beginClaudeLogin(email: String? = nil) {
        dependencies.invalidateWidgetConfiguration(.claude)
        defer { publishWidgetConfiguration() }
        invalidateRefresh()
        removeSnapshot(.claude)
        defaults.set(false, forKey: "claudeEnabled")
        do { try dependencies.deleteClaudeCredentials() }
        catch {
            errors[.claude] = error.localizedDescription
            return
        }
        claude.openLogin(email: email)
    }

    func enableClaude() async {
        defer { publishWidgetConfiguration() }
        invalidateRefresh()
        removeSnapshot(.claude)
        defaults.set(true, forKey: "claudeEnabled")
        demo = false
        await refresh()
    }

    func selectClaudeOrganization(_ id: String) async {
        guard claude.selectedOrganizationID != id else { return }
        defer { publishWidgetConfiguration() }
        do {
            try claude.selectOrganization(id)
            dependencies.invalidateWidgetConfiguration(.claude)
            invalidateRefresh()
            removeSnapshot(.claude)
            try dependencies.deleteClaudeCredentials()
            errors[.claude] = nil
            if claudeConfigured { await refresh() }
        } catch { errors[.claude] = error.localizedDescription }
    }

    @discardableResult
    func refresh(waiterID: UUID = UUID()) async -> RefreshResult {
        guard !demo else { return RefreshResult() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: RefreshResult(cancelled: true))
                    return
                }
                if let activeRefresh {
                    activeRefresh.waiters[waiterID] = continuation
                    return
                }
                let operation = RefreshOperation()
                operation.waiters[waiterID] = continuation
                activeRefresh = operation
                refreshing = true
                let currentRevision = revision
                operation.task = Task {
                    let result = await self.performRefresh(revision: currentRevision)
                    self.finishRefresh(id: operation.id, result: result)
                }
            }
        } onCancel: {
            Task { @MainActor in self.cancelRefresh(waiterID: waiterID) }
        }
    }

    func cancelRefresh(waiterID: UUID) {
        guard let operation = activeRefresh, let waiter = operation.waiters.removeValue(forKey: waiterID) else { return }
        // A foreground or watch consumer may still need the same provider operation.
        if operation.waiters.isEmpty { invalidateRefresh() }
        waiter.resume(returning: RefreshResult(cancelled: true))
    }

    private func finishRefresh(id: UUID, result: RefreshResult) {
        guard let operation = activeRefresh, operation.id == id else { return }
        activeRefresh = nil
        refreshing = false
        for waiter in operation.waiters.values { waiter.resume(returning: result) }
        operation.waiters.removeAll()
    }

    private func performRefresh(revision currentRevision: Int) async -> RefreshResult {
        var result = RefreshResult()
        let startedAt = Date()
        defer {
            publishWatchState()
            reconcileLiveActivity()
        }
        // Capture this generation's configuration before the first suspension.
        let name = username
        let allowance = allowance
        let legacy = legacy
        let organizationPlan = organizationPlan
        let tokenAvailability = githubTokenAvailability
        if !name.isEmpty, case .temporarilyUnavailable = tokenAvailability {
            result.attempted.append(.copilot)
            result.failed.append(.copilot)
            recordRefreshFailure(ConfigurationError.temporarilyUnavailableToken, provider: .copilot)
        }
        if !name.isEmpty, case let .available(token) = tokenAvailability {
            result.attempted.append(.copilot)
            do {
                let value: UsageSnapshot
                if organizationPlan {
                    if let fetch = dependencies.fetchCopilotQuota { value = try await fetch(token) }
                    else { value = try await CopilotQuotaClient().fetch(token: token, allowance: allowance) }
                } else {
                    value = try await dependencies.fetchGitHub(name, token, allowance, legacy)
                }
                guard !Task.isCancelled, revision == currentRevision else { return RefreshResult(cancelled: true) }
                accept(value)
                if value.updatedAt >= startedAt { result.refreshed.append(.copilot) }
                else { result.failed.append(.copilot) }
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return RefreshResult(cancelled: true) }
                recordRefreshFailure(error, provider: .copilot)
                result.failed.append(.copilot)
            }
        }
        guard revision == currentRevision, !Task.isCancelled else { return RefreshResult(cancelled: true) }
        if codexConfigured {
            result.attempted.append(.codex)
            do {
                let value: UsageSnapshot
                if let fetch = dependencies.fetchCodex { value = try await fetch() }
                else { value = try await codex.fetchUsage() }
                guard !Task.isCancelled, revision == currentRevision else { return RefreshResult(cancelled: true) }
                accept(value)
                if value.updatedAt >= startedAt { result.refreshed.append(.codex) }
                else { result.failed.append(.codex) }
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return RefreshResult(cancelled: true) }
                recordRefreshFailure(error, provider: .codex)
                result.failed.append(.codex)
            }
        }
        guard revision == currentRevision, !Task.isCancelled else { return RefreshResult(cancelled: true) }
        if claudeConfigured {
            result.attempted.append(.claude)
            do {
                let value: UsageSnapshot
                if let fetch = dependencies.fetchClaude { value = try await fetch() }
                else { value = try await claude.fetchUsage() }
                guard !Task.isCancelled, revision == currentRevision else { return RefreshResult(cancelled: true) }
                publishWidgetConfiguration()
                accept(value)
                if value.updatedAt >= startedAt { result.refreshed.append(.claude) }
                else { result.failed.append(.claude) }
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return RefreshResult(cancelled: true) }
                recordRefreshFailure(error, provider: .claude)
                result.failed.append(.claude)
            }
        }
        return result
    }

    private func invalidateRefresh() {
        revision += 1
        let operation = activeRefresh
        operation?.task?.cancel()
        activeRefresh = nil
        refreshing = false
        if let operation {
            claude.cancelQuotaFetch()
            for waiter in operation.waiters.values { waiter.resume(returning: RefreshResult(cancelled: true)) }
            operation.waiters.removeAll()
        }
    }

    private func accept(_ snapshot: UsageSnapshot) {
        snapshots.removeAll { $0.provider == snapshot.provider }
        snapshots.append(snapshot)
        errors[snapshot.provider] = nil
        unavailableActivityProviders.remove(snapshot.provider)
        if let merge = dependencies.mergeCachedSnapshot { merge(snapshot) }
        else { dependencies.saveSnapshots(snapshots) }
        dependencies.reloadWidgets()
        dependencies.scheduleResetAlerts(snapshots, resetAlerts)
        publishWatchState()
        reconcileLiveActivity()
    }

    private func removeSnapshot(_ provider: Provider) {
        snapshots.removeAll { $0.provider == provider }
        if let remove = dependencies.removeCachedSnapshot { remove(provider) }
        else { dependencies.saveSnapshots(snapshots) }
        dependencies.reloadWidgets()
        publishWatchState()
        reconcileLiveActivity()
    }

    private func recordRefreshFailure(_ error: Error, provider: Provider) {
        errors[provider] = error.localizedDescription
        let permanent: Bool
        if let error = error as? UsageError {
            switch error {
            case .noUsageData, .unsupportedSchema, .invalidCredentials, .http(401), .http(404): permanent = true
            default: permanent = false
            }
        } else if let error = error as? CopilotQuotaError {
            switch error {
            case .noPublishedQuota, .unsupportedSchema, .unavailable, .accessDenied: permanent = true
            default: permanent = false
            }
        } else if let error = error as? CodexAuthError {
            switch error {
            case .signIn, .forbidden, .http(401), .http(403), .http(404): permanent = true
            default: permanent = false
            }
        } else if provider == .claude {
            permanent = ClaudeWebSession.isAuthoritativeUsageFailure(error)
        } else {
            permanent = false
        }
        if permanent { unavailableActivityProviders.insert(provider) }
        reconcileLiveActivity()
    }

    func disconnect(_ provider: Provider) async {
        dependencies.invalidateWidgetConfiguration(provider)
        defer { publishWidgetConfiguration() }
        invalidateRefresh()
        errors[provider] = nil
        removeSnapshot(provider)
        if provider == .copilot {
            username = ""
            allowanceText = ""
            legacy = false
            organizationPlan = true
            for key in ["githubUsername", "githubAllowance", "githubLegacy", "githubOrganizationPlan"] { defaults.removeObject(forKey: key) }
            do { try dependencies.deleteToken() }
            catch { errors[provider] = error.localizedDescription }
        } else if provider == .claude {
            defaults.set(false, forKey: "claudeEnabled")
            do { try dependencies.deleteClaudeCredentials() }
            catch { errors[provider] = error.localizedDescription }
            if let clear = dependencies.clearClaude { await clear() }
            else { await claude.clearSession() }
        } else {
            defaults.set(false, forKey: "codexEnabled")
            if let clear = dependencies.clearCodex { await clear() }
            else {
                do { try codex.clearSession() }
                catch { errors[provider] = error.localizedDescription }
            }
        }
    }

    #if DEBUG
    private static let demoSnapshots: [UsageSnapshot] = [
        UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "session", title: "Sesión · 5 h", used: 28, limit: 100, resetsAt: Date().addingTimeInterval(7200)),
            UsageWindow(id: "week", title: "Semana", used: 46, limit: 100, resetsAt: Date().addingTimeInterval(172800))
        ], updatedAt: Date(), source: "Datos de ejemplo"),
        UsageSnapshot(provider: .copilot, windows: [
            UsageWindow(id: "copilot_credits", title: "Créditos del mes", used: 6134, limit: 60000,
                        resetsAt: Date().addingTimeInterval(864000), remaining: 53774, reportedRemainingPercent: 89.6)
        ], updatedAt: Date(), source: "Datos de ejemplo"),
        UsageSnapshot(provider: .claude, windows: [
            UsageWindow(id: "five_hour", title: "Sesión · 5 h", used: 37, limit: 100, resetsAt: Date().addingTimeInterval(10800)),
            UsageWindow(id: "seven_day", title: "Semana", used: 22, limit: 100, resetsAt: Date().addingTimeInterval(259200))
        ], updatedAt: Date(), source: "Datos de ejemplo")
    ]
    #endif
}

private enum ConfigurationError: LocalizedError {
    case missingUsername, missingToken, invalidAllowance, temporarilyUnavailableToken
    var errorDescription: String? {
        switch self {
        case .missingUsername: return String(localized: "Introduce tu usuario de GitHub.")
        case .missingToken: return String(localized: "Añade un token de GitHub con permiso Plan de lectura.")
        case .invalidAllowance: return String(localized: "La cuota debe ser un número mayor que cero, o quedar vacía.")
        case .temporarilyUnavailableToken: return String(localized: "El llavero no está disponible. Desbloquea el iPhone para actualizar GitHub Copilot.")
        }
    }
}
