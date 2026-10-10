//
//  PickySecretStore.swift
//  Picky
//
//  Keychain-backed storage for credentials typed into Settings. New secrets
//  must not be persisted in settings.json (architecture guard).
//

import Foundation
import Security

enum PickySecretAccount: String, CaseIterable {
    case groqSTTAPIKey = "GROQ_STT_API_KEY"
}

protocol PickySecretStoring: AnyObject {
    func secret(for account: PickySecretAccount) -> String?
    /// Stores a trimmed value, or deletes it when the value is empty.
    /// Returns false when the backing store rejected the change.
    @discardableResult
    func setSecret(_ value: String, for account: PickySecretAccount) -> Bool
}

enum PickySecretStore {
    /// Tests and UI-test hosts never touch the user's Keychain.
    static let shared: PickySecretStoring = PickyRuntimeEnvironment.allowsUserEnvironmentEffects
        ? PickyKeychainSecretStore()
        : PickyInMemorySecretStore()
}

final class PickyInMemorySecretStore: PickySecretStoring {
    private let lock = NSLock()
    private var values: [PickySecretAccount: String] = [:]

    func secret(for account: PickySecretAccount) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    @discardableResult
    func setSecret(_ value: String, for account: PickySecretAccount) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock(); defer { lock.unlock() }
        values[account] = trimmed.isEmpty ? nil : trimmed
        return true
    }
}

/// One generic-password item per account under a Picky service. Reads are
/// cached because the dictation path checks provider readiness often.
final class PickyKeychainSecretStore: PickySecretStoring {
    static let service = "com.jonghakseo.picky.secrets"

    private let lock = NSLock()
    private var cache: [PickySecretAccount: String?] = [:]

    func secret(for account: PickySecretAccount) -> String? {
        lock.lock()
        if let cached = cache[account] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let value = Self.read(account)
        lock.lock()
        cache[account] = .some(value)
        lock.unlock()
        return value
    }

    @discardableResult
    func setSecret(_ value: String, for account: PickySecretAccount) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let succeeded = trimmed.isEmpty ? Self.delete(account) : Self.write(trimmed, account: account)
        if succeeded {
            lock.lock()
            cache[account] = .some(trimmed.isEmpty ? nil : trimmed)
            lock.unlock()
        }
        return succeeded
    }

    private static func baseQuery(_ account: PickySecretAccount) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account.rawValue,
        ]
    }

    private static func read(_ account: PickySecretAccount) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func write(_ value: String, account: PickySecretAccount) -> Bool {
        let data = Data(value.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var attributes = baseQuery(account)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        attributes[kSecAttrLabel as String] = "Picky \(account.rawValue)"
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func delete(_ account: PickySecretAccount) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
