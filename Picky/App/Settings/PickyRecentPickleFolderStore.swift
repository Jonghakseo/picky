import Foundation

protocol PickyRecentPickleFolderStoring {
    var recentPickleCwds: [String] { get }
    var pinnedPickleCwds: [String] { get }
    func record(cwd: String) throws -> [String]
    func remove(cwd: String) throws -> [String]
    func pin(cwd: String) throws -> (pinned: [String], recent: [String])
    func unpin(cwd: String) throws -> (pinned: [String], recent: [String])
    func reorderPinned(cwds: [String]) throws -> [String]
}

struct PickyNoopRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    var recentPickleCwds: [String] { [] }
    var pinnedPickleCwds: [String] { [] }
    func record(cwd: String) throws -> [String] { [] }
    func remove(cwd: String) throws -> [String] { [] }
    func pin(cwd: String) throws -> (pinned: [String], recent: [String]) { ([], []) }
    func unpin(cwd: String) throws -> (pinned: [String], recent: [String]) { ([], []) }
    func reorderPinned(cwds: [String]) throws -> [String] { [] }
}

struct PickySettingsRecentPickleFolderStore: PickyRecentPickleFolderStoring {
    var settingsStore: PickySettingsStore = PickySettingsStore()

    var recentPickleCwds: [String] {
        settingsStore.load().recentPickleCwds
    }

    var pinnedPickleCwds: [String] {
        settingsStore.load().pinnedPickleCwds
    }

    func record(cwd: String) throws -> [String] {
        var settings = settingsStore.load()
        settings.recordRecentPickleCwd(cwd)
        settings = settings.normalizedPaths()
        try settingsStore.save(settings)
        return settings.recentPickleCwds
    }

    func remove(cwd: String) throws -> [String] {
        var settings = settingsStore.load()
        settings.removeRecentPickleCwd(cwd)
        settings = settings.normalizedPaths()
        try settingsStore.save(settings)
        return settings.recentPickleCwds
    }

    func pin(cwd: String) throws -> (pinned: [String], recent: [String]) {
        var settings = settingsStore.load()
        settings.pinPickleCwd(cwd)
        settings = settings.normalizedPaths()
        try settingsStore.save(settings)
        return (settings.pinnedPickleCwds, settings.recentPickleCwds)
    }

    func unpin(cwd: String) throws -> (pinned: [String], recent: [String]) {
        var settings = settingsStore.load()
        settings.unpinPickleCwd(cwd)
        settings = settings.normalizedPaths()
        try settingsStore.save(settings)
        return (settings.pinnedPickleCwds, settings.recentPickleCwds)
    }

    func reorderPinned(cwds: [String]) throws -> [String] {
        var settings = settingsStore.load()
        settings.reorderPinnedPickleCwds(cwds)
        settings = settings.normalizedPaths()
        try settingsStore.save(settings)
        return settings.pinnedPickleCwds
    }
}
