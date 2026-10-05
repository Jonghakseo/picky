//
//  PickyRemoteOverlayBuilder.swift
//  Picky
//
//  Pure projection from app-owned state into the `hub.overlay` payload. The
//  gateway uses it to decide which rooms exist, which are archived, and which
//  still have unread activity; it carries nothing the session projection
//  already streams.
//

import Foundation

enum PickyRemoteOverlayBuilder {
    static func build(
        activeSessionIDs: [String],
        archivedSessionIDs: [String],
        unreadSessionIDs: Set<String>,
        dockLayout: PickyDockLayout,
        pinnedFolders: [String],
        recentFolders: [String]
    ) -> PickyRemoteOverlaySnapshot {
        let active = deduplicated(activeSessionIDs)
        let activeSet = Set(active)
        // A session can only be in one list. The archive list wins for an id
        // that somehow appears in both so the phone never shows it twice.
        let archived = deduplicated(archivedSessionIDs)
        let archivedSet = Set(archived)
        let knownIDs = activeSet.union(archivedSet)

        let groups = dockLayout.groups.map { group in
            PickyRemoteOverlayGroup(
                id: group.id,
                name: group.displayName,
                color: String(describing: group.color),
                memberIds: deduplicated(group.memberSessionIDs).filter { knownIDs.contains($0) }
            )
        }

        return PickyRemoteOverlaySnapshot(
            activeSessionIds: active.filter { !archivedSet.contains($0) },
            archivedSessionIds: archived,
            // Unread for a session the phone cannot see would be a badge with
            // nothing behind it.
            unreadSessionIds: active.filter { unreadSessionIDs.contains($0) },
            groups: groups,
            folders: PickyRemoteOverlayFolders(
                pinned: deduplicated(pinnedFolders),
                recent: deduplicated(recentFolders)
            )
        )
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
