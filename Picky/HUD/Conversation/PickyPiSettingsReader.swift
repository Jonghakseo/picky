//
//  PickyPiSettingsReader.swift
//  Picky
//
//  Tiny read-only bridge for Pi UI defaults used by the HUD.
//

import Foundation

enum PickyPiSettingsError: LocalizedError, Equatable {
    case invalidSettingsJSON(String)

    var errorDescription: String? {
        switch self {
        case .invalidSettingsJSON(let path):
            return "Pi settings.json is not a JSON object: \(path)"
        }
    }
}

enum PickyPiSettingsReader {
    static func hideThinkingBlock(cwd: String?) -> Bool {
        var value = hideThinkingBlock(in: globalSettingsURL()) ?? false
        if let projectURL = projectSettingsURL(cwd: cwd), let projectValue = hideThinkingBlock(in: projectURL) {
            value = projectValue
        }
        return value
    }

    static func setHideThinkingBlock(_ hidden: Bool, cwd: String?) throws {
        try setHideThinkingBlock(hidden, in: settingsURLForWriting(cwd: cwd))
    }

    static func settingsURLForWriting(cwd: String?, fileManager: FileManager = .default) -> URL {
        if let projectURL = projectSettingsURL(cwd: cwd), fileManager.fileExists(atPath: projectURL.path) {
            return projectURL
        }
        return globalSettingsURL()
    }

    static func hideThinkingBlock(in url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["hideThinkingBlock"] as? Bool
        else { return nil }
        return value
    }

    static func setHideThinkingBlock(_ hidden: Bool, in url: URL, fileManager: FileManager = .default) throws {
        var object: [String: Any] = [:]
        if fileManager.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            if !data.isEmpty {
                guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw PickyPiSettingsError.invalidSettingsJSON(url.path)
                }
                object = decoded
            }
        }

        object["hideThinkingBlock"] = hidden
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try data.write(to: url, options: .atomic)
    }

    private static func globalSettingsURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("agent", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }

    private static func projectSettingsURL(cwd: String?) -> URL? {
        guard let cwd, !cwd.isEmpty else { return nil }
        return URL(fileURLWithPath: cwd, isDirectory: true)
            .appendingPathComponent(".pi", isDirectory: true)
            .appendingPathComponent("settings.json", isDirectory: false)
    }
}
