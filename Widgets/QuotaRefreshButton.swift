import AppIntents
import SwiftUI

struct QuotaRefreshButton: View {
    let target: QuotaRefreshTarget
    let accent: Color
    var showsTitle = false

    var body: some View {
        Button(intent: RefreshQuotaIntent(target: target)) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.clockwise")
                if showsTitle { Text("Actualizar") }
            }
            .font(.caption2.weight(.semibold))
            .frame(minWidth: 28, minHeight: 28)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.mini)
        .tint(accent)
        .accessibilityLabel(target == .summary ? String(localized: "Actualizar cuotas") : String(localized: "Actualizar cuota de \(target.providers.first!.title)"))
        .accessibilityHint("Consulta la última cuota sin abrir Pulso")
    }
}
