import SwiftUI

struct ConnectionsView: View {
    @Bindable var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var githubDraft = UsageStore.GitHubDraft()
    @State private var showingCodex = false
    @State private var showingClaude = false
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
                    ForEach(Provider.allCases) { provider in
                        Toggle(provider.title, isOn: Binding(
                            get: { store.isProviderVisible(provider) },
                            set: { store.setProviderVisible(provider, $0) }
                        ))
                        .accessibilityIdentifier("visible_\(provider.rawValue)")
                    }
                    Text("La selección se recuerda en este iPhone. Ocultar un panel conserva su cuenta y su última lectura; sus widgets siguen disponibles.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Conexión", value: store.codexConfigured ? "Sesión web" : "Sin conectar")
                    if let account = store.codex.accountLabel {
                        LabeledContent("Cuenta de ChatGPT", value: account)
                    }
                    Text("La cifra grande es lo disponible; el porcentaje usado se muestra debajo, como en los IDEs. Compara la misma cuenta y hora de lectura.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Abrir sesión de ChatGPT") {
                        store.codex.openLogin()
                        showingCodex = true
                    }
                    Button("Borrar sesión web de Codex", role: .destructive) { confirmDisconnect = .codex }
                    if let error = store.errors[.codex] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Codex · experimental") } footer: {
                    Text("Utiliza la web oficial de ChatGPT. La lectura de cuotas puede dejar de funcionar si cambia el servicio. Algunos métodos de inicio de sesión pueden bloquear el navegador integrado.")
                }
                Section {
                    LabeledContent("Conexión", value: store.claudeConfigured ? "Sesión web" : "Sin conectar")
                    Button("Abrir sesión de Claude") {
                        store.beginClaudeLogin()
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
                    }
                    Button("Borrar sesión web de Claude", role: .destructive) { confirmDisconnect = .claude }
                    if let error = store.errors[.claude] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("Claude · experimental") } footer: {
                    Text("Consulta los límites de tu plan de Claude y Claude Code desde la web oficial. La sesión se guarda por separado de Codex. El acceso puede fallar si cambia Claude o se bloquea el navegador integrado.")
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
                    SecureField(store.githubConfigured ? "Nuevo token (opcional)" : "Token personal de GitHub", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Picker("Tipo de cuenta", selection: $githubDraft.organizationPlan) {
                        Text("Empresa u organización").tag(true)
                        Text("Personal, pagada por mí").tag(false)
                    }
                    .accessibilityIdentifier("githubAccountType")
                    if githubDraft.organizationPlan {
                        Text("La cuota se consulta en tu cuenta de Copilot, no en tu facturación personal. Tu token puede necesitar Copilot Requests → lectura y autorización de tu organización.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Toggle("Plan con peticiones premium antiguas", isOn: $githubDraft.legacy)
                        TextField(githubDraft.legacy ? "Cuota mensual de peticiones (opcional)" : "Créditos incluidos al mes (opcional)", text: $githubDraft.allowanceText)
                            .keyboardType(.decimalPad)
                    }
                    Button(saving ? "Consultando…" : "Guardar y consultar Copilot") {
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
                    Text("Empresa: consulta experimental de tu cuota, sin acceso a la facturación de la organización. GitHub puede no publicar una cuota numérica para algunos planes o bloquear el token por política. Personal: token con permiso Plan → lectura. El token se recuerda en el llavero: no necesitas pegarlo otra vez. El campo vacío sirve para reemplazarlo. La cuota incluida se introduce manualmente; si la dejas vacía, solo mostramos consumo. Las licencias de empresa requieren otra integración. Los datos de facturación pueden llegar con retraso.")
                }
                Section("En tu escritorio") {
                    Toggle("Mantener pantalla encendida", isOn: $store.deskMode)
                    Toggle("Tono nocturno", isOn: $store.nightMode)
                    Text("Mantiene la pantalla encendida mientras PULSO esté abierta. Para StandBy: carga el iPhone, colócalo en horizontal y añade los widgets de PULSO. iOS controla Always-On y la frecuencia de actualización de los widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Toggle("Mostrar datos de ejemplo", isOn: $store.demo)
                        .accessibilityIdentifier("demoToggle")
                    Text("La demostración no reemplaza las lecturas reales ni se comparte con los widgets.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Actualizar ahora") { Task { await store.refresh() } }
                        .disabled(store.refreshing || store.demo || disconnecting)
                }
            }
            .navigationTitle("Conexiones")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Listo") { dismiss() } } }
            .sheet(isPresented: $showingCodex) { codexSheet }
            .sheet(isPresented: $showingClaude) { claudeSheet }
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
        .interactiveDismissDisabled(saving || disconnecting)
    }

    private var claudeSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "lock.shield")
                    Text(store.claude.address).font(.caption).textSelection(.enabled)
                    Spacer()
                    if store.claude.loading { ProgressView().controlSize(.small) }
                }.padding(12).background(.thinMaterial)
                ClaudeBrowser(session: store.claude)
                Text("Inicia sesión en claude.ai y pulsa Consultar cuota. Si tienes varios espacios, podrás elegir uno en Conexiones.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .navigationTitle("Claude").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingClaude = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Consultar cuota") {
                        showingClaude = false
                        Task { await store.enableClaude() }
                    }
                }
            }
        }
    }

    private var codexSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "lock.shield")
                    Text(store.codex.address).font(.caption).textSelection(.enabled)
                    Spacer()
                    if store.codex.loading { ProgressView().controlSize(.small) }
                }.padding(12).background(.thinMaterial)
                CodexBrowser(session: store.codex)
                Text("Inicia sesión en la web oficial y pulsa Consultar cuota. Nunca te pediremos la contraseña fuera de esa web.")
                    .font(.caption).foregroundStyle(.secondary).padding(12)
            }
            .navigationTitle("ChatGPT / Codex").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cerrar") { showingCodex = false } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Consultar cuota") {
                        showingCodex = false
                        Task { await store.enableCodex() }
                    }
                }
            }
        }
    }
}
