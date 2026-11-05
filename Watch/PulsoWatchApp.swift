import SwiftUI

@main
struct PulsoWatchApp: App {
    @State private var store = WatchUsageStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchDashboardView(store: store)
                .preferredColorScheme(.dark)
                .tint(.mint)
                .task(id: scenePhase) {
                    if scenePhase == .active { store.refresh() }
                }
        }
    }
}
