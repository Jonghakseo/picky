//
//  PickySettingsStore.swift
//  Picky
//

import Foundation

struct PickySettingsStore {
    let url: URL
    var fileManager: FileManager = .default

    init(appSupportRoot: URL = PickyAppSupport.defaultRoot(), fileManager: FileManager = .default) {
        self.url = appSupportRoot.appendingPathComponent("Settings", isDirectory: true).appendingPathComponent("settings.json")
        self.fileManager = fileManager
    }

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func load() -> PickySettings {
        let appSupportRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        guard fileManager.fileExists(atPath: url.path) else {
            return .defaults(appSupportRoot: appSupportRoot)
        }
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PickySettings.self, from: data) else {
            return .defaults(appSupportRoot: appSupportRoot)
        }
        return settings
    }

    func save(_ settings: PickySettings) throws {
        let normalized = settings.normalizedPaths()
        try validate(normalized)
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder.prettyPickySettings.encode(normalized)
        try data.write(to: url, options: .atomic)
    }

    func validate(_ settings: PickySettings) throws {
        try validateDirectory(settings.defaultCwd, error: .invalidDefaultCwd(settings.defaultCwd))
        try validateDirectory(settings.mainAgentCwd, error: .invalidMainAgentCwd(settings.mainAgentCwd))
        if !settings.worktreeParent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateDirectory(settings.worktreeParent, error: .invalidWorktreeParent(settings.worktreeParent))
        }
        if !settings.piCodingAgentDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateDirectory(settings.piCodingAgentDir, error: .invalidPiCodingAgentDir(settings.piCodingAgentDir))
        }
        if !settings.piBinaryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try validateExecutable(settings.piBinaryPath, error: .invalidPiBinaryPath(settings.piBinaryPath))
        }
    }

    private func validateDirectory(_ path: String, error: PickySettingsValidationError) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: NSString(string: path).expandingTildeInPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw error
        }
    }

    private func validateExecutable(_ path: String, error: PickySettingsValidationError) throws {
        guard fileManager.isExecutableFile(atPath: NSString(string: path).expandingTildeInPath) else {
            throw error
        }
    }
}

private extension JSONEncoder {
    static var prettyPickySettings: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
