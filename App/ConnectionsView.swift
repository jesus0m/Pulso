import SwiftUI

struct ConnectionsView: View {
    @Bindable var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var githubDraft = UsageStore.GitHubDraft()
    @State private var showingClaude = false
    @State private var claudeEmail = ""
    @State private var enteringClaudeEmail = true
    @State private var saving = false
    @State private var disconnecting = false
    @State private var confirmDisconnect: Provider?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Tus cuentas. Solo en tu iPhone.").font(.title2.weight(.medium))
                    Text("Las credenciales permanecen en el dispositivo. PULSO no necesita un servidor ni un Mac.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Section("Paneles visibles") {
                    ForEach(store.providerOrder) { provider in
                        HStack(spacing: 4) {
                            Toggle(provider.title, isOn: Binding(
                                get: { store.isProviderVisible(provider) },
                                set: { store.setProviderVisible(provider, $0) }
                            ))
                            .accessibilityIdentifier("visible_\(provider.rawValue)")
                            Button { store.moveProvider(provider, by: -1) } label: {
                                Image(systemName: "chevron.up").frame(width: 32, height: 32)
                            }
                            .disabled(!store.canMoveProvider(provider, by: -1))
                            .accessibilityLabel("Subir \(provider.title)")
                            .accessibilityIdentifier("moveUp_\(provider.rawValue)")
                            Button { store.moveProvider(provider, by: 1) } label: {
                                Image(systemName: "chevron.down").frame(width: 32, height: 32)
                            }
                            .disabled(!store.canMoveProvider(provider, by: 1))
                            .accessibilityLabel("Bajar \(provider.title)")
                            .accessibilityIdentifier("moveDown_\(provider.rawValue)")
                        }
                        .buttonStyle(.borderless)
                    }
                    Text("El orden y la selección se recuerdan en este iPhone. Ocultar un panel conserva su cuenta y su última lectura. El widget resumen y el Apple Watch siguen esa selección; los widgets individuales siguen disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Conexión", value: store.codexConfigured ? String(localized: "Sesión guardada") : String(localized: "Sin conectar"))
                    if let account = store.codex.accountLabel {
                        LabeledContent("Cuenta de ChatGPT", value: account)
                    }
                    Text("La cifra grande es lo disponible; el porcentaje usado se muestra debajo, como en los IDEs. Compara la misma cuenta y hora de lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button(store.codex.isSigningIn ? String(localized: "Esperando a ChatGPT…") : String(localized: "Entrar con ChatGPT")) {
                        Task { await store.signInCodex() }
                    }
                    .disabled(store.codex.isSigningIn || disconnecting)
                    .accessibilityIdentifier("codexNativeSignIn")
                    if store.codex.isSigningIn {
                        Button("Cancelar inicio de sesión") { store.codex.cancelSignIn() }
                    }
                    Button("Borrar sesión de Codex", role: .destructive) { confirmDisconnect = .codex }
                    if let error = store.errors[.codex] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Codex") } footer: {
                    Text("Inicia sesión con ChatGPT en la ventana segura del sistema. La sesión se guarda en el llavero y se renueva cuando ChatGPT lo permite.")
                }
                Section {
                    LabeledContent("Conexión", value: store.claudeConfigured ? String(localized: "Sesión web") : String(localized: "Sin conectar"))
                    Button("Abrir sesión de Claude") {
                        enteringClaudeEmail = true
                        claudeEmail = ""
                        showingClaude = true
                    }
                    if store.claude.organizations.count > 1 {
                        Picker("Espacio de trabajo", selection: Binding(
                            get: { store.claude.selectedOrganizationID ?? "" },
                            set: { id in
                                guard !id.isEmpty else { return }
                                Task { await store.selectClaudeOrganization(id) }
                            }
                        )) {
                            Text("Seleccionar…").tag("")
                            ForEach(store.claude.organizations) { organization in
                                Text(organization.name).tag(organization.id)
                            }
                        }
                        if let date = UserDefaults.standard.object(forKey: "claudeNativeLastAttempt") as? Date {
                            Text("Claude HTTP nativo: \(localizedQuotaStatus(UserDefaults.standard.string(forKey: "claudeNativeLastResult") ?? "—")) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button("Borrar sesión web de Claude", role: .destructive) { confirmDisconnect = .claude }
                    if let error = store.errors[.claude] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Claude") } footer: {
                    Text("Consulta los límites de tu plan de Claude y Claude Code. La sesión se guarda por separado de Codex.")
                }
                Section {
                    if store.githubConfigured {
                        LabeledContent("Cuenta guardada", value: "@\(store.username)")
                        Label("Credencial guardada en el llavero del iPhone", systemImage: "checkmark.shield")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    TextField("Usuario de GitHub", text: $githubDraft.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("githubUsername")
                    SecureField(store.githubConfigured ? String(localized: "Nuevo token (opcional)") : String(localized: "Token personal de GitHub"), text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Tipo de cuenta", selection: $githubDraft.organizationPlan) {
                        Text("Empresa u organización").tag(true)
                        Text("Personal, pagada por mí").tag(false)
                    }
                    .accessibilityIdentifier("githubAccountType")
                    if githubDraft.organizationPlan {
                        Text("La cuota se consulta en tu cuenta de Copilot, no en tu facturación personal. Tu token puede necesitar Copilot Requests → lectura y autorización de tu organización.")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Límite mensual de respaldo (opcional)", text: $githubDraft.allowanceText)
                            .keyboardType(.decimalPad)
                    } else {
                        Toggle("Plan con peticiones premium antiguas", isOn: $githubDraft.legacy)
                        TextField(githubDraft.legacy ? String(localized: "Cuota mensual de peticiones (opcional)") : String(localized: "Créditos incluidos al mes (opcional)"), text: $githubDraft.allowanceText)
                            .keyboardType(.decimalPad)
                    }
                    Button(saving ? String(localized: "Consultando…") : String(localized: "Guardar y consultar Copilot")) {
                        saving = true
                        Task {
                            await store.saveGitHub(username: githubDraft.username, allowanceText: githubDraft.allowanceText, legacy: githubDraft.legacy, token: token, organizationPlan: githubDraft.organizationPlan)
                            token = ""
                            saving = false
                        }
                    }.disabled(saving || disconnecting)
                    Link("Ver mi uso en GitHub", destination: URL(string: "https://github.com/settings/copilot/features")!)
                    Link("Crear token en GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    Button("Borrar conexión de Copilot", role: .destructive) { confirmDisconnect = .copilot }
                    if let error = store.errors[.copilot] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("GitHub Copilot") } footer: {
                    Text("Empresa: el límite mensual se obtiene de GitHub. Si no está disponible, se utiliza el límite de respaldo. Personal: token con permiso Plan → lectura y cuota incluida manual. El token se guarda en el llavero; déjalo vacío para conservarlo.")
                }
                Section {
                    Picker("Mostrar cuotas como", selection: $store.quotaDisplay) {
                        Text("Restante").tag(QuotaDisplay.remaining)
                        Text("Usado").tag(QuotaDisplay.used)
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("quotaDisplayPicker")
                    Text("Se aplica al panel y a los widgets. La otra cifra sigue visible al lado, así que «72 % disponible» y «28 % usado» son la misma lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Pantalla") }
                Section {
                    Toggle("Activar actividad en directo", isOn: Binding(
                        get: { store.liveActivity.enabled },
                        set: { store.liveActivity.setEnabled($0) }
                    ))
                    .accessibilityIdentifier("liveActivityToggle")
                    if store.liveActivity.enabled {
                        Picker("Proveedor en la isla", selection: Binding(
                            get: { store.liveActivity.provider },
                            set: { store.selectLiveActivityProvider($0) }
                        )) {
                            ForEach(store.providerOrder) { provider in
                                Text(provider.title).tag(provider)
                            }
                        }
                        .accessibilityIdentifier("liveActivityProvider")
                        LabeledContent("Estado", value: store.liveActivity.isRunning ? String(localized: "En curso") : String(localized: "Detenida"))
                            .accessibilityIdentifier("liveActivityStatus")
                        if store.liveActivity.isRunning {
                            Button("Finalizar actividad", role: .destructive) { store.liveActivity.stop() }
                                .accessibilityIdentifier("stopLiveActivity")
                        } else {
                            Button("Iniciar actividad en directo") { store.startLiveActivity() }
                                .disabled(disconnecting)
                                .accessibilityIdentifier("startLiveActivity")
                        }
                    }
                    if let message = store.liveActivity.message {
                        Text(message).font(.caption).foregroundStyle(.orange)
                            .accessibilityIdentifier("liveActivityMessage")
                    }
                } header: { Text("Actividad en directo · Dynamic Island") } footer: {
                    Text("Opcional: muestra un proveedor en la pantalla bloqueada y, si tu iPhone tiene Dynamic Island, un icono y su porcentaje. Mantén pulsada la isla para ver todas sus cuotas. Los datos se actualizan solo cuando PULSO recibe una lectura; el contador de renovación funciona sin conexión, pero no consulta cuotas cada minuto en segundo plano. Dura como máximo 8 horas; iOS decide el tamaño y puede finalizarla antes. Después debes iniciarla de nuevo. El proveedor y sus cifras quedan visibles sin desbloquear; no se muestran cuentas ni credenciales.")
                }
                Section {
                    Toggle("Avisarme cuando se restablezca una cuota",
                           isOn: Binding(get: { store.resetAlerts },
                                         set: { value in Task { await store.setResetAlerts(value) } }))
                        .accessibilityIdentifier("resetAlertsToggle")
                    if store.notificationsDenied {
                        Text("iOS tiene las notificaciones desactivadas para PULSO. Actívalas en Ajustes para recibir el aviso.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    Text("El aviso se programa para la hora exacta de renovación que informa el proveedor, así que llega puntual aunque no abras PULSO. Si esa hora cambia, se recoloca en la siguiente lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                } header: { Text("Notificaciones") }
                Section("En tu escritorio") {
                    Toggle("Mantener pantalla encendida", isOn: $store.deskMode)
                    Toggle("Tono nocturno", isOn: $store.nightMode)
                    Text("Mantiene la pantalla encendida mientras PULSO esté abierta. Para StandBy: carga el iPhone, colócalo en horizontal y añade los widgets de PULSO. iOS controla Always-On y la frecuencia de actualización de los widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    let report = BackgroundRefresh.report
                    LabeledContent("Actualización de iOS", value: backgroundRefreshAvailability)
                    LabeledContent("Modo de bajo consumo",
                                   value: ProcessInfo.processInfo.isLowPowerModeEnabled ? String(localized: "Activado") : String(localized: "Desactivado"))
                    if let lastRequest = report.lastRequest {
                        Text("Última solicitud: \(lastRequest.formatted(date: .abbreviated, time: .shortened))")
                        if let error = report.schedulingError {
                            Text("Solicitud rechazada: \(error)").foregroundStyle(.orange)
                        } else if let requestedAfter = report.requestedAfter {
                            Text("Aceptada; no antes de: \(requestedAfter.formatted(date: .abbreviated, time: .shortened))")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let lastRun = report.lastRun {
                        Text("Último intento: \(lastRun.formatted(date: .abbreviated, time: .shortened))")
                        Text(localizedQuotaStatus(report.outcome ?? "—")).foregroundStyle(.secondary)
                        Text("\(report.count) despertares desde la instalación")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("iOS todavía no ha despertado a PULSO").foregroundStyle(.secondary)
                    }
                    ForEach(Provider.allCases) { provider in
                        let attempt = UserDefaults(suiteName: SnapshotCache.suite)?
                            .dictionary(forKey: "widgetQuotaAttempt.\(provider.rawValue)")
                        if let date = attempt?["date"] as? Date {
                            Text("Widget \(provider.title): \(localizedQuotaStatus(attempt?["result"] as? String ?? "—")) · \(date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { Text("Actualización en segundo plano") } footer: {
                    Text("iOS decide cuándo ejecuta la solicitud. Los widgets pueden consultar Codex, Copilot y Claude con el iPhone bloqueado, después del primer desbloqueo tras reiniciar. Usan el llavero cifrado compartido con PULSO y conservan la última lectura si falla la consulta. Claude utiliza su sesión web experimental: si caduca o pide una comprobación, abre su sesión en PULSO. Ningún intervalo está garantizado.")
                }
                .accessibilityIdentifier("backgroundSection")
                Section {
                    #if DEBUG
                    Toggle("Mostrar datos de ejemplo", isOn: $store.demo)
                        .accessibilityIdentifier("demoToggle")
                    Text("La demostración no reemplaza las lecturas reales ni se comparte con los widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                    #endif
                    Button("Actualizar ahora") { Task { await store.refresh() } }
                        .disabled(store.refreshing || store.demo || disconnecting)
                }
                Section("Acerca de Pulso") {
                    Text(verbatim: "© 2026 Jesus Oliva Morales (olivathedev)")
                        .font(.footnote)
                        .accessibilityIdentifier("authorCopyright")
                    Link(destination: URL(string: "https://olivathedev.com/")!) {
                        Label("Web del desarrollador", systemImage: "globe")
                    }
                    .accessibilityIdentifier("developerWebsite")
                    Link(destination: URL(string: "https://ko-fi.com/olivathedev")!) {
                        Label("Invítame a un café", systemImage: "cup.and.saucer")
                    }
                    .accessibilityIdentifier("supportDeveloper")
                    Text("Uso personal no comercial. Los derechos de venta y explotación comercial están reservados al autor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Conexiones")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .sheet(isPresented: $showingClaude) {
                claudeSheet.onDisappear {
                    store.claude.cancelEmailLogin()
                    claudeEmail = ""
                }
            }
            .confirmationDialog("Borrar la conexión y sus datos locales", isPresented: Binding(get: { confirmDisconnect != nil }, set: { if !$0 { confirmDisconnect = nil } }), titleVisibility: .visible) {
                if let provider = confirmDisconnect {
                    Button("Desconectar \(provider.title)", role: .destructive) {
                        disconnecting = true
                        Task {
                            await store.disconnect(provider)
                            githubDraft = store.githubDraft
                            disconnecting = false
                        }
                        confirmDisconnect = nil
                    }
                }
            }
        }
        .onAppear { githubDraft = store.githubDraft }
        .interactiveDismissDisabled(saving || disconnecting || store.codex.isSigningIn)
    }

    private var backgroundRefreshAvailability: String {
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return String(localized: "Activada")
        case .denied: return String(localized: "Desactivada")
        case .restricted: return String(localized: "Restringida")
        @unknown default: return String(localized: "Desconocida")
        }
    }

    private func embeddedLoginBlocked(site: String, retry: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Google no permite iniciar sesión aquí", systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            Text("Es una protección antiphishing de Google frente a navegadores dentro de apps, no un fallo de Pulso. Por eso la página sale en blanco.")
            Text("Vuelve a \(site) y entra con tu correo: te envía un código de acceso a la misma cuenta.")
            Button("Volver a \(site)", action: retry).font(.subheadline.weight(.medium))
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .accessibilityIdentifier("embeddedLoginBlocked")
    }

    private var claudeSheet: some View {
        NavigationStack {
            Group {
                if enteringClaudeEmail {
                    Form {
                        Section {
                            Text("Entra con tu correo").font(.title2.weight(.medium))
                            Text("Pulso rellena y envía tu correo en la web oficial. Después introduces allí el código que te envíe Claude. No guardamos tu correo en los ajustes.")
                                .font(.subheadline).foregroundStyle(.secondary)
                            TextField("Correo de tu cuenta de Claude", text: $claudeEmail)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .privacySensitive()
                                .accessibilityIdentifier("claudeLoginEmail")
                            Button("Continuar con correo") {
                                store.beginClaudeLogin(email: claudeEmail)
                                claudeEmail = ""
                                enteringClaudeEmail = false
                            }
                            .disabled(!validClaudeEmail)
                            .accessibilityIdentifier("claudeContinueEmail")
                            Button("Abrir web sin rellenar el correo") {
                                store.beginClaudeLogin()
                                claudeEmail = ""
                                enteringClaudeEmail = false
                            }
                        } footer: {
                            Text("Google no admite este navegador integrado. Usa el acceso por correo. Este paso no es OAuth nativo: conserva la sesión web actual. Al consultar la cuota, su sesión se guarda en el llavero cifrado compartido para actualizar los widgets. Desconectar Claude elimina esa copia. Los códigos, CAPTCHA y cualquier autorización los confirmas tú en claude.ai.")
                        }
                    }
                } else {
                    claudeWebContent
                }
            }
            .navigationTitle("Claude").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingClaude = false } }
                if !enteringClaudeEmail {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Consultar cuota") {
                            showingClaude = false
                            Task { await store.enableClaude() }
                        }
                    }
                }
            }
        }
    }

    private var validClaudeEmail: Bool {
        let email = claudeEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = email.split(separator: "@", omittingEmptySubsequences: false)
        return email.count <= 254 && parts.count == 2 && !parts[0].isEmpty && parts[1].contains(".")
            && !email.contains(where: \.isWhitespace)
    }

    private var claudeWebContent: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "lock.shield")
                Text(store.claude.address).font(.caption).textSelection(.enabled)
                Spacer()
                if store.claude.loading { ProgressView().controlSize(.small) }
            }.padding(12).background(.thinMaterial)
            if store.claude.blockedLoginHost != nil {
                embeddedLoginBlocked(site: "claude.ai") { store.claude.openLogin() }
            }
            ClaudeBrowser(session: store.claude)
            if let notice = store.claude.emailLoginNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary).padding(12)
            }
            Text("Inicia sesión en claude.ai y pulsa Consultar cuota. Si tienes varios espacios, podrás elegir uno en Conexiones.")
                .font(.caption).foregroundStyle(.secondary).padding(12)
        }
    }

}
