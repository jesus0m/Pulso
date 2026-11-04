import SwiftUI

@main
struct PulsoApp: App {
    @State private var store = UsageStore()
    var body: some Scene {
        WindowGroup {
            DashboardView(store: store)
                .preferredColorScheme(.dark)
                .tint(.mint)
        }
    }
}
