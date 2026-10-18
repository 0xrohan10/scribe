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

    public init(service: String = "ai.rohan.Scribe") {
        self.service = service
    }

    public func secret(for key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Passing nil or an empty string deletes the key.
    public func setSecret(_ value: String?, for key: String) throws {
        let deleteStatus = SecItemDelete(baseQuery(key) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else { throw KeychainError(status: deleteStatus) }
        guard let value, !value.isEmpty else { return }

        var item = baseQuery(key)
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        item[kSecAttrLabel as String] = "Scribe: \(key)"
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
}
