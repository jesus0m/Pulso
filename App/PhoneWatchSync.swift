import Foundation
import WatchConnectivity

@MainActor
final class PhoneWatchSync: NSObject, WCSessionDelegate {
    static let shared = PhoneWatchSync()

    private weak var store: UsageStore?
    private var latestState: WatchQuotaState?

    func start(store: UsageStore) {
        self.store = store
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func publish(_ state: WatchQuotaState) {
        latestState = state
        sendLatestState()
    }

    private func sendLatestState() {
        guard WCSession.isSupported(), let latestState else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        // Application context replaces old state and is delivered opportunistically offline.
        if let context = try? latestState.context() {
            try? session.updateApplicationContext(context)
        }
    }

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in self.sendLatestState() }
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in self.sendLatestState() }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in self.sendLatestState() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                             replyHandler: @escaping ([String: Any]) -> Void) {
        guard message["request"] as? String == WatchQuotaState.refreshRequest else {
            replyHandler([:])
            return
        }
        Task { @MainActor in
            // Reply promptly with the cache; fresh readings follow via application context.
            replyHandler((try? self.latestState?.context()) ?? [:])
            await self.store?.refresh()
        }
    }
}
