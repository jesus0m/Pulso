import Foundation
import Security

struct SharedKeychain {
    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? { String(localized: "No se pudo acceder al llavero del dispositivo (\(status)).") }
    }

    struct Operations {
        var read: ([String: Any]) -> (OSStatus, Data?)
        var add: ([String: Any]) -> OSStatus
        var update: ([String: Any], [String: Any]) -> OSStatus
        var delete: ([String: Any]) -> OSStatus

        static let live = Operations(
            read: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query as CFDictionary, &result)
                return (status, result as? Data)
            },
            add: { SecItemAdd($0 as CFDictionary, nil) },
            update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
            delete: { SecItemDelete($0 as CFDictionary) }
        )
    }

    private static let queue = DispatchQueue(label: "com.jesusom.pulso.shared-keychain")
    let service: String
    let account: String
    var group: String? = Bundle.main.object(forInfoDictionaryKey: "PulsoKeychainGroup") as? String
    var legacyGroup: String? = Bundle.main.object(forInfoDictionaryKey: "PulsoLegacyKeychainGroup") as? String
    var operations: Operations = .live

    private func identity(group: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: group, kSecAttrSynchronizable as String: false]
    }

    private func read(group: String) throws -> Data? {
        var query = identity(group: group)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = operations.read(query)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw Failure(status: status) }
        guard let data else { throw Failure(status: errSecDecode) }
        return data
    }

    private func write(_ data: Data, group: String) throws {
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
        let query = identity(group: group)
        var status = operations.update(query, attributes)
        if status == errSecItemNotFound {
            status = operations.add(query.merging(attributes) { _, value in value })
            if status == errSecDuplicateItem { status = operations.update(query, attributes) }
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    private func remove(group: String) throws {
        let status = operations.delete(identity(group: group))
        guard status == errSecSuccess || status == errSecItemNotFound else { throw Failure(status: status) }
    }

    func load() throws -> Data? {
        try Self.queue.sync {
            guard let group else { throw Failure(status: errSecMissingEntitlement) }
            if let data = try read(group: group) { return data }
            guard let legacyGroup, legacyGroup != group, let data = try read(group: legacyGroup) else { return nil }
            try write(data, group: group)
            guard try read(group: group) == data else { throw Failure(status: errSecDecode) }
            try remove(group: legacyGroup)
            return data
        }
    }

    func save(_ data: Data) throws {
        try Self.queue.sync {
            guard let group else { throw Failure(status: errSecMissingEntitlement) }
            try write(data, group: group)
            guard try read(group: group) == data else { throw Failure(status: errSecDecode) }
            if let legacyGroup, legacyGroup != group { try remove(group: legacyGroup) }
        }
    }

    func delete() throws {
        try Self.queue.sync {
            guard let group else { throw Failure(status: errSecMissingEntitlement) }
            var failure: Error?
            for group in Set([group, legacyGroup].compactMap { $0 }) {
                do { try remove(group: group) } catch { failure = error }
            }
            if let failure { throw failure }
        }
    }
}
