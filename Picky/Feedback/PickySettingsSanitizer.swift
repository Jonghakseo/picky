//
//  PickySettingsSanitizer.swift
//  Picky
//
//  Reads the user's settings.json and produces a sanitized JSON Data with
//  API keys, tokens, and secret-shaped fields replaced. Used by the
//  diagnostics bundle's Full scope so the attached settings are useful for
//  reproducing config-driven bugs without leaking provider credentials.
//

import Foundation

enum PickySettingsSanitizer {
    /// Key-name fragments (case-insensitive) that trigger masking. Matches
    /// values whose key contains any of these substrings — broad on purpose so
    /// future settings inherit masking by naming convention.
    static let sensitiveKeyFragments: [String] = [
        "apikey",
        "token",
        "secret",
        "password",
        "authorization",
        "baseurl"
    ]

    static func sanitizedJSONData(from settingsFileURL: URL) throws -> Data {
        let raw = try Data(contentsOf: settingsFileURL)
        return try sanitize(jsonData: raw)
    }

    static func sanitize(jsonData: Data) throws -> Data {
        let object = try JSONSerialization.jsonObject(with: jsonData, options: [.fragmentsAllowed])
        let sanitized = sanitize(value: object, parentKey: nil)
        return try JSONSerialization.data(
            withJSONObject: sanitized,
            options: [.prettyPrinted, .sortedKeys]
        )
    }

    static func sanitize(value: Any, parentKey: String?) -> Any {
        if let dictionary = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (key, inner) in dictionary {
                out[key] = sanitize(value: inner, parentKey: key)
            }
            return out
        }
        if let array = value as? [Any] {
            return array.map { sanitize(value: $0, parentKey: parentKey) }
        }
        if let stringValue = value as? String, shouldMask(key: parentKey) {
            return maskedReplacement(for: stringValue)
        }
        return value
    }

    static func shouldMask(key: String?) -> Bool {
        guard let key else { return false }
        let lowercased = key.lowercased()
        return sensitiveKeyFragments.contains(where: { lowercased.contains($0) })
    }

    static func maskedReplacement(for value: String) -> String {
        let count = value.count
        if count == 0 { return "" }
        return "<masked:\(count) chars>"
    }
}
