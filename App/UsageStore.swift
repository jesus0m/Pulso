import Foundation
import Observation
import WidgetKit

@MainActor @Observable
final class UsageStore {
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

        static var live: Self {
            Self(loadSnapshots: SnapshotCache.load, saveSnapshots: SnapshotCache.save,
                 readToken: TokenVault.read, saveToken: TokenVault.save, deleteToken: TokenVault.delete,
                 fetchGitHub: { name, token, allowance, legacy in
                     try await GitHubUsageClient().fetch(username: name, token: token, allowance: allowance, legacy: legacy)
                 }, reloadWidgets: { WidgetCenter.shared.reloadAllTimelines() })
        }
    }

    private(set) var snapshots: [UsageSnapshot]
    private(set) var errors: [Provider: String] = [:]
    private(set) var refreshing = false
    private(set) var hiddenProviders: Set<Provider>
    var demo: Bool
    var deskMode = false
    var nightMode = false
    private(set) var username: String
    private(set) var allowanceText: String
    private(set) var legacy: Bool
    private(set) var organizationPlan: Bool
    let codex = CodexWebSession()
    let claude = ClaudeWebSession()
    private var revision = 0
    @ObservationIgnored private var activeRefresh: Task<Void, Never>?
    @ObservationIgnored private let dependencies: Dependencies
    @ObservationIgnored private let defaults: UserDefaults

    init(dependencies: Dependencies = .live, defaults: UserDefaults = .standard, demo: Bool? = nil) {
        self.dependencies = dependencies
        self.defaults = defaults
        snapshots = dependencies.loadSnapshots()
        username = defaults.string(forKey: "githubUsername") ?? ""
        allowanceText = defaults.string(forKey: "githubAllowance") ?? ""
        legacy = defaults.bool(forKey: "githubLegacy")
        organizationPlan = defaults.object(forKey: "githubOrganizationPlan") as? Bool ?? true
        hiddenProviders = Set((defaults.stringArray(forKey: "hiddenProviders") ?? []).compactMap(Provider.init(rawValue:)))
        self.demo = demo ?? ProcessInfo.processInfo.arguments.contains("--demo")
        // Remove the old personal billing report when this account is organization-paid.
        if organizationPlan, snapshots.contains(where: { $0.provider == .copilot && $0.source.hasPrefix("GitHub API") }) {
            snapshots.removeAll { $0.provider == .copilot }
            dependencies.saveSnapshots(snapshots)
            dependencies.reloadWidgets()
        }
    }

    var githubConfigured: Bool { !username.isEmpty && dependencies.readToken() != nil }
    var codexConfigured: Bool { defaults.bool(forKey: "codexEnabled") }
    var claudeConfigured: Bool { defaults.bool(forKey: "claudeEnabled") }
    var githubDraft: GitHubDraft { GitHubDraft(username: username, allowanceText: allowanceText, legacy: legacy, organizationPlan: organizationPlan) }
    var allowance: Double? { Self.parseAllowance(allowanceText) }
    var visibleProviders: [Provider] { Provider.allCases.filter { isProviderVisible($0) } }

    func isProviderVisible(_ provider: Provider) -> Bool { !hiddenProviders.contains(provider) }

    func setProviderVisible(_ provider: Provider, _ visible: Bool) {
        if visible { hiddenProviders.remove(provider) }
        else { hiddenProviders.insert(provider) }
        defaults.set(Provider.allCases.filter { hiddenProviders.contains($0) }.map(\.rawValue), forKey: "hiddenProviders")
    }

    private static func parseAllowance(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        return value
    }

    func snapshot(for provider: Provider) -> UsageSnapshot? {
        if demo { return Self.demoSnapshots.first { $0.provider == provider } }
        return snapshots.first { $0.provider == provider }
    }

    func saveGitHub(username: String, allowanceText: String, legacy: Bool, token: String, organizationPlan: Bool? = nil) async {
        do {
            let organizationPlan = organizationPlan ?? self.organizationPlan
            let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
            let allowanceText = allowanceText.trimmingCharacters(in: .whitespacesAndNewlines)
            let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw ConfigurationError.missingUsername }
            if !organizationPlan && !allowanceText.isEmpty && Self.parseAllowance(allowanceText) == nil { throw ConfigurationError.invalidAllowance }
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
            await refresh()
        } catch { errors[.copilot] = error.localizedDescription }
    }

    func enableCodex() async {
        invalidateRefresh()
        defaults.set(true, forKey: "codexEnabled")
        demo = false
        await refresh()
    }

    func beginClaudeLogin() {
        invalidateRefresh()
        removeSnapshot(.claude)
        defaults.set(false, forKey: "claudeEnabled")
        claude.openLogin()
    }

    func enableClaude() async {
        invalidateRefresh()
        removeSnapshot(.claude)
        defaults.set(true, forKey: "claudeEnabled")
        demo = false
        await refresh()
    }

    func selectClaudeOrganization(_ id: String) async {
        do {
            try claude.selectOrganization(id)
            invalidateRefresh()
            removeSnapshot(.claude)
            errors[.claude] = nil
            if claudeConfigured { await refresh() }
        } catch { errors[.claude] = error.localizedDescription }
    }

    func refresh() async {
        guard !demo else { return }
        if let activeRefresh { await activeRefresh.value; return }
        refreshing = true
        let currentRevision = revision
        let task = Task { await self.performRefresh(revision: currentRevision) }
        activeRefresh = task
        await task.value
        guard revision == currentRevision else { return }
        activeRefresh = nil
        refreshing = false
    }

    private func performRefresh(revision currentRevision: Int) async {
        // Capture this generation's configuration before the first suspension.
        let name = username
        let allowance = allowance
        let legacy = legacy
        let organizationPlan = organizationPlan
        let token = dependencies.readToken()
        if !name.isEmpty, let token {
            do {
                let value: UsageSnapshot
                if organizationPlan {
                    if let fetch = dependencies.fetchCopilotQuota { value = try await fetch(token) }
                    else { value = try await CopilotQuotaClient().fetch(token: token) }
                } else {
                    value = try await dependencies.fetchGitHub(name, token, allowance, legacy)
                }
                guard !Task.isCancelled, revision == currentRevision else { return }
                accept(value)
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return }
                errors[.copilot] = error.localizedDescription
            }
        }
        guard revision == currentRevision, !Task.isCancelled else { return }
        if codexConfigured {
            do {
                let value: UsageSnapshot
                if let fetch = dependencies.fetchCodex { value = try await fetch() }
                else { value = try await codex.fetchUsage() }
                guard !Task.isCancelled, revision == currentRevision else { return }
                accept(value)
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return }
                errors[.codex] = error.localizedDescription
            }
        }
        guard revision == currentRevision, !Task.isCancelled else { return }
        if claudeConfigured {
            do {
                let value: UsageSnapshot
                if let fetch = dependencies.fetchClaude { value = try await fetch() }
                else { value = try await claude.fetchUsage() }
                guard !Task.isCancelled, revision == currentRevision else { return }
                accept(value)
            } catch {
                guard revision == currentRevision, !Task.isCancelled else { return }
                errors[.claude] = error.localizedDescription
            }
        }
    }

    private func invalidateRefresh() {
        revision += 1
        activeRefresh?.cancel()
        activeRefresh = nil
        refreshing = false
    }

    private func accept(_ snapshot: UsageSnapshot) {
        snapshots.removeAll { $0.provider == snapshot.provider }
        snapshots.append(snapshot)
        errors[snapshot.provider] = nil
        dependencies.saveSnapshots(snapshots)
        dependencies.reloadWidgets()
    }

    private func removeSnapshot(_ provider: Provider) {
        snapshots.removeAll { $0.provider == provider }
        dependencies.saveSnapshots(snapshots)
        dependencies.reloadWidgets()
    }

    func disconnect(_ provider: Provider) async {
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
            if let clear = dependencies.clearClaude { await clear() }
            else { await claude.clearSession() }
        } else {
            defaults.set(false, forKey: "codexEnabled")
            if let clear = dependencies.clearCodex { await clear() }
            else { await codex.clearSession() }
        }
    }

    private static let demoSnapshots: [UsageSnapshot] = [
        UsageSnapshot(provider: .codex, windows: [
            UsageWindow(id: "session", title: "Sesión · 5 h", used: 28, limit: 100, resetsAt: Date().addingTimeInterval(7200)),
            UsageWindow(id: "week", title: "Semana", used: 46, limit: 100, resetsAt: Date().addingTimeInterval(172800))
        ], updatedAt: Date(), source: "Datos de ejemplo"),
        UsageSnapshot(provider: .copilot, windows: [
            UsageWindow(id: "month", title: "Créditos del mes", used: 184, limit: 1000, resetsAt: Date().addingTimeInterval(864000))
        ], updatedAt: Date(), source: "Datos de ejemplo"),
        UsageSnapshot(provider: .claude, windows: [
            UsageWindow(id: "five_hour", title: "Sesión · 5 h", used: 37, limit: 100, resetsAt: Date().addingTimeInterval(10800)),
            UsageWindow(id: "seven_day", title: "Semana", used: 22, limit: 100, resetsAt: Date().addingTimeInterval(259200))
        ], updatedAt: Date(), source: "Datos de ejemplo")
    ]
}

private enum ConfigurationError: LocalizedError {
    case missingUsername, missingToken, invalidAllowance
    var errorDescription: String? {
        switch self {
        case .missingUsername: return "Introduce tu usuario de GitHub."
        case .missingToken: return "Añade un token de GitHub con permiso Plan de lectura."
        case .invalidAllowance: return "La cuota debe ser un número mayor que cero, o quedar vacía."
        }
    }
}
