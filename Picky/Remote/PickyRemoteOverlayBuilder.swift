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
    /// The gateway validates `hub.overlay` against a schema and drops the whole
    /// message when any array is too long, so a Mac with thousands of archived
    /// Pickles would silently stop updating the phone. Mirrors the limits in
    /// `agentd/src/remote/hub-protocol.ts`.
    enum Limits {
        static let activeSessions = 2000
        static let archivedSessions = 5000
        static let unreadSessions = 2000
        static let groups = 200
        static let groupMembers = 2000
        static let groupNameCharacters = 200
        static let folders = 100
    }

    static func build(
        activeSessionIDs: [String],
        archivedSessionIDs: [String],
        unreadSessionIDs: Set<String>,
        dockLayout: PickyDockLayout,
        pinnedFolders: [String],
        recentFolders: [String]
    ) -> PickyRemoteOverlaySnapshot {
        // Mac Dock order, not the registry's: the phone list keeps rows where the
        // dock keeps tiles, so a reply arriving never moves a Pickle. Group
        // members stay contiguous, which is how the phone rebuilds its sections.
        let active = PickyDockProjector.cycleSessionIDs(
            layout: dockLayout,
            activeSessionIDs: deduplicated(activeSessionIDs)
        )
        let activeSet = Set(active)
        // A session can only be in one list. The archive list wins for an id
        // that somehow appears in both so the phone never shows it twice.
        let archived = deduplicated(archivedSessionIDs)
        let archivedSet = Set(archived)
        let knownIDs = activeSet.union(archivedSet)

        let groups = dockLayout.groups.prefix(Limits.groups).map { group in
            PickyRemoteOverlayGroup(
                id: group.id,
                name: String(group.displayName.prefix(Limits.groupNameCharacters)),
                color: String(describing: group.color),
                memberIds: Array(
                    deduplicated(group.memberSessionIDs)
                        .filter { knownIDs.contains($0) }
                        .prefix(Limits.groupMembers)
                )
            )
        }

        let activeIDs = Array(active.filter { !archivedSet.contains($0) }.prefix(Limits.activeSessions))

        return PickyRemoteOverlaySnapshot(
            activeSessionIds: activeIDs,
            archivedSessionIds: Array(archived.prefix(Limits.archivedSessions)),
            // Unread for a session the phone cannot see would be a badge with
            // nothing behind it.
            unreadSessionIds: Array(activeIDs.filter { unreadSessionIDs.contains($0) }.prefix(Limits.unreadSessions)),
            groups: Array(groups),
            folders: PickyRemoteOverlayFolders(
                pinned: Array(deduplicated(pinnedFolders).prefix(Limits.folders)),
                recent: Array(deduplicated(recentFolders).prefix(Limits.folders))
            )
        )
    }

    private static func deduplicated(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}
