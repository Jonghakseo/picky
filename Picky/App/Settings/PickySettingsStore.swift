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
            return migrateRealtimeOptInRuntimeModeIfNeeded(.defaults(appSupportRoot: appSupportRoot))
        }
        guard let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(PickySettings.self, from: data) else {
            return .defaults(appSupportRoot: appSupportRoot)
        }
        return migrateRealtimeOptInRuntimeModeIfNeeded(settings)
    }

    private func migrateRealtimeOptInRuntimeModeIfNeeded(_ settings: PickySettings) -> PickySettings {
        guard AppBundleConfiguration.realtimeOptIn,
              !settings.mainAgentRuntimeModeRealtimeOptInMigrationApplied else {
            return settings
        }

        var migrated = settings
        migrated.mainAgentRuntimeMode = .openAIRealtime
        migrated.mainAgentRuntimeModeRealtimeOptInMigrationApplied = true
        try? save(migrated)
        return migrated
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
    }

    private func validateDirectory(_ path: String, error: PickySettingsValidationError) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: NSString(string: path).expandingTildeInPath, isDirectory: &isDirectory), isDirectory.boolValue else {
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
