//
//  AppBundleConfiguration.swift
//  Picky
//
//  Shared helper for reading runtime configuration from the built app bundle.
//

import Foundation

enum AppBundleConfiguration {
    static func stringValue(forKey key: String) -> String? {
        if let value = Bundle.main.object(forInfoDictionaryKey: key) as? String {
            let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedValue.isEmpty {
                return trimmedValue
            }
        }

        guard let resourceInfoPath = Bundle.main.path(forResource: "Info", ofType: "plist"),
              let resourceInfo = NSDictionary(contentsOfFile: resourceInfoPath),
              let value = resourceInfo[key] as? String else {
            return nil
        }

        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedValue.isEmpty ? nil : trimmedValue
    }

    static var realtimeOptIn: Bool {
        guard let buildInfoPath = Bundle.main.path(forResource: "PickyBuildInfo", ofType: "json"),
              let data = try? Data(contentsOf: URL(fileURLWithPath: buildInfoPath)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return false
        }
        let raw = json["realtimeOptIn"] as? String ?? ""
        return raw == "1" || raw.lowercased() == "true"
    }
}
