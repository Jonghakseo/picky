//
//  AzureOpenAIKeychainStore.swift
//  Picky
//
//  Small Keychain reader for Azure OpenAI voice configuration. Environment
//  variables still take precedence, but a single consolidated Keychain entry
//  allows local secrets/settings to survive app restarts and reboots without
//  prompting once per setting.
//

import Foundation
import Security

enum AzureOpenAIKeychainStore {
    static let service = "com.jonghakseo.picky.azure-openai"
    static let consolidatedAccount = "AZURE_OPENAI_VOICE_CONFIG"

    private static let cacheLock = NSLock()
    private static var cachedKeychainValues: [String: String]?
    private static var didLoadKeychainValues = false

    static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? keychainValues()[key]
    }

    private static func keychainValues() -> [String: String] {
        cacheLock.lock()
        if didLoadKeychainValues {
            let values = cachedKeychainValues ?? [:]
            cacheLock.unlock()
            return values
        }
        cacheLock.unlock()

        let values = loadConsolidatedValues()

        cacheLock.lock()
        cachedKeychainValues = values
        didLoadKeychainValues = true
        cacheLock.unlock()

        return values
    }

    private static func loadConsolidatedValues() -> [String: String] {
        guard let data = data(for: consolidatedAccount),
              let decodedValues = try? JSONDecoder().decode([String: String].self, from: data) else {
            return [:]
        }

        return decodedValues.compactMapValues { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }
    }

    private static func data(for account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              !data.isEmpty else {
            return nil
        }

        return data
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
