import SwiftUI
import WidgetKit

private struct UsageEntry: TimelineEntry {
    let date: Date
    let provider: Provider
    let snapshot: UsageSnapshot?
}

private struct CachedUsageProvider: TimelineProvider {
    let provider: Provider

    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), provider: provider, snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let now = Date()
        let current = entry(at: now)
        var entries = [current]
        // Dated entries update the presentation even if WidgetKit defers the next reload.
        if let snapshot = current.snapshot {
            var transitions = [snapshot.updatedAt.addingTimeInterval(301)]
            if let firstReset = snapshot.windows.compactMap(\.resetsAt).filter({ $0 > now }).min() {
                transitions.append(firstReset)
            }
            for date in Set(transitions.filter { $0 > now }).sorted() {
                entries.append(UsageEntry(date: date, provider: provider, snapshot: snapshot))
            }
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }

    private func entry(at date: Date) -> UsageEntry {
        UsageEntry(date: date, provider: provider,
                   snapshot: SnapshotCache.load().first { $0.provider == provider })
    }
}

private struct ProviderWidgetView: View {
    let entry: UsageEntry
    private var accent: Color {
        switch entry.provider {
        case .codex: return Color(red: 0.57, green: 0.95, blue: 0.78)
        case .copilot: return Color(red: 0.78, green: 0.69, blue: 1)
        case .claude: return Color(red: 0.95, green: 0.65, blue: 0.48)
        }
    }
    private var window: UsageWindow? { entry.snapshot?.windows.first }
    private var renewalPending: Bool {
        entry.snapshot?.windows.contains { window in
            window.resetsAt.map { $0 <= entry.date } ?? false
        } ?? false
    }
    private var isStale: Bool {
        guard let updatedAt = entry.snapshot?.updatedAt else { return true }
        return renewalPending || entry.date.timeIntervalSince(updatedAt) > 300
    }
    private var amount: String {
        guard let window, !renewalPending else { return "—" }
        if let percent = window.displayedRemainingPercent { return "\(percent)%" }
        guard window.used.isFinite, window.used >= 0 else { return "—" }
        return window.used.formatted(.number.precision(.fractionLength(0...2)))
    }
    private var detail: String {
        guard let window else { return "Abre Pulso para conectar" }
        if renewalPending { return "Renovación pendiente" }
        return window.displayedUsedPercent.map { "disponible · \($0)% usado" } ?? "consumidos · \(window.title)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.provider.title.uppercased())
                .font(.caption.weight(.semibold)).foregroundStyle(accent)
            Spacer(minLength: 0)
            Text(verbatim: amount)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.65).lineLimit(1)
            Text(verbatim: detail)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let reset = window?.resetsAt {
                Text("Renovación: \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                HStack(spacing: 4) {
                    Text(isStale ? "Sin actualizar" : "Actualizado")
                    Text(snapshot.updatedAt, style: .time)
                }
                .font(.system(size: 10)).foregroundStyle(isStale ? .orange : .secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text("Sin datos").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .containerBackground(Color(red: 0.035, green: 0.045, blue: 0.05), for: .widget)
        .widgetURL(URL(string: "pulso://dashboard"))
    }
}

private func providerConfiguration(_ provider: Provider) -> some WidgetConfiguration {
    StaticConfiguration(kind: "Pulso.\(provider.rawValue)", provider: CachedUsageProvider(provider: provider)) { entry in
        ProviderWidgetView(entry: entry)
    }
    .configurationDisplayName(Text(verbatim: "Pulso · \(provider.title)"))
    .description("Última cuota guardada en el iPhone. Abre Pulso para actualizarla.")
    .supportedFamilies([.systemSmall])
}

private struct CodexWidget: Widget {
    var body: some WidgetConfiguration { providerConfiguration(.codex) }
}

private struct CopilotWidget: Widget {
    var body: some WidgetConfiguration { providerConfiguration(.copilot) }
}

private struct ClaudeWidget: Widget {
    var body: some WidgetConfiguration { providerConfiguration(.claude) }
}

@main
struct PulsoWidgetBundle: WidgetBundle {
    var body: some Widget {
        CodexWidget()
        CopilotWidget()
        ClaudeWidget()
    }
}
