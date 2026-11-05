import Foundation
import Observation
import WatchConnectivity
import WidgetKit

@MainActor @Observable
final class WatchUsageStore: NSObject, WCSessionDelegate {
    private(set) var state: WatchQuotaState?
    private(set) var refreshing = false
    private(set) var status = String(localized: "Abre Pulso en el iPhone para sincronizar.")

    @ObservationIgnored private let cache = WatchQuotaCache()
    @ObservationIgnored private var timeout: Task<Void, Never>?
    @ObservationIgnored private var refreshID: UUID?
    @ObservationIgnored private let usesLaunchFixture: Bool

    override init() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        usesLaunchFixture = arguments.contains("--demo") || arguments.contains("--empty-state")
        #else
        usesLaunchFixture = false
        #endif
        super.init()
        #if DEBUG
        if arguments.contains("--reset-preferences") { cache.clear() }
        if arguments.contains("--empty-state") { return }
        if arguments.contains("--demo") {
            state = Self.demoState(display: arguments.contains("--quota-used") ? .used : .remaining)
            status = String(localized: "Datos de ejemplo")
            return
        }
        #endif
        state = cache.load()
        if state != nil { status = String(localized: "Lectura guardada. Conecta el iPhone para sincronizar.") }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func refresh() {
        guard !usesLaunchFixture, !refreshing, WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated else { return }
        guard session.isReachable else {
            status = String(localized: "Sin conexión. Abre Pulso en el iPhone.")
            return
        }
        refreshing = true
        let requestID = UUID()
        refreshID = requestID
        status = String(localized: "Sincronizando con el iPhone…")
        timeout?.cancel()
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(15)) } catch { return }
            self?.finishWithError(requestID: requestID)
        }
        session.sendMessage(["request": WatchQuotaState.refreshRequest], replyHandler: { [weak self] context in
            let state = WatchQuotaState(context: context)
            Task { @MainActor in
                guard let self, self.refreshID == requestID else { return }
                if let state {
                    if !self.receive(state) { self.status = String(localized: "Se conserva la lectura más reciente.") }
                    self.finishRefresh()
                } else {
                    self.finishWithError(requestID: requestID)
                }
            }
        }, errorHandler: { [weak self] _ in
            Task { @MainActor in self?.finishWithError(requestID: requestID) }
        })
    }

    @discardableResult
    private func receive(_ state: WatchQuotaState) -> Bool {
        guard self.state.map({ $0.sentAt <= state.sentAt }) ?? true, cache.save(state) else { return false }
        self.state = state
        status = String(localized: "Lectura recibida del iPhone")
        if !state.isDemo { WidgetCenter.shared.reloadAllTimelines() }
        return true
    }

    private func finishRefresh() {
        timeout?.cancel()
        timeout = nil
        refreshID = nil
        refreshing = false
    }

    private func finishWithError(requestID: UUID) {
        guard refreshID == requestID else { return }
        finishRefresh()
        status = String(localized: "No se pudo sincronizar. Abre Pulso en el iPhone.")
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        let state = WatchQuotaState(context: session.receivedApplicationContext)
        Task { @MainActor in
            if error != nil {
                self.status = String(localized: "No se pudo conectar con el iPhone.")
                return
            }
            if let state { self.receive(state) }
            self.refresh()
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        let reachable = session.isReachable
        Task { @MainActor in
            if reachable {
                self.refresh()
            } else {
                self.finishRefresh()
                self.status = String(localized: "Sin conexión. Se conserva la última lectura.")
            }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let state = WatchQuotaState(context: applicationContext) else { return }
        Task { @MainActor in self.receive(state) }
    }

    #if DEBUG
    private static func demoState(display: QuotaDisplay) -> WatchQuotaState {
        let now = Date()
        return WatchQuotaState(snapshots: [
            UsageSnapshot(provider: .codex, windows: [
                UsageWindow(id: "session", title: "Sesión · 5 h", used: 28, limit: 100, resetsAt: now.addingTimeInterval(7200)),
                UsageWindow(id: "week", title: "Semana", used: 46, limit: 100, resetsAt: now.addingTimeInterval(172800))
            ], updatedAt: now, source: ""),
            UsageSnapshot(provider: .copilot, windows: [
                UsageWindow(id: "copilot_credits", title: "Créditos del mes", used: 6134, limit: 60000,
                            resetsAt: now.addingTimeInterval(864000), remaining: 53774, reportedRemainingPercent: 89.6)
            ], updatedAt: now, source: ""),
            UsageSnapshot(provider: .claude, windows: [
                UsageWindow(id: "five_hour", title: "Sesión · 5 h", used: 37, limit: 100, resetsAt: now.addingTimeInterval(10800)),
                UsageWindow(id: "seven_day", title: "Semana", used: 22, limit: 100, resetsAt: now.addingTimeInterval(259200))
            ], updatedAt: now, source: "")
        ], visibleProviders: Provider.allCases, quotaDisplay: display, isDemo: true)
    }
    #endif
}
