//
//  AzureOpenAIKeychainStore.swift
//  Picky
//
//  Small Keychain reader for Azure OpenAI voice configuration. Environment
//  variables still take precedence, but matching Keychain entries allow local
//  secrets/settings to survive app restarts and reboots without committing them.
//

import Foundation
import Security

enum AzureOpenAIKeychainStore {
    static let service = "com.jonghakseo.picky.azure-openai"

    static func value(
        for key: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? string(for: key)
    }

    static func string(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !string.isEmpty else {
            return nil
        }

        return string
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
