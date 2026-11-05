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
        Task {
            _ = await WidgetQuotaRefresh().refresh(providers: [provider])
            let now = Date()
            let current = entry(at: now)
            var entries = [current]
            // Dated entries update the presentation even if WidgetKit defers the next reload.
            for date in QuotaTimeline.transitionDates(for: current.snapshot, after: now) {
                entries.append(UsageEntry(date: date, provider: provider, snapshot: current.snapshot))
            }
            let reloadAt = now.addingTimeInterval(300)
            WidgetQuotaDiagnostics.timeline(scope: provider.rawValue, requestedAfter: reloadAt, entryCount: entries.count)
            completion(Timeline(entries: entries, policy: .after(reloadAt)))
        }
    }

    private func entry(at date: Date) -> UsageEntry {
        UsageEntry(date: date, provider: provider,
                   snapshot: SnapshotCache.load().first { $0.provider == provider })
    }
}

private struct ProviderWidgetView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family
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
    private var display: QuotaDisplay { SnapshotCache.quotaDisplay }
    private var amount: String {
        guard let window, !renewalPending else { return "—" }
        if let percent = window.displayedPercent(display) { return "\(percent)%" }
        guard window.used.isFinite, window.used >= 0 else { return "—" }
        return window.used.formatted(.number.precision(.fractionLength(0...2)))
    }
    private var detail: String {
        guard let window else { return String(localized: "Abre Pulso para consultar") }
        if renewalPending { return String(localized: "Renovación pendiente") }
        guard let complement = window.complementPercent(display) else { return String(localized: "consumidos · \(window.localizedTitle)") }
        return String(localized: "\(display.headlineNoun) · \(complement)% \(display.complementNoun)")
    }

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                primary
            case .systemMedium:
                HStack(alignment: .top, spacing: 16) {
                    primary.frame(maxWidth: .infinity, alignment: .leading)
                    Divider()
                    details.frame(maxWidth: .infinity, alignment: .leading)
                }
            default:
                VStack(alignment: .leading, spacing: 14) {
                    primary.frame(maxHeight: 160)
                    Divider()
                    details
                    Spacer(minLength: 0)
                }
            }
        }
        .containerBackground(Color(red: 0.035, green: 0.045, blue: 0.05), for: .widget)
        .widgetURL(URL(string: "pulso://dashboard"))
    }

    private var primary: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ProviderLogo(provider: entry.provider, size: 14)
                Text(entry.provider.title.uppercased())
                    .font(.caption.weight(.semibold)).foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.65)
                Spacer(minLength: 0)
                QuotaRefreshButton(target: QuotaRefreshTarget(provider: entry.provider), accent: accent)
            }
            Spacer(minLength: 0)
            Text(verbatim: amount)
                .font(.system(size: 38, weight: .semibold, design: .rounded))
                .minimumScaleFactor(0.65).lineLimit(1)
            Text(verbatim: detail)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            if let reset = window?.resetsAt {
                if reset > entry.date, !renewalPending {
                    HStack(spacing: 3) {
                        Text("Renueva en")
                        QuotaCountdown(provider: entry.provider, start: entry.date, reset: reset)
                            .monospacedDigit()
                    }
                    .font(.system(size: 10)).foregroundStyle(accent)
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .accessibilityLabel("Renovación: \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                }
                Text("\(renewalPending ? String(localized: "Renovación prevista") : String(localized: "Renovación")): \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                    .font(.system(size: 9)).foregroundStyle(.secondary)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer(minLength: 0)
            if let snapshot = entry.snapshot {
                HStack(spacing: 4) {
                    Text(isStale ? String(localized: "Sin actualizar") : String(localized: "Actualizado"))
                    Text(snapshot.updatedAt, style: .time)
                }
                .font(.system(size: 10)).foregroundStyle(isStale ? .orange : .secondary)
                .lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text("Sin datos").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let window, window.id == "copilot_credits" {
                Text("CRÉDITOS DEL MES").font(.caption2.weight(.semibold)).foregroundStyle(accent)
                Text("\(creditAmount(window.used)) consumidos").font(.caption)
                if let limit = window.limit {
                    Text("\(creditAmount(limit)) de límite").font(.caption)
                }
                if let remaining = window.remaining {
                    Text("\(creditAmount(remaining)) restantes").font(.caption)
                }
                if let percent = window.reportedRemainingPercent {
                    Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))% disponible")
                        .font(.caption2).foregroundStyle(accent)
                }
            }
            ForEach(Array((entry.snapshot?.windows.dropFirst() ?? []).prefix(family == .systemMedium ? 1 : 5))) { extra in
                VStack(alignment: .leading, spacing: 4) {
                    Text(extra.localizedTitle).font(.caption.weight(.semibold)).lineLimit(1)
                    if let reset = extra.resetsAt, reset <= entry.date {
                        Text("Renovación pendiente").font(.caption2).foregroundStyle(.orange)
                    } else {
                        Text(extra.displayedPercent(display).map { String(localized: "\($0)% \(display.headlineNoun)") } ?? String(localized: "Cuota desconocida"))
                            .font(.headline).foregroundStyle(accent)
                            .minimumScaleFactor(0.7).lineLimit(1)
                        if let complement = extra.complementPercent(display) {
                            Text("\(complement)% \(display.complementNoun)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        if let reset = extra.resetsAt {
                            QuotaCountdown(provider: entry.provider, start: entry.date, reset: reset)
                                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if entry.snapshot == nil {
                Text("Conecta tu cuenta y consulta la cuota en Pulso.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if entry.snapshot?.windows.count == 1, window?.id != "copilot_credits" {
                Text(window?.localizedTitle ?? String(localized: "Última lectura"))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func providerConfiguration(_ provider: Provider) -> some WidgetConfiguration {
    var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
    if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
    return StaticConfiguration(kind: "Pulso.\(provider.rawValue)", provider: CachedUsageProvider(provider: provider)) { entry in
        ProviderWidgetView(entry: entry)
    }
    .configurationDisplayName(Text(verbatim: "Pulso · \(provider.title)"))
    .description("Consulta la cuota cuando iOS permite actualizar el widget. Conserva la última lectura sin conexión.")
    .supportedFamilies(families)
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
        PulsoSummaryWidget()
        CodexWidget()
        CopilotWidget()
        ClaudeWidget()
        PulsoLiveActivity()
    }
}
