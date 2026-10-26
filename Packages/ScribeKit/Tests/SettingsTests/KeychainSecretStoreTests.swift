import Foundation
import Security
import Testing
@testable import Settings

@Suite struct KeychainSecretStoreTests {
    @Test func failedReplacementPreservesExistingCredential() throws {
        let keychain = TestKeychain(value: "old-token", failure: errSecInteractionNotAllowed)
        let store = KeychainSecretStore(service: "test", access: keychain.access)
        #expect(throws: KeychainError.self) { try store.setSecret("new-token", for: "account") }
        #expect(store.secret(for: "account") == "old-token")
    }

    @Test func createReplaceAndDeleteThroughPublicInterface() throws {
        let keychain = TestKeychain()
        let store = KeychainSecretStore(service: "test", access: keychain.access)
        try store.setSecret("first", for: "account")
        #expect(store.secret(for: "account") == "first")
        try store.setSecret("second", for: "account")
        #expect(store.secret(for: "account") == "second")
        try store.setSecret("", for: "account")
        #expect(store.secret(for: "account") == nil)
        try store.setSecret(nil, for: "account")
        #expect(store.secret(for: "account") == nil)
    }

    @Test func failedCreationDoesNotSaveCredential() {
        let keychain = TestKeychain(failure: errSecInteractionNotAllowed)
        let store = KeychainSecretStore(service: "test", access: keychain.access)
        #expect(throws: KeychainError.self) { try store.setSecret("new-token", for: "account") }
        #expect(store.secret(for: "account") == nil)
    }

    @Test func concurrentCreationStillSavesTheRequestedCredential() throws {
        let keychain = TestKeychain(createBeforeAdd: true)
        let store = KeychainSecretStore(service: "test", access: keychain.access)
        try store.setSecret("requested-token", for: "account")
        #expect(store.secret(for: "account") == "requested-token")
    }
}

/// One-item Security simulation. Failed writes leave the item unchanged, as SecItemUpdate does.
private final class TestKeychain: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Data?
    private let failure: OSStatus
    private var createBeforeAdd: Bool

    init(value: String? = nil, failure: OSStatus = errSecSuccess, createBeforeAdd: Bool = false) {
        self.value = value.map { Data($0.utf8) }
        self.failure = failure
        self.createBeforeAdd = createBeforeAdd
    }

    var access: KeychainAccess {
        KeychainAccess(
            read: { _ in self.lock.withLock { self.value } },
            add: { item in self.lock.withLock {
                guard self.failure == errSecSuccess else { return self.failure }
                if self.createBeforeAdd {
                    self.value = Data("another-callers-token".utf8)
                    self.createBeforeAdd = false
                }
                guard self.value == nil else { return errSecDuplicateItem }
                self.value = item[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            update: { _, attributes in self.lock.withLock {
                guard self.value != nil else { return errSecItemNotFound }
                guard self.failure == errSecSuccess else { return self.failure }
                self.value = attributes[kSecValueData as String] as? Data
                return errSecSuccess
            } },
            delete: { _ in self.lock.withLock {
                guard self.value != nil else { return errSecItemNotFound }
                self.value = nil
                return errSecSuccess
            } })
    }
}
