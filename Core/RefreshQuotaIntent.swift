import AppIntents

enum QuotaRefreshTarget: String, AppEnum {
    case summary, codex, copilot, claude

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Cuotas"
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] = [
        .summary: "Todos los proveedores",
        .codex: "Codex",
        .copilot: "GitHub Copilot",
        .claude: "Claude"
    ]

    var providers: Set<Provider> {
        switch self {
        case .summary: return Set(Provider.allCases)
        case .codex: return [.codex]
        case .copilot: return [.copilot]
        case .claude: return [.claude]
        }
    }

    init(provider: Provider) {
        switch provider {
        case .codex: self = .codex
        case .copilot: self = .copilot
        case .claude: self = .claude
        }
    }
}

struct RefreshQuotaIntent: AppIntent {
    static var title: LocalizedStringResource = "Actualizar cuotas"
    static var description = IntentDescription("Consulta las cuotas desde el widget sin abrir Pulso.")
    static var openAppWhenRun = false
    static var isDiscoverable = false

    @Parameter(title: "Proveedor")
    var target: QuotaRefreshTarget

    static var parameterSummary: some ParameterSummary {
        Summary("Actualizar \(\.$target)")
    }

    init() {}

    init(target: QuotaRefreshTarget) {
        self.target = target
    }

    func perform() async throws -> some IntentResult {
        _ = await WidgetQuotaRefresh().refresh(providers: target.providers, userInitiated: true)
        return .result()
    }
}
