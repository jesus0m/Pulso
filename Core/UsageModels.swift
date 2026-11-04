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

    var usedPercent: Double? {
        guard let limit, limit.isFinite, limit > 0, used.isFinite, used >= 0 else { return nil }
        return min(100, max(0, used / limit * 100))
    }

    /// Keep the two displayed integers complementary, avoiding 44% + 55% from floating point error.
    var displayedUsedPercent: Int? { usedPercent.map { Int($0.rounded()) } }
    var displayedRemainingPercent: Int? { displayedUsedPercent.map { 100 - $0 } }

    var remainingPercent: Double? {
        guard let limit, limit.isFinite, limit > 0, used.isFinite, used >= 0 else { return nil }
        return min(100, max(0, (1 - used / limit) * 100))
    }
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
        case .unsupportedSchema: return "El proveedor devolvió datos de uso no compatibles."
        case .invalidCredentials: return "Introduce un usuario y un token válidos."
        case .invalidAllowance: return "El límite manual debe ser un número mayor que cero."
        case .noUsageData: return "GitHub no ha devuelto datos de consumo para esta cuenta. No equivale a consumo cero. Comprueba el tipo de cuenta en Conexiones."
        case .invalidResponse: return "No se pudo verificar la respuesta del proveedor."
        case .http(401): return "La sesión ha caducado o el token no es válido."
        case .http(403): return "Acceso denegado. Comprueba el permiso Plan de lectura y los límites de GitHub."
        case .http(404): return "Informe no disponible. Comprueba el usuario y si tu plan se factura a tu cuenta personal."
        case .http(let code): return "El proveedor no pudo completar la consulta (HTTP \(code))."
        }
    }
}

enum SnapshotCache {
    private static let suite = "group.com.jesusom.pulso"
    private static let key = "usageSnapshots"

    static func load() -> [UsageSnapshot] {
        guard let data = UserDefaults(suiteName: suite)?.data(forKey: key),
              let snapshots = try? JSONDecoder().decode([UsageSnapshot].self, from: data) else { return [] }
        return snapshots
    }

    static func save(_ snapshots: [UsageSnapshot]) {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        guard let data = try? JSONEncoder().encode(snapshots) else {
            defaults.removeObject(forKey: key)
            return
        }
        defaults.set(data, forKey: key)
    }
}
