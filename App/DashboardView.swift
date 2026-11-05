import SwiftUI

struct DashboardView: View {
    @Bindable var store: UsageStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showingConnections = false

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height && !dynamicTypeSize.isAccessibilitySize
            VStack(spacing: 0) {
                header
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    ScrollView {
                        VStack(alignment: .leading, spacing: landscape ? 16 : 32) {
                            #if DEBUG
                            if store.demo {
                                Label("DEMOSTRACIÓN · datos de ejemplo", systemImage: "eye")
                                    .font(.caption.weight(.semibold)).foregroundStyle(.yellow)
                                    .accessibilityIdentifier("demoBanner")
                            }
                            #endif
                            if store.visibleProviders.isEmpty {
                                ContentUnavailableView {
                                    Label("Sin paneles visibles", systemImage: "rectangle.slash")
                                } description: {
                                    Text("Tus cuentas siguen conectadas. Elige qué paneles quieres mostrar.")
                                } actions: {
                                    Button("Elegir paneles") { showingConnections = true }
                                }
                            } else if landscape {
                                HStack(alignment: .top, spacing: 24) {
                                    ForEach(store.visibleProviders) { provider in
                                        providerPanel(provider, now: context.date, compact: true)
                                    }
                                }
                            } else {
                                VStack(spacing: 32) {
                                    ForEach(store.visibleProviders) { provider in
                                        providerPanel(provider, now: context.date, compact: false)
                                            .padding(.bottom, 24)
                                            .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.12)).frame(height: 1) }
                                    }
                                }
                            }
                            if !store.deskMode {
                                footer
                            }
                        }
                        .padding(.horizontal, landscape ? 36 : 28)
                        .padding(.vertical, landscape ? 16 : 28)
                    }
                }
            }
            .background(Color.black)
            .foregroundStyle(store.nightMode ? Color(red: 0.85, green: 0.25, blue: 0.2) : .white)
            .sheet(isPresented: $showingConnections) { ConnectionsView(store: store) }
            .statusBarHidden(store.deskMode)
            .persistentSystemOverlays(store.deskMode ? .hidden : .automatic)
            .onChange(of: store.deskMode) { _, _ in updateIdleTimer() }
            .onChange(of: scenePhase) { _, _ in updateIdleTimer() }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                updateIdleTimer()
                while !Task.isCancelled {
                    await store.refresh()
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                }
            }
            .onOpenURL { url in
                if url.scheme == "pulso" { showingConnections = url.host != "dashboard" }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg").font(.title3.weight(.medium))
                Text("PULSO").font(.system(.headline, design: .rounded).weight(.bold)).tracking(3)
            }
            Spacer()
            Button { Task { await store.refresh() } } label: {
                if store.refreshing { ProgressView().controlSize(.small) }
                else { Image(systemName: "arrow.clockwise") }
            }
            .frame(width: 44, height: 44)
            .disabled(store.refreshing || store.demo)
            .accessibilityLabel("Actualizar cuotas")
            Button {
                store.deskMode.toggle()
            } label: {
                Image(systemName: store.deskMode ? "display" : "display.and.arrow.down")
                    .frame(width: 44, height: 44)
                    .foregroundStyle(store.deskMode ? .mint : .secondary)
            }
            .accessibilityLabel(store.deskMode ? String(localized: "Desactivar modo escritorio") : String(localized: "Activar modo escritorio"))
            .accessibilityIdentifier("deskModeButton")
            Button { showingConnections = true } label: {
                Image(systemName: "slider.horizontal.3").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Conexiones y ajustes")
            .accessibilityIdentifier("settingsButton")
        }
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .padding(.leading, 28).padding(.trailing, 16).padding(.top, 8)
    }

    private func providerPanel(_ provider: Provider, now: Date, compact: Bool) -> some View {
        let snapshot = store.snapshot(for: provider)
        let window = snapshot?.windows.first
        let isCreditQuota = provider == .copilot && window?.id == "copilot_credits"
        let consumed = window.map { creditAmount($0.used) } ?? "—"
        let approximation = store.organizationPlan && !isCreditQuota && window?.limit != nil ? "≈ " : ""
        let consumedAmount = approximation + consumed
        let copilotDetail = !isCreditQuota ? window?.displayedUsedPercent.map {
            String(localized: "\(consumedAmount) consumidos · \($0)% de la cuota")
        } ?? String(localized: "\(consumedAmount) consumidos") : String(localized: "\(consumedAmount) consumidos")
        let stale = snapshot.map { now.timeIntervalSince($0.updatedAt) > 300 || $0.windows.contains { ($0.resetsAt ?? .distantFuture) <= now } || store.errors[provider] != nil } ?? false
        let accent = store.nightMode ? Color(red: 0.85, green: 0.25, blue: 0.2) : provider.accent
        return VStack(alignment: .leading, spacing: compact ? 12 : 20) {
            HStack(alignment: .center, spacing: 10) {
                Group {
                    if let logo = provider.logoAsset {
                        Image(logo).resizable().scaledToFit().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: provider.symbol)
                    }
                }
                .foregroundStyle(accent)
                Text(provider.title).font(compact ? .headline : .title3.weight(.medium))
                Spacer(minLength: 2)
            }
            if let window {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(window.displayedPercent(store.quotaDisplay).map(String.init)
                         ?? (provider == .copilot ? window.used.formatted(.number.precision(.fractionLength(0...1))) : "—"))
                        .font(.system(size: compact ? 62 : 88, weight: .light, design: .rounded))
                        .monospacedDigit().tracking(-3).minimumScaleFactor(0.5).lineLimit(1)
                        .accessibilityIdentifier("quota_\(provider.rawValue)")
                    if window.displayedPercent(store.quotaDisplay) != nil {
                        Text("%").font(.system(size: 28, weight: .light)).foregroundStyle(accent)
                    }
                    Spacer(minLength: 0)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(window.displayedPercent(store.quotaDisplay).map { String(localized: "\($0) por ciento \(store.quotaDisplay.headlineNoun); \(window.complementPercent(store.quotaDisplay) ?? 0) por ciento \(store.quotaDisplay.complementNoun)") } ?? String(localized: "\(window.used.formatted()) consumidos; cuota restante desconocida"))
                VStack(alignment: .leading, spacing: 10) {
                    informationRow(stacked: compact) {
                        Text(window.displayedPercent(store.quotaDisplay) == nil ? String(localized: "CONSUMIDO · CUOTA DESCONOCIDA") : store.quotaDisplay.headline)
                            .font(.caption2.weight(.semibold)).tracking(2)
                    } trailing: {
                        Text(window.localizedTitle).font(.caption).foregroundStyle(.secondary)
                    }
                    if let filled = window.displayedPercent(store.quotaDisplay) {
                        GeometryReader { proxy in
                            ZStack(alignment: .leading) {
                                Capsule().fill(accent.opacity(0.12))
                                Capsule().fill(accent).frame(width: max(0, proxy.size.width * Double(filled) / 100))
                            }
                        }.frame(height: 4).accessibilityHidden(true)
                    }
                    informationRow(stacked: compact) {
                        Text(provider == .copilot
                             ? copilotDetail
                             : window.complementPercent(store.quotaDisplay).map { String(localized: "\($0)% \(store.quotaDisplay.complementNoun)") } ?? String(localized: "Consumo desconocido"))
                            .accessibilityIdentifier("used_\(provider.rawValue)")
                    } trailing: {
                        if let reset = window.resetsAt {
                            Text(reset > now ? String(localized: "Renueva \(reset.formatted(.relative(presentation: .numeric)))") : String(localized: "Renovación pendiente"))
                        }
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    if isCreditQuota {
                        if let limit = window.limit {
                            Text("\(creditAmount(limit)) de límite mensual")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        informationRow(stacked: compact) {
                            if let remaining = window.remaining {
                                Text("\(creditAmount(remaining)) restantes")
                            }
                        } trailing: {
                            if let percent = window.reportedRemainingPercent {
                                Text("\(percent.formatted(.number.precision(.fractionLength(0...1))))% disponible")
                            }
                        }
                        .font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(snapshot?.windows.dropFirst().map { $0 } ?? []) { extra in
                    VStack(alignment: .leading, spacing: 5) {
                        informationRow(stacked: compact) {
                            Text(extra.localizedTitle)
                        } trailing: {
                            Text(extra.displayedPercent(store.quotaDisplay).map { String(localized: "\($0)% \(store.quotaDisplay.headlineNoun) · \(extra.complementPercent(store.quotaDisplay) ?? 0)% \(store.quotaDisplay.complementNoun)") } ?? String(localized: "Sin cuota"))
                                .foregroundStyle(accent)
                        }.font(.subheadline)
                        if let reset = extra.resetsAt {
                            Text(reset > now ? String(localized: "Renueva \(reset.formatted(.relative(presentation: .numeric)))") : String(localized: "Renovación pendiente · última lectura"))
                                .font(.caption).foregroundStyle(reset > now ? Color.secondary : .orange)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 5) {
                    Text(stale ? String(localized: "Sin actualizar · última lectura \(snapshot!.updatedAt.formatted(date: .omitted, time: .shortened))") : String(localized: "Lectura \(snapshot!.updatedAt.formatted(date: .omitted, time: .shortened))"))
                        .foregroundStyle(stale ? .orange : .secondary)
                    if provider == .copilot && !store.organizationPlan {
                        Text("Informe de facturación; puede llevar retraso.").foregroundStyle(.secondary)
                    }
                }.font(.caption2)
            } else {
                Text("—").font(.system(size: compact ? 62 : 88, weight: .ultraLight, design: .rounded)).foregroundStyle(accent.opacity(0.6))
                Text(provider == .copilot && store.githubConfigured ? String(localized: "Cuenta guardada · sin lectura de cuota") : String(localized: "Tu cuota, a un vistazo."))
                    .font(.subheadline).foregroundStyle(.secondary)
                Button { showingConnections = true } label: {
                    Label(provider == .copilot && store.githubConfigured ? String(localized: "Revisar Copilot") : String(localized: "Conectar \(provider.title)"), systemImage: "plus")
                        .font(.subheadline.weight(.medium)).foregroundStyle(accent)
                        .padding(.vertical, 12)
                }
            }
            if !store.demo, let error = store.errors[provider] {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("panel_\(provider.rawValue)")
    }

    @ViewBuilder
    private func informationRow<Leading: View, Trailing: View>(
        stacked: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        if stacked || dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                leading()
                trailing()
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            HStack {
                leading()
                Spacer()
                trailing()
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "arrow.clockwise").font(.caption2)
                Text("Consulta cada minuto con la app abierta")
            }.font(.caption2).foregroundStyle(.secondary)
            #if DEBUG
            if store.demo {
                Button("Salir de la demostración") { store.demo = false }
                    .font(.subheadline).accessibilityIdentifier("exitDemoButton")
            } else if store.snapshots.isEmpty {
                Button("Ver una demostración") { store.demo = true }
                    .font(.subheadline).accessibilityIdentifier("demoButton")
            }
            #endif
        }
    }

    private func updateIdleTimer() {
        UIApplication.shared.isIdleTimerDisabled = store.deskMode && scenePhase == .active
    }
}
