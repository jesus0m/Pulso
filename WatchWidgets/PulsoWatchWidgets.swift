import SwiftUI
import WidgetKit

private struct WatchQuotaEntry: TimelineEntry {
    let date: Date
    let provider: Provider
    let state: WatchQuotaState?

    var snapshot: UsageSnapshot? {
        guard state?.visibleProviders.contains(provider) == true else { return nil }
        return state?.snapshot(for: provider)
    }

    var window: UsageWindow? { snapshot?.windows.first }
    var display: QuotaDisplay { state?.quotaDisplay ?? .remaining }
    var isDemo: Bool { state?.isDemo == true }
    var isStale: Bool { state?.isStale(provider, now: date) ?? true }
    var resetPending: Bool {
        snapshot?.windows.contains { ($0.resetsAt ?? .distantFuture) <= date } ?? false
    }

    var value: String {
        guard let window else { return "—" }
        return window.displayedPercent(display).map { "\($0)%" } ?? creditAmount(window.used)
    }

    var noun: String {
        window?.displayedPercent(display) == nil ? String(localized: "consumidos") : display.headlineNoun
    }

    var shortName: String { provider == .copilot ? "Copilot" : provider.title }

    var readingDescription: String {
        guard let snapshot, window != nil else { return String(localized: "\(provider.title). Sin lectura. Abre Pulso en el iPhone.") }
        let status = resetPending ? String(localized: "Renovación pendiente de confirmar.") : isStale ? String(localized: "Sin actualizar.") : ""
        let reading = snapshot.updatedAt.formatted(date: .abbreviated, time: .shortened)
        return String(localized: "\(isDemo ? String(localized: "Demostración. ") : "")\(provider.title). \(value) \(noun). \(status) Última lectura: \(reading).")
    }
}

private struct WatchQuotaTimeline: TimelineProvider {
    let provider: Provider

    func placeholder(in context: Context) -> WatchQuotaEntry {
        WatchQuotaEntry(date: .now, provider: provider, state: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (WatchQuotaEntry) -> Void) {
        completion(WatchQuotaEntry(date: .now, provider: provider, state: WatchQuotaCache().load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchQuotaEntry>) -> Void) {
        let now = Date()
        let state = WatchQuotaCache().load()
        var dates = [now]
        if state?.visibleProviders.contains(provider) == true, let snapshot = state?.snapshot(for: provider) {
            // Schedule known transitions even if the system defers the next cache reload.
            let staleAt = snapshot.updatedAt.addingTimeInterval(300.001)
            if staleAt > now { dates.append(staleAt) }
            dates.append(contentsOf: snapshot.windows.compactMap(\.resetsAt).filter { $0 > now })
        }
        let entries = Set(dates).sorted().map {
            WatchQuotaEntry(date: $0, provider: provider, state: state)
        }
        completion(Timeline(entries: entries, policy: .after(now.addingTimeInterval(900))))
    }
}

private struct WatchQuotaWidgetView: View {
    let entry: WatchQuotaEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular:
                circular
            case .accessoryInline:
                inline
            default:
                rectangular
            }
        }
        .containerBackground(for: .widget) { Color.black }
        .widgetAccentable()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.readingDescription)
    }

    private var rectangular: some View {
        Group {
            if entry.window != nil {
                ViewThatFits(in: .vertical) {
                    rectangularContent(expanded: true)
                        .fixedSize(horizontal: false, vertical: true)
                    rectangularContent(expanded: false)
                }
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    Label(entry.shortName, systemImage: entry.provider.symbol)
                        .font(.headline)
                    Text("Sin lectura").font(.caption)
                    Text("Abre Pulso en el iPhone").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func rectangularContent(expanded: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Image(systemName: entry.provider.symbol)
                Text(entry.shortName)
                if entry.isDemo { Text("DEMO") }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(entry.provider.accent)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(entry.value)
                    .font(.system(expanded ? .title2 : .headline, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                Text(entry.noun).font(.caption2)
            }
            if expanded {
                expandedSecondary
            } else {
                compactSecondary
            }
            status
            if expanded, let reset = entry.window?.resetsAt, reset > entry.date, !entry.resetPending {
                HStack(spacing: 3) {
                    Text("Renueva en")
                    Text(timerInterval: entry.date...reset, countsDown: true).monospacedDigit()
                }
                .font(.caption2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .lineLimit(1)
    }

    @ViewBuilder
    private var expandedSecondary: some View {
        if let snapshot = entry.snapshot {
            ForEach(Array(snapshot.windows.dropFirst())) { window in
                Text("\(window.localizedTitle) · \(window.displayedPercent(entry.display).map { String(localized: "\($0)% \(entry.display.headlineNoun)") } ?? String(localized: "\(creditAmount(window.used)) consumidos"))")
                    .font(.caption2)
            }
        }
        if let credits = entry.window, credits.id == "copilot_credits" {
            Text("\(creditAmount(credits.used)) consumidos").font(.caption2)
            if let limit = credits.limit {
                Text("\(creditAmount(limit)) de límite mensual").font(.caption2)
            }
            if let remaining = credits.remaining {
                Text("\(creditAmount(remaining)) restantes").font(.caption2)
            }
            if let percent = credits.reportedRemainingPercent {
                Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))% disponible")
                    .font(.caption2)
            }
        }
    }

    @ViewBuilder
    private var compactSecondary: some View {
        if let week = entry.snapshot?.windows.dropFirst().first {
            Text("\(week.localizedTitle) · \(week.displayedPercent(entry.display).map { "\($0)%" } ?? creditAmount(week.used))")
                .font(.caption2)
        } else if let credits = entry.window, credits.id == "copilot_credits", let remaining = credits.remaining {
            Text("\(creditAmount(remaining)) restantes").font(.caption2)
        }
    }

    @ViewBuilder
    private var status: some View {
        if entry.resetPending {
            Text("Renovación pendiente").font(.caption2).foregroundStyle(.secondary)
        } else if entry.isStale {
            if let reading = entry.snapshot?.updatedAt {
                Text("Anterior · \(reading, style: .date)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        } else if let reading = entry.snapshot?.updatedAt {
            Text("Lectura · \(reading, style: .time)")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    private var circular: some View {
        Group {
            if let percent = entry.window?.displayedPercent(entry.display) {
                Gauge(value: Double(percent), in: 0...100) {
                    Text(entry.isDemo ? "DEMO" : entry.resetPending ? String(localized: "Pendiente") : entry.isStale ? String(localized: "Anterior") : entry.shortName)
                } currentValueLabel: {
                    VStack(spacing: 0) {
                        Text(entry.value).font(.headline).monospacedDigit()
                        Text(entry.display == .used ? String(localized: "usado") : String(localized: "disp.")).font(.caption2)
                    }
                }
                .gaugeStyle(.accessoryCircular)
                .tint(entry.provider.accent)
            } else if entry.window != nil {
                VStack(spacing: 1) {
                    Image(systemName: entry.provider.symbol)
                    Text(entry.value).font(.caption2).monospacedDigit()
                    Text("consumidos").font(.caption2)
                }
            } else {
                VStack(spacing: 2) {
                    Image(systemName: "iphone")
                    Text("Sin lectura").font(.caption2)
                }
            }
        }
    }

    private var inline: some View {
        Group {
            if entry.window != nil {
                Text("\(entry.isDemo ? String(localized: "Demo · ") : "")\(entry.shortName) \(entry.value) \(entry.noun)\(entry.resetPending ? String(localized: " · renovación pendiente") : entry.isStale ? String(localized: " · anterior") : "")")
            } else {
                Text("\(entry.shortName) · sin lectura")
            }
        }
    }
}

private func quotaConfiguration(for provider: Provider) -> some WidgetConfiguration {
    StaticConfiguration(kind: "pulso.watch.\(provider.rawValue)", provider: WatchQuotaTimeline(provider: provider)) { entry in
        WatchQuotaWidgetView(entry: entry)
    }
    .configurationDisplayName(Text(verbatim: "\(provider.title) · Pulso"))
    .description("Última cuota del iPhone. Sigue la selección de usado o disponible de Pulso.")
    .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
}

private struct CodexWatchWidget: Widget {
    var body: some WidgetConfiguration { quotaConfiguration(for: .codex) }
}

private struct CopilotWatchWidget: Widget {
    var body: some WidgetConfiguration { quotaConfiguration(for: .copilot) }
}

private struct ClaudeWatchWidget: Widget {
    var body: some WidgetConfiguration { quotaConfiguration(for: .claude) }
}

@main
struct PulsoWatchWidgets: WidgetBundle {
    var body: some Widget {
        CodexWatchWidget()
        CopilotWatchWidget()
        ClaudeWatchWidget()
    }
}
