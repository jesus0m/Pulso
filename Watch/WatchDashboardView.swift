import SwiftUI

struct WatchDashboardView: View {
    let store: WatchUsageStore

    var body: some View {
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 60)) { context in
                List {
                    if let state = store.state {
                        if state.isDemo {
                            Text("DEMOSTRACIÓN").font(.caption2).foregroundStyle(.yellow)
                        }
                        if state.visibleProviders.isEmpty {
                            Text("Sin paneles visibles").font(.headline)
                                .accessibilityIdentifier("watch_no_panels")
                            Text("Elige los proveedores en Pulso para iPhone.").font(.caption)
                        }
                        ForEach(state.visibleProviders) { provider in
                            NavigationLink {
                                WatchProviderDetail(store: store, provider: provider)
                            } label: {
                                summary(provider, state: state, now: context.date)
                            }
                            .listRowBackground(provider.accent.opacity(0.10))
                            .accessibilityIdentifier("watch_panel_\(provider.rawValue)")
                        }
                    } else {
                        Label("Tu cuota, en la muñeca", systemImage: "waveform.path.ecg")
                            .font(.headline)
                        Text("Conecta tus cuentas en Pulso para iPhone. Las cuotas se sincronizarán aquí.")
                            .font(.caption)
                            .accessibilityIdentifier("watch_empty")
                    }
                    Section {
                        Button {
                            store.refresh()
                        } label: {
                            Label(store.refreshing ? String(localized: "Sincronizando…") : String(localized: "Sincronizar con iPhone"),
                                  systemImage: "arrow.clockwise")
                        }
                        .disabled(store.refreshing || store.state?.isDemo == true)
                        .accessibilityIdentifier("watch_refresh")
                        Text(store.status).font(.caption2).foregroundStyle(.secondary)
                            .accessibilityIdentifier("watch_sync_status")
                        Text("Sincronizar recibe la lectura guardada y solicita otra al iPhone.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .navigationTitle("PULSO")
            }
        }
    }

    private func summary(_ provider: Provider, state: WatchQuotaState, now: Date) -> some View {
        let snapshot = state.snapshot(for: provider)
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                ProviderMark(provider: provider)
                Text(provider.title).font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(provider.accent)
            if let window = snapshot?.windows.first {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 14) {
                        primaryQuota(window, display: state.quotaDisplay)
                        secondaryQuotas(snapshot?.windows ?? [], display: state.quotaDisplay)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 7) {
                        primaryQuota(window, display: state.quotaDisplay)
                        secondaryQuotas(snapshot?.windows ?? [], display: state.quotaDisplay)
                    }
                }
                if state.isStale(provider, now: now) {
                    Text("Sin actualizar · última lectura").font(.caption2).foregroundStyle(.orange)
                }
                if let reset = window.resetsAt { WatchResetView(reset: reset, now: now) }
                if let snapshot { WatchReadingView(date: snapshot.updatedAt) }
            } else {
                Text(state.failedProviders.contains(provider) ? String(localized: "No se pudo consultar la cuota. Abre Pulso en el iPhone.")
                     : String(localized: "Sin lectura. Abre Pulso en el iPhone."))
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    private func primaryQuota(_ window: UsageWindow, display: QuotaDisplay) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(window.displayedPercent(display).map { "\($0)%" } ?? creditAmount(window.used))
                .font(.system(.largeTitle, design: .rounded).weight(.light))
                .monospacedDigit()
            Text(window.displayedPercent(display) == nil ? String(localized: "consumidos") : display.headlineNoun)
                .font(.caption2).foregroundStyle(.secondary)
            Text(window.localizedTitle).font(.caption2).foregroundStyle(.secondary)
        }
    }

    private func secondaryQuotas(_ windows: [UsageWindow], display: QuotaDisplay) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(windows.dropFirst())) { window in
                VStack(alignment: .leading, spacing: 2) {
                    Text(window.localizedTitle).font(.caption2).foregroundStyle(.secondary)
                    Text(window.displayedPercent(display).map { "\($0)%" } ?? creditAmount(window.used))
                        .font(.title3).monospacedDigit()
                    Text(window.displayedPercent(display) == nil ? String(localized: "consumidos") : display.headlineNoun)
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            if let credits = windows.first, credits.id == "copilot_credits", let remaining = credits.remaining {
                VStack(alignment: .leading, spacing: 2) {
                    Text(creditAmount(remaining)).font(.title3).monospacedDigit()
                    Text("créditos restantes").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct WatchProviderDetail: View {
    let store: WatchUsageStore
    let provider: Provider

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let state = store.state {
                        if state.isDemo {
                            Text("DEMOSTRACIÓN").font(.caption2).foregroundStyle(.yellow)
                        }
                        if let snapshot = state.snapshot(for: provider) {
                            ForEach(snapshot.windows) { window in
                                WatchWindowView(window: window, display: state.quotaDisplay, now: context.date)
                            }
                            if snapshot.windows.isEmpty {
                                Text("No hay ventanas de cuota en la última lectura.").font(.caption)
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                if state.isStale(provider, now: context.date) {
                                    Text("Sin actualizar · última lectura").foregroundStyle(.orange)
                                }
                                WatchReadingView(date: snapshot.updatedAt)
                                Text("El contador indica la renovación prevista; no actualiza la cuota.")
                                    .foregroundStyle(.secondary)
                            }.font(.caption2)
                        } else {
                            Text("Abre Pulso en el iPhone para conectar esta cuenta o consultar la cuota.")
                                .font(.caption)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.bottom)
            }
            .navigationTitle(provider.title)
            .tint(provider.accent)
            .foregroundStyle(.white)
            .accessibilityIdentifier("watch_detail_\(provider.rawValue)")
        }
    }
}

private struct WatchWindowView: View {
    let window: UsageWindow
    let display: QuotaDisplay
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(window.localizedTitle).font(.headline)
                .accessibilityIdentifier("watch_window_\(window.id)")
            Text(window.displayedPercent(display).map { "\($0)%" } ?? creditAmount(window.used))
                .font(.system(.largeTitle, design: .rounded).weight(.light))
                .monospacedDigit()
                .accessibilityIdentifier("watch_quota_\(window.id)")
            Text(window.displayedPercent(display) == nil ? String(localized: "Consumido · cuota desconocida") : display.headline)
                .font(.caption2).foregroundStyle(.secondary)
            if let percent = window.displayedPercent(display) {
                ProgressView(value: Double(percent), total: 100).accessibilityHidden(true)
            }
            if let complement = window.complementPercent(display) {
                Text("\(complement)% \(display.complementNoun)").font(.caption)
            }
            if window.id == "copilot_credits" {
                Text("\(creditAmount(window.used)) consumidos").font(.caption)
                    .accessibilityIdentifier("watch_credits_consumed")
                if let limit = window.limit {
                    Text("\(creditAmount(limit)) de límite mensual").font(.caption)
                        .accessibilityIdentifier("watch_credits_limit")
                }
                if let remaining = window.remaining {
                    Text("\(creditAmount(remaining)) restantes").font(.caption)
                        .accessibilityIdentifier("watch_credits_remaining")
                }
                if let percent = window.reportedRemainingPercent {
                    Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))% disponible").font(.caption)
                        .accessibilityIdentifier("watch_credits_reported_percent")
                }
            }
            if let reset = window.resetsAt {
                WatchResetView(reset: reset, now: now)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct WatchReadingView: View {
    let date: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Última lectura")
            Text("\(date, style: .date) · \(date, style: .time)")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("watch_last_reading")
    }
}

private struct WatchResetView: View {
    let reset: Date
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if reset > now {
                Text("Renueva en")
                Text(timerInterval: now...reset, countsDown: true)
                    .monospacedDigit()
            } else {
                Text("Renovación pendiente de confirmar")
                    .foregroundStyle(.orange)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .accessibilityElement(children: .combine)
    }
}

private struct ProviderMark: View {
    let provider: Provider

    var body: some View {
        Group {
            if let asset = provider.logoAsset {
                Image(asset).resizable().scaledToFit()
            } else {
                Image(systemName: provider.symbol).resizable().scaledToFit()
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}
