import Foundation
import Security

/// Only the app accesses this item; the widget receives quota snapshots instead.
enum TokenVault {
    private static let queue = DispatchQueue(label: "com.jesusom.pulso.credentials")
    private static var identity: [String: Any] {
        var result: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "com.jesusom.pulso.github",
                                    kSecAttrAccount as String: "personal-token",
                                    kSecAttrSynchronizable as String: false]
        #if os(macOS)
        result[kSecUseDataProtectionKeychain as String] = true
        #endif
        return result
    }

    static func save(_ token: String) throws {
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw UsageError.invalidCredentials }
        try queue.sync {
            var add = identity
            add[kSecValueData as String] = Data(token.utf8)
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let status = SecItemAdd(add as CFDictionary, nil)
            switch status {
            case errSecSuccess: return
            case errSecDuplicateItem:
                let update: [String: Any] = [kSecValueData as String: Data(token.utf8),
                                            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
                let status = SecItemUpdate(identity as CFDictionary, update as CFDictionary)
                guard status == errSecSuccess else { throw VaultError(status: status) }
            default: throw VaultError(status: status)
            }
        }
    }

    /// A locked/unavailable Keychain is treated as disconnected, never as an empty token.
    static func read() -> String? {
        queue.sync {
            var query = identity
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data, let token = String(data: data, encoding: .utf8), !token.isEmpty else { return nil }
                return token
            case errSecItemNotFound: return nil
            default: return nil
            }
        }
    }

    static func delete() throws {
        try queue.sync {
            let status = SecItemDelete(identity as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw VaultError(status: status) }
        }
    }

    private struct VaultError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { "No se pudo acceder al llavero del dispositivo (\(status))." }
    }
}
