import ActivityKit
import SwiftUI
import WidgetKit

struct PulsoLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: QuotaActivityAttributes.self) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    providerLabel(context.attributes.provider)
                    Spacer()
                    freshness(context)
                }
                if let primary = context.state.primary {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(percent(primary, state: context.state))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(context.state.showsUsed ? String(localized: "usado") : String(localized: "disponible")).font(.caption)
                            Text(primary.kind.title).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                        reset(primary, since: context.state.updatedAt)
                            .font(.caption).frame(maxWidth: 105, alignment: .trailing)
                    }
                    balances(primary, state: context.state).font(.caption2)
                }
                HStack {
                    Text("Última lectura")
                    Text(context.state.updatedAt, style: .time)
                    Spacer()
                    if context.state.windows.count > 1 {
                        Text("+\(context.state.windows.count - 1) cuotas")
                    }
                }
                .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding()
            .activityBackgroundTint(Color(red: 0.035, green: 0.045, blue: 0.05))
            .activitySystemActionForegroundColor(context.attributes.provider.accent)
            .widgetURL(URL(string: "pulso://dashboard"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    providerLabel(context.attributes.provider)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    freshness(context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(Array(context.state.windows.enumerated()), id: \.offset) { _, window in
                            HStack(alignment: .top, spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(window.kind.title).font(.caption.weight(.medium))
                                    balances(window, state: context.state)
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                VStack(alignment: .trailing, spacing: 2) {
                                    Text(percent(window, state: context.state))
                                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                                    Text(context.state.showsUsed ? String(localized: "usado") : String(localized: "disponible"))
                                        .font(.system(size: 9)).foregroundStyle(.secondary)
                                }
                                reset(window, since: context.state.updatedAt)
                                    .font(.system(size: 10)).frame(width: 76, alignment: .trailing)
                            }
                        }
                        HStack(spacing: 4) {
                            Text("Última lectura")
                            Text(context.state.updatedAt, style: .time)
                        }
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                }
            } compactLeading: {
                providerIcon(context.attributes.provider)
                    .frame(width: 18, height: 18)
            } compactTrailing: {
                Text(context.state.primary.map { percent($0, state: context.state) } ?? "—")
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .foregroundStyle(isStale(context) ? .orange : context.attributes.provider.accent)
                    .accessibilityLabel(isStale(context) ? String(localized: "Última lectura sin actualizar") : String(localized: "Cuota"))
            } minimal: {
                providerIcon(context.attributes.provider)
                    .frame(width: 18, height: 18)
            }
            .keylineTint(context.attributes.provider.accent)
            .widgetURL(URL(string: "pulso://dashboard"))
        }
    }

    private func isStale(_ context: ActivityViewContext<QuotaActivityAttributes>) -> Bool {
        context.isStale || context.state.refreshFailed
    }

    private func freshness(_ context: ActivityViewContext<QuotaActivityAttributes>) -> some View {
        Text(isStale(context) ? String(localized: "Sin actualizar · abre PULSO") : String(localized: "Última cuota"))
            .font(.system(size: 10))
            .foregroundStyle(isStale(context) ? .orange : .secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func providerLabel(_ provider: Provider) -> some View {
        HStack(spacing: 5) {
            providerIcon(provider).frame(width: 16, height: 16)
            Text(provider.title).font(.caption.weight(.semibold))
        }
        .foregroundStyle(provider.accent)
    }

    private func providerIcon(_ provider: Provider) -> some View {
        Group {
            if let asset = provider.logoAsset {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: provider.symbol).resizable().scaledToFit()
            }
        }
        .foregroundStyle(provider.accent)
        .accessibilityHidden(true)
    }

    private func percent(_ window: QuotaActivityAttributes.Window,
                         state: QuotaActivityAttributes.ContentState) -> String {
        window.percent(showsUsed: state.showsUsed).map { "\($0)%" } ?? "—"
    }

    private func balances(_ window: QuotaActivityAttributes.Window,
                          state: QuotaActivityAttributes.ContentState) -> some View {
        let isPercent = [.session, .week, .opus, .sonnet].contains(window.kind)
        let used = isPercent ? window.usedPercent.map { "\($0)%" } ?? "—" : window.used.map(creditAmount) ?? "—"
        let remaining = isPercent ? window.remainingPercent.map { "\($0)%" } ?? "—" : window.remaining.map(creditAmount) ?? "—"
        return Text("\(used) usados · \(remaining) restantes")
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    @ViewBuilder private func reset(_ window: QuotaActivityAttributes.Window, since date: Date) -> some View {
        if let reset = window.resetsAt {
            VStack(alignment: .trailing, spacing: 2) {
                Text("Renueva en").foregroundStyle(.secondary)
                Text(timerInterval: min(date, reset)...reset, countsDown: true)
                    .monospacedDigit().multilineTextAlignment(.trailing)
            }
        } else {
            Text("Renovación\nsin fecha").foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
    }
}
