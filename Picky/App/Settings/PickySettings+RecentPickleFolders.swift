import Foundation

extension PickySettings {
    static func normalizedRecentPickleCwd(_ cwd: String) -> String? {
        let trimmed = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return (NSString(string: trimmed).expandingTildeInPath as NSString).standardizingPath
    }

    static func normalizedPinnedPickleCwds(_ cwds: [String]) -> [String] {
        var normalized: [String] = []
        for cwd in cwds {
            guard let path = normalizedRecentPickleCwd(cwd), !normalized.contains(path) else { continue }
            normalized.append(path)
        }
        return normalized
    }

    static func normalizedRecentPickleCwds(_ cwds: [String], excluding pinnedCwds: [String] = []) -> [String] {
        let pinned = Set(normalizedPinnedPickleCwds(pinnedCwds))
        var normalized: [String] = []
        for cwd in cwds {
            guard let path = normalizedRecentPickleCwd(cwd), !pinned.contains(path), !normalized.contains(path) else { continue }
            normalized.append(path)
            if normalized.count == maxStoredRecentPickleCwds { break }
        }
        return normalized
    }

    mutating func recordRecentPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        pinnedPickleCwds = Self.normalizedPinnedPickleCwds(pinnedPickleCwds)
        if pinnedPickleCwds.contains(path) {
            recentPickleCwds.removeAll { $0 == path }
            return
        }
        recentPickleCwds.removeAll { $0 == path }
        recentPickleCwds.insert(path, at: 0)
        recentPickleCwds = Array(recentPickleCwds.prefix(Self.maxStoredRecentPickleCwds))
    }

    mutating func removeRecentPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        recentPickleCwds.removeAll { $0 == path }
    }

    mutating func pinPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        pinnedPickleCwds = Self.normalizedPinnedPickleCwds(pinnedPickleCwds)
        if !pinnedPickleCwds.contains(path) {
            pinnedPickleCwds.append(path)
        }
        recentPickleCwds.removeAll { $0 == path }
    }

    mutating func unpinPickleCwd(_ cwd: String) {
        guard let path = Self.normalizedRecentPickleCwd(cwd) else { return }
        pinnedPickleCwds = Self.normalizedPinnedPickleCwds(pinnedPickleCwds)
        let wasPinned = pinnedPickleCwds.contains(path)
        pinnedPickleCwds.removeAll { $0 == path }
        guard wasPinned else { return }
        recordRecentPickleCwd(path)
    }
}
