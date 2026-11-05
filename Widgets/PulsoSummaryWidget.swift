import SwiftUI
import WidgetKit

private struct SummaryEntry: TimelineEntry {
    let date: Date
    let state: SummaryWidgetState
}

private struct CachedSummaryProvider: TimelineProvider {
    func placeholder(in context: Context) -> SummaryEntry {
        SummaryEntry(date: Date(), state: SummaryWidgetState(snapshots: [], display: .remaining))
    }

    func getSnapshot(in context: Context, completion: @escaping (SummaryEntry) -> Void) {
        completion(entry(at: Date()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SummaryEntry>) -> Void) {
        Task {
            _ = await WidgetQuotaRefresh().refresh()
            let now = Date()
            let current = entry(at: now)
            let dates = [now] + current.state.transitionDates(after: now)
            let entries = dates.map { SummaryEntry(date: $0, state: current.state) }
            let reloadAt = now.addingTimeInterval(300)
            WidgetQuotaDiagnostics.timeline(scope: "summary", requestedAfter: reloadAt, entryCount: entries.count)
            completion(Timeline(entries: entries, policy: .after(reloadAt)))
        }
    }

    private func entry(at date: Date) -> SummaryEntry {
        SummaryEntry(date: date, state: SummaryWidgetState(
            snapshots: SnapshotCache.load(), display: SnapshotCache.quotaDisplay
        ))
    }
}

struct PulsoSummaryWidget: Widget {
    var body: some WidgetConfiguration {
        var families: [WidgetFamily] = [.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge]
        if #available(iOS 27.0, *) { families.append(.systemExtraLargePortrait) }
        return StaticConfiguration(kind: "Pulso.summary", provider: CachedSummaryProvider()) { entry in
            SummaryWidgetView(entry: entry)
        }
        .configurationDisplayName("Resumen de Pulso")
        .description("Codex, Copilot y Claude se consultan cuando iOS permite actualizar. Conserva la última lectura sin conexión.")
        .supportedFamilies(families)
    }
}

private struct SummaryWidgetView: View {
    let entry: SummaryEntry
    @Environment(\.widgetFamily) private var family
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: family == .systemSmall ? 6 : 10) {
                header
                if family == .systemSmall {
                    compactRows
                } else if family == .systemMedium {
                    if dynamicTypeSize.isAccessibilitySize || geometry.size.height < 120 {
                        compactRows
                    } else {
                        columns
                    }
                } else if dynamicTypeSize.isAccessibilitySize && geometry.size.height < 400 {
                    compactRows
                } else {
                    detailedRows(size: geometry.size)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .containerBackground(.black, for: .widget)
        .widgetURL(URL(string: "pulso://dashboard"))
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text("PULSO")
                .font(.caption2.weight(.bold)).tracking(1.5)
                .foregroundStyle(Provider.codex.accent)
            Spacer(minLength: 0)
            QuotaRefreshButton(target: .summary, accent: Provider.codex.accent,
                               showsTitle: family != .systemSmall && !dynamicTypeSize.isAccessibilitySize)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
    }

    private var compactRows: some View {
        VStack(spacing: 0) {
            ForEach(entry.state.readings) { reading in
                HStack(spacing: 7) {
                    ProviderLogo(provider: reading.provider, size: 17)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(shortTitle(reading.provider))
                            .font(.caption.weight(.semibold))
                        readingDate(reading, compact: true)
                    }
                    Spacer(minLength: 2)
                    valueText(reading.value(for: reading.windows.first, display: entry.state.display))
                        .font(.system(.headline, design: .rounded).weight(.semibold))
                        .foregroundStyle(reading.provider.accent)
                }
                .lineLimit(1).minimumScaleFactor(0.65)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(compactAccessibilityLabel(reading))
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(entry.state.readings) { reading in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        ProviderLogo(provider: reading.provider, size: 14)
                        Text(shortTitle(reading.provider))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(reading.provider.accent)
                    valueText(reading.value(for: reading.windows.first, display: entry.state.display))
                        .font(.system(.title2, design: .rounded).weight(.semibold))
                    Text(reading.windows.first?.localizedTitle ?? String(localized: "Sin lectura"))
                        .font(.caption2).foregroundStyle(.secondary)
                    if let window = reading.windows.first {
                        resetLabel(window, provider: reading.provider, detailed: false)
                    }
                    Spacer(minLength: 0)
                    readingDate(reading, compact: false)
                }
                .lineLimit(1).minimumScaleFactor(0.7)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
    }

    private func detailedRows(size: CGSize) -> some View {
        let spacious = size.height > 450
        let wide = size.width > 500
        let windowLimit = spacious ? 4 : 2
        return VStack(alignment: .leading, spacing: spacious ? 16 : 10) {
            ForEach(entry.state.readings) { reading in
                VStack(alignment: .leading, spacing: spacious ? 10 : 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label {
                            Text(reading.provider.title)
                        } icon: {
                            ProviderLogo(provider: reading.provider)
                        }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(reading.provider.accent)
                        Spacer(minLength: 0)
                        readingDate(reading, compact: false)
                    }
                    .lineLimit(1).minimumScaleFactor(0.7)
                    if reading.windows.isEmpty {
                        Text("Sin lectura · Abre Pulso para consultar")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading),
                                                 count: wide ? min(windowLimit, reading.windows.count) : 2),
                                  alignment: .leading, spacing: 10) {
                            ForEach(Array(reading.windows.prefix(windowLimit))) { window in
                                windowDetail(window, reading: reading, spacious: spacious)
                            }
                        }
                        if let credits = reading.windows.first(where: { $0.id == "copilot_credits" }) {
                            creditBalances(credits, accent: reading.provider.accent)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                if reading.provider != entry.state.readings.last?.provider {
                    Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                        .accessibilityHidden(true)
                }
            }
        }
    }

    private func windowDetail(_ window: UsageWindow, reading: SummaryProviderReading,
                              spacious: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacious ? 5 : 2) {
            Text(window.localizedTitle).font(.caption2).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                valueText(reading.value(for: window, display: entry.state.display))
                    .font(.system(spacious ? .title2 : .headline, design: .rounded).weight(.semibold))
                    .foregroundStyle(reading.provider.accent)
                if spacious {
                    Text(entry.state.display.headlineNoun).font(.caption2).foregroundStyle(.secondary)
                }
            }
            if spacious, let complement = window.complementPercent(entry.state.display) {
                Text("\(complement)% \(entry.state.display.complementNoun)")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            resetLabel(window, provider: reading.provider, detailed: spacious)
        }
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func creditBalances(_ window: UsageWindow, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(validAmount(window.used)) usados · \(validAmount(window.limit)) de límite")
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Text("\(validAmount(window.remaining)) restantes")
                if let percent = window.reportedRemainingPercent,
                   percent.isFinite, (0...100).contains(percent) {
                    Text("\(creditAmount(percent))% disponible")
                        .foregroundStyle(accent)
                }
            }
            .foregroundStyle(.secondary)
        }
        .font(.caption2).lineLimit(1).minimumScaleFactor(0.65)
    }

    @ViewBuilder
    private func resetLabel(_ window: UsageWindow, provider: Provider, detailed: Bool) -> some View {
        if let reset = window.resetsAt {
            if reset <= entry.date {
                Text("Renovación pendiente")
                    .font(.caption2).foregroundStyle(.orange)
            } else {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.clockwise").accessibilityHidden(true)
                    QuotaCountdown(provider: provider, start: entry.date, reset: reset)
                        .monospacedDigit()
                }
                .font(.caption2).foregroundStyle(provider.accent)
                .accessibilityLabel("Renovación: \(reset.formatted(.dateTime.day().month(.abbreviated).hour().minute()))")
                if detailed {
                    Text(reset, format: .dateTime.day().month(.abbreviated).hour().minute())
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        } else {
            Text("Sin fecha de renovación").font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func readingDate(_ reading: SummaryProviderReading, compact: Bool) -> some View {
        if let updatedAt = reading.updatedAt {
            HStack(spacing: 3) {
                if reading.isStale(at: entry.date) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .accessibilityHidden(true)
                    if !compact { Text("Sin actualizar") }
                } else if !compact {
                    Text("Lectura")
                }
                Text(updatedAt, style: .time)
            }
            .font(.caption2)
            .foregroundStyle(reading.isStale(at: entry.date) ? Color.orange : Color.secondary)
            .accessibilityLabel("Última lectura: \(updatedAt.formatted(.dateTime.day().month().hour().minute()))\(reading.isStale(at: entry.date) ? String(localized: ", sin actualizar") : "")")
        } else {
            Text("Sin lectura").font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func valueText(_ value: SummaryQuotaValue) -> Text {
        Text(verbatim: valueString(value))
    }

    private func valueString(_ value: SummaryQuotaValue) -> String {
        switch value {
        case .percent(let percent): return "\(percent)%"
        case .amount(let amount): return creditAmount(amount)
        case .unavailable: return String(localized: "Sin datos")
        }
    }

    private func validAmount(_ amount: Double?) -> String {
        guard let amount, amount.isFinite, amount >= 0 else { return "—" }
        return creditAmount(amount)
    }

    private func shortTitle(_ provider: Provider) -> String {
        provider == .copilot ? "Copilot" : provider.title
    }

    private func compactAccessibilityLabel(_ reading: SummaryProviderReading) -> String {
        let value = reading.value(for: reading.windows.first, display: entry.state.display)
        let quota = value == .unavailable ? String(localized: "Cuota desconocida") :
            String(localized: "\(valueString(value)) \(entry.state.display.headlineNoun)")
        guard let updatedAt = reading.updatedAt else {
            return String(localized: "\(reading.provider.title), \(quota), sin lectura")
        }
        return String(localized: "\(reading.provider.title), \(quota), última lectura \(updatedAt.formatted(.dateTime.day().month().hour().minute()))\(reading.isStale(at: entry.date) ? String(localized: ", sin actualizar") : "")")
    }
}
