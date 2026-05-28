//
//  PickyFullscreenSidebarGrouping.swift
//  Picky
//
//  Groups fullscreen Pickles by their local project root.
//

import Foundation

struct PickyFullscreenSidebarGroup: Equatable, Identifiable {
    let id: String
    let label: String
    let sessions: [PickySessionListViewModel.SessionCard]
}

enum PickyFullscreenSidebarGrouping {
    static func groups(from sessions: [PickySessionListViewModel.SessionCard]) -> [PickyFullscreenSidebarGroup] {
        guard !sessions.isEmpty else { return [] }

        var buckets: [String: (label: String, sessions: [PickySessionListViewModel.SessionCard], latestUpdate: Date)] = [:]
        var order: [String] = []

        for session in sessions {
            let key = groupKey(for: session)
            if buckets[key.id] == nil {
                order.append(key.id)
                buckets[key.id] = (label: key.label, sessions: [], latestUpdate: session.updatedAt)
            }
            buckets[key.id]?.sessions.append(session)
            if session.updatedAt > (buckets[key.id]?.latestUpdate ?? .distantPast) {
                buckets[key.id]?.latestUpdate = session.updatedAt
            }
        }

        return order.compactMap { id -> (index: Int, group: PickyFullscreenSidebarGroup, latestUpdate: Date)? in
            guard let bucket = buckets[id], let index = order.firstIndex(of: id) else { return nil }
            return (
                index: index,
                group: PickyFullscreenSidebarGroup(id: id, label: bucket.label, sessions: bucket.sessions),
                latestUpdate: bucket.latestUpdate
            )
        }
        .sorted { lhs, rhs in
            if lhs.latestUpdate != rhs.latestUpdate { return lhs.latestUpdate > rhs.latestUpdate }
            return lhs.index < rhs.index
        }
        .map(\.group)
    }

    static func groupKey(for session: PickySessionListViewModel.SessionCard) -> (id: String, label: String) {
        let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cwd.isEmpty else {
            return ("unknown", "Unknown")
        }

        let url = URL(fileURLWithPath: NSString(string: cwd).expandingTildeInPath).standardizedFileURL
        let components = url.pathComponents.filter { $0 != "/" }

        if let worktreesIndex = components.firstIndex(of: ".worktrees"),
           components.indices.contains(components.index(after: worktreesIndex)) {
            let repoName = components[components.index(after: worktreesIndex)]
            return ("worktrees:\(repoName)", repoName)
        }

        let label = url.lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        if !label.isEmpty {
            return ("path:\(url.path)", label)
        }

        return ("path:\(cwd)", cwd)
    }
}
