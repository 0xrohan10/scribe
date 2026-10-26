import Core
import Foundation
import Security

public struct KeychainError: Error, LocalizedError {
    public let status: OSStatus
    public var errorDescription: String? {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "Keychain error \(status)"
    }
}

/// API keys as generic passwords in the login Keychain, one account per key.
public struct KeychainSecretStore: SecretStore {
    public let service: String
    private let access: KeychainAccess

    public init(service: String = "ai.rohan.Scribe") {
        self.init(service: service, access: .system)
    }

    init(service: String, access: KeychainAccess) {
        self.service = service
        self.access = access
    }

    public func secret(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        guard let data = access.read(query) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Passing nil or an empty string deletes the key.
    public func setSecret(_ value: String?, for key: String) throws {
        let query = baseQuery(key)
        guard let value, !value.isEmpty else {
            let status = access.delete(query)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }

        let attributes: [String: Any] = [
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecAttrLabel as String: "Scribe: \(key)",
        ]
        // An unsuccessful update must leave the previous credential usable.
        var status = access.update(query, attributes)
        if status == errSecItemNotFound {
            status = access.add(query.merging(attributes) { _, new in new })
            // Another caller can create the item between update and add.
            if status == errSecDuplicateItem { status = access.update(query, attributes) }
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}

/// Security operations can fail independently. Tests inject those failures without touching the login Keychain.
struct KeychainAccess: Sendable {
    var read: @Sendable ([String: Any]) -> Data?
    var add: @Sendable ([String: Any]) -> OSStatus
    var update: @Sendable ([String: Any], [String: Any]) -> OSStatus
    var delete: @Sendable ([String: Any]) -> OSStatus

    static let system = KeychainAccess(
        read: { query in
            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
            return result as? Data
        },
        add: { SecItemAdd($0 as CFDictionary, nil) },
        update: { SecItemUpdate($0 as CFDictionary, $1 as CFDictionary) },
        delete: { SecItemDelete($0 as CFDictionary) })
}
