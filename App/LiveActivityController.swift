import ActivityKit
import Foundation
import Observation

@MainActor @Observable
final class LiveActivityController {
    struct Session {
        let id: String
        let provider: Provider
        let startedAt: Date
        var update: (QuotaActivityAttributes.ContentState, Date) async -> Void
        var end: () async -> Void
        var observeEnd: (@escaping @MainActor () -> Void) -> Task<Void, Never>? = { _ in nil }
    }

    struct Backend {
        var isAuthorized: () -> Bool
        var sessions: () -> [Session]
        var request: (QuotaActivityAttributes, QuotaActivityAttributes.ContentState, Date) throws -> Session

        static var live: Self {
            Self(
                isAuthorized: { ActivityAuthorizationInfo().areActivitiesEnabled },
                sessions: {
                    Activity<QuotaActivityAttributes>.activities
                        .filter { $0.activityState == .active || $0.activityState == .stale }
                        .map(session)
                },
                request: { attributes, state, staleDate in
                    session(try Activity.request(attributes: attributes,
                                                 content: ActivityContent(state: state, staleDate: staleDate),
                                                 pushType: nil))
                }
            )
        }

        private static func session(_ activity: Activity<QuotaActivityAttributes>) -> Session {
            Session(id: activity.id, provider: activity.attributes.provider,
                    startedAt: activity.attributes.startedAt,
                    update: { state, staleDate in
                        await activity.update(ActivityContent(state: state, staleDate: staleDate))
                    }, end: {
                        await activity.end(nil, dismissalPolicy: .immediate)
                    }, observeEnd: { onEnd in
                        Task { @MainActor in
                            for await state in activity.activityStateUpdates {
                                guard !Task.isCancelled else { return }
                                if state == .ended || state == .dismissed {
                                    onEnd()
                                    return
                                }
                            }
                        }
                    })
        }
    }

    private(set) var enabled: Bool
    private(set) var provider: Provider
    private(set) var activeID: String?
    private(set) var message: String?
    var isRunning: Bool { activeID != nil }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var operations: Task<Void, Never>?
    @ObservationIgnored private var observation: Task<Void, Never>?
    @ObservationIgnored private var generation = 0

    init(defaults: UserDefaults = .standard, backend: Backend = .live, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.backend = backend
        self.now = now
        enabled = defaults.bool(forKey: "liveActivityEnabled")
        provider = Provider(rawValue: defaults.string(forKey: "liveActivityProvider") ?? "") ?? .codex
        activeID = defaults.string(forKey: "liveActivityID")
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        defaults.set(value, forKey: "liveActivityEnabled")
        if !value { stop() }
    }

    func selectProvider(_ value: Provider) {
        guard value != provider else { return }
        stop()
        provider = value
        defaults.set(value.rawValue, forKey: "liveActivityProvider")
    }

    func start(snapshot: UsageSnapshot?, configured: Bool, demo: Bool, display: QuotaDisplay,
               refreshFailed: Bool = false, unavailable: Bool = false) {
        reconcile(snapshot: snapshot, configured: configured, demo: demo, display: display,
                  refreshFailed: refreshFailed, unavailable: unavailable)
        guard enabled, !isRunning else { return }
        guard backend.isAuthorized() else {
            message = String(localized: "iOS no permite actividades en directo. Revisa Ajustes → PULSO.")
            return
        }
        guard !demo else {
            message = String(localized: "Desactiva los datos de ejemplo para iniciar una actividad real.")
            return
        }
        guard configured, !unavailable, let snapshot, snapshot.provider == provider,
              let state = QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: display,
                                                                    refreshFailed: refreshFailed) else {
            message = String(localized: "Conecta este proveedor y consulta una cuota real antes de iniciar.")
            return
        }
        let date = now()
        do {
            let session = try backend.request(
                QuotaActivityAttributes(providerID: provider.rawValue, startedAt: date),
                state, state.staleDate(now: date)
            )
            activeID = session.id
            defaults.set(session.id, forKey: "liveActivityID")
            message = nil
            observe(session)
        } catch {
            message = String(localized: "iOS no pudo iniciar la actividad en directo. Vuelve a intentarlo con PULSO abierta.")
        }
    }

    func reconcile(snapshot: UsageSnapshot?, configured: Bool, demo: Bool, display: QuotaDisplay,
                   refreshFailed: Bool = false, unavailable: Bool = false) {
        let sessions = backend.sessions()
        guard enabled, configured, !demo, !unavailable, backend.isAuthorized(),
              let snapshot, snapshot.provider == provider,
              let state = QuotaActivityAttributes.ContentState.make(snapshot: snapshot, display: display,
                                                                    refreshFailed: refreshFailed) else {
            let hadSession = activeID != nil || !sessions.isEmpty
            stop(sessions: sessions)
            if hadSession {
                if !backend.isAuthorized() { message = String(localized: "iOS tiene desactivadas las actividades en directo.") }
                else if demo { message = String(localized: "La demostración no se comparte con actividades en directo.") }
                else if enabled { message = String(localized: "Actividad finalizada: no hay una cuota real disponible.") }
            }
            return
        }
        guard let id = activeID,
              let session = sessions.first(where: { $0.id == id && $0.provider == provider }) else {
            // A dismissed or expired session may only be replaced by an explicit Start.
            if activeID != nil {
                clearSession()
                message = String(localized: "La actividad ha finalizado. Pulsa Iniciar para crear otra.")
            }
            for session in sessions { enqueueEnd(session) }
            return
        }
        guard now().timeIntervalSince(session.startedAt) < 8 * 3600 else {
            stop(sessions: sessions)
            message = String(localized: "La sesión ha alcanzado su duración máxima. Puedes iniciar otra.")
            return
        }
        for other in sessions where other.id != id { enqueueEnd(other) }
        if observation == nil { observe(session) }
        generation += 1
        let revision = generation
        let date = state.staleDate(now: now())
        let previous = operations
        operations = Task { [weak self] in
            await previous?.value
            guard let self, self.generation == revision, self.activeID == id, self.enabled else { return }
            await session.update(state, date)
        }
    }

    func stop() { stop(sessions: backend.sessions()) }

    private func stop(sessions: [Session]) {
        clearSession()
        message = nil
        for session in sessions { enqueueEnd(session) }
    }

    private func clearSession() {
        generation += 1
        observation?.cancel()
        observation = nil
        activeID = nil
        defaults.removeObject(forKey: "liveActivityID")
    }

    private func enqueueEnd(_ session: Session) {
        let previous = operations
        operations = Task {
            await previous?.value
            await session.end()
        }
    }

    private func observe(_ session: Session) {
        observation?.cancel()
        observation = session.observeEnd { [weak self] in
            guard let self, self.activeID == session.id else { return }
            self.clearSession()
            self.message = String(localized: "La actividad ha finalizado. Pulsa Iniciar para crear otra.")
        }
    }
}
