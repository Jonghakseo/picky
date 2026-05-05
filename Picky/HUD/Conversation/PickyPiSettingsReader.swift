//
//  PickyPiSettingsReader.swift
//  Picky
//
//  Tiny read-only bridge for Pi UI defaults used by the HUD.
//

import Foundation

enum PickyPiSettingsReader {
    static func hideThinkingBlock(cwd: String?) -> Bool {
        var value = hideThinkingBlock(in: globalSettingsURL()) ?? false
        if let projectURL = projectSettingsURL(cwd: cwd), let projectValue = hideThinkingBlock(in: projectURL) {
            value = projectValue
        }
        return value
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

    private static func hideThinkingBlock(in url: URL) -> Bool? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = object["hideThinkingBlock"] as? Bool
        else { return nil }
        return value
    }
}
