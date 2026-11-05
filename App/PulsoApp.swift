import SwiftUI

@main
struct PulsoApp: App {
    @State private var store: UsageStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        ResetNotifier.configureForegroundPresentation()
        let store = UsageStore()
        _store = State(initialValue: store)
        PhoneWatchSync.shared.start(store: store)
        // Must be registered before launch finishes, so it cannot wait for the view.
        BackgroundRefresh.register(store: store)
    }

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store)
                .preferredColorScheme(.dark)
                .tint(.mint)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { BackgroundRefresh.schedule() }
            if phase == .active { store.reconcileLiveActivity() }
        }
    }
}
