import Foundation

enum Provider: String, Codable, CaseIterable, Identifiable, Sendable {
    case codex, copilot, claude
    var id: String { rawValue }
    var title: String {
        switch self {
        case .codex: return "Codex"
        case .copilot: return "GitHub Copilot"
        case .claude: return "Claude"
        }
    }
}

struct UsageWindow: Codable, Identifiable, Equatable, Sendable {
    var id: String
    var title: String
    var used: Double
    var limit: Double?
    var resetsAt: Date?
    var remaining: Double? = nil
    var reportedRemainingPercent: Double? = nil

    /// Keep persisted provider titles stable; resolve display copy in each app or extension.
    var localizedTitle: String {
        switch title {
        case "Sesión": return String(localized: "Sesión")
        case "Sesión · 5 h": return String(localized: "Sesión · 5 h")
        case "Semana": return String(localized: "Semana")
        case "Semana · Opus": return String(localized: "Semana · Opus")
        case "Semana · Sonnet": return String(localized: "Semana · Sonnet")
        case "Mes": return String(localized: "Mes")
        case "Créditos del mes": return String(localized: "Créditos del mes")
        case "Créditos usados · cuenta": return String(localized: "Créditos usados · cuenta")
        case "Premium · cuenta": return String(localized: "Premium · cuenta")
        case "Chat · cuenta": return String(localized: "Chat · cuenta")
        case "Mes · solicitudes premium": return String(localized: "Mes · solicitudes premium")
        case "Mes · créditos IA": return String(localized: "Mes · créditos IA")
        default:
            if title.hasPrefix("Sesión · ") {
                return String(localized: "Sesión · \(String(title.dropFirst("Sesión · ".count)))")
            }
            if title.hasPrefix("Semana · ") {
                return String(localized: "Semana · \(String(title.dropFirst("Semana · ".count)))")
            }
            return title
        }
    }

    var usedPercent: Double? {
        guard let limit, limit.isFinite, limit > 0, used.isFinite, used >= 0 else { return nil }
        return min(100, max(0, used / limit * 100))
    }

    /// Derived percentages stay complementary; independently reported balances take precedence.
    var displayedUsedPercent: Int? { usedPercent.map { Int($0.rounded()) } }
    var displayedRemainingPercent: Int? {
        if let reportedRemainingPercent, reportedRemainingPercent.isFinite,
           (0...100).contains(reportedRemainingPercent) {
            return Int(reportedRemainingPercent.rounded())
        }
        return displayedUsedPercent.map { 100 - $0 }
    }

    var remainingPercent: Double? {
        if let reportedRemainingPercent, reportedRemainingPercent.isFinite,
           (0...100).contains(reportedRemainingPercent) {
            return reportedRemainingPercent
        }
        guard let limit, limit.isFinite, limit > 0, used.isFinite, used >= 0 else { return nil }
        return min(100, max(0, (1 - used / limit) * 100))
    }

    /// The headline figure and the complement shown beside it, so both readings
    /// stay visible however the user prefers to read a quota.
    func displayedPercent(_ display: QuotaDisplay) -> Int? {
        display == .used ? displayedUsedPercent : displayedRemainingPercent
    }

    func complementPercent(_ display: QuotaDisplay) -> Int? {
        display == .used ? displayedRemainingPercent : displayedUsedPercent
    }
}

enum QuotaDisplay: String, Codable, CaseIterable, Sendable {
    case remaining, used

    var headline: String { self == .used ? String(localized: "USADO") : String(localized: "DISPONIBLE") }
    var headlineNoun: String { self == .used ? String(localized: "usado") : String(localized: "disponible") }
    var complementNoun: String { self == .used ? String(localized: "disponible") : String(localized: "usado") }
}

struct UsageSnapshot: Codable, Equatable, Sendable {
    var provider: Provider
    var windows: [UsageWindow]
    var updatedAt: Date
    var source: String
}

enum UsageError: Error, Equatable, LocalizedError {
    case unsupportedSchema, invalidCredentials, invalidAllowance, invalidResponse, noUsageData, http(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema: return String(localized: "El proveedor devolvió datos de uso no compatibles.")
        case .invalidCredentials: return String(localized: "Introduce un usuario y un token válidos.")
        case .invalidAllowance: return String(localized: "El límite manual debe ser un número mayor que cero.")
        case .noUsageData: return String(localized: "GitHub no ha devuelto datos de consumo para esta cuenta. No equivale a consumo cero. Comprueba el tipo de cuenta en Conexiones.")
        case .invalidResponse: return String(localized: "No se pudo verificar la respuesta del proveedor.")
        case .http(401): return String(localized: "La sesión ha caducado o el token no es válido.")
        case .http(403): return String(localized: "Acceso denegado. Comprueba el permiso Plan de lectura y los límites de GitHub.")
        case .http(404): return String(localized: "Informe no disponible. Comprueba el usuario y si tu plan se factura a tu cuenta personal.")
        case .http(let code): return String(localized: "El proveedor no pudo completar la consulta (HTTP \(code)).")
        }
    }
}

/// Stored diagnostics are also used for coordination; translate only when displaying them.
func localizedQuotaStatus(_ status: String) -> String {
    switch status {
    case "En curso": return String(localized: "En curso")
    case "Actualizado": return String(localized: "Actualizado")
    case "Tiempo de ejecución agotado": return String(localized: "Tiempo de ejecución agotado")
    case "Sin proveedores conectados": return String(localized: "Sin proveedores conectados")
    default: return status
    }
}

enum SnapshotCache {
    static let suite = "group.com.jesusom.pulso"
    private static let key = "usageSnapshots"
    private static let displayKey = "quotaDisplay"

    /// Lives in the shared group so the widgets read the same preference as the app.
    static var quotaDisplay: QuotaDisplay {
        get {
            let raw = UserDefaults(suiteName: suite)?.string(forKey: displayKey) ?? ""
            return QuotaDisplay(rawValue: raw) ?? .remaining
        }
        set { UserDefaults(suiteName: suite)?.set(newValue.rawValue, forKey: displayKey) }
    }

    static func load() -> [UsageSnapshot] {
        (try? SharedQuotaAccess.transaction { readSnapshots() }) ?? []
    }

    private static func readSnapshots() -> [UsageSnapshot] {
        let defaults = UserDefaults(suiteName: suite)
        defaults?.synchronize()
        guard let data = defaults?.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else { return [] }
        return snapshots
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        try? SharedQuotaAccess.transaction { writeSnapshots(snapshots) }
    }

    static func merge(_ snapshot: UsageSnapshot) {
        try? SharedQuotaAccess.transaction {
            var snapshots = readSnapshots()
            if let current = snapshots.first(where: { $0.provider == snapshot.provider }),
               current.updatedAt > snapshot.updatedAt { return }
            snapshots.removeAll { $0.provider == snapshot.provider }
            snapshots.append(snapshot)
            writeSnapshots(snapshots)
        }
    }

    static func remove(_ provider: Provider) {
        try? SharedQuotaAccess.transaction {
            writeSnapshots(readSnapshots().filter { $0.provider != provider })
        }
    }

    private static func writeSnapshots(_ snapshots: [UsageSnapshot]) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        guard let data = try? JSONEncoder().encode(snapshots) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
        defaults.synchronize()
    }
}
