import SwiftUI

struct ConnectionsView: View {
    @Bindable var store: UsageStore
    @Environment(\.dismiss) private var dismiss
    @State private var token = ""
    @State private var githubDraft = UsageStore.GitHubDraft()
    @State private var showingCodex = false
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
                Section {
                    LabeledContent("Conexión", value: store.codexConfigured ? "Sesión web" : "Sin conectar")
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
                    TextField("Usuario de GitHub", text: $githubDraft.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("githubUsername")
                    SecureField(store.githubConfigured ? "Nuevo token (opcional)" : "Token personal de GitHub", text: $token)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Toggle("Plan con peticiones premium antiguas", isOn: $githubDraft.legacy)
                    TextField(githubDraft.legacy ? "Cuota mensual de peticiones (opcional)" : "Créditos incluidos al mes (opcional)", text: $githubDraft.allowanceText)
                        .keyboardType(.decimalPad)
                    Button(saving ? "Consultando…" : "Guardar y consultar Copilot") {
                        saving = true
                        Task {
                            await store.saveGitHub(username: githubDraft.username, allowanceText: githubDraft.allowanceText, legacy: githubDraft.legacy, token: token)
                            token = ""
                            saving = false
                        }
                    }.disabled(saving || disconnecting)
                    Link("Crear token en GitHub", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                    Button("Borrar conexión de Copilot", role: .destructive) { confirmDisconnect = .copilot }
                    if let error = store.errors[.copilot] { Text(error).font(.caption).foregroundStyle(.orange) }
                } header: { Text("GitHub Copilot") } footer: {
                    Text("Cuenta personal: token con permiso Plan → lectura. El token se guarda en el llavero. La cuota incluida se introduce manualmente; si la dejas vacía, solo mostramos consumo. Las licencias de empresa requieren otra integración. Los datos de facturación pueden llegar con retraso.")
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
