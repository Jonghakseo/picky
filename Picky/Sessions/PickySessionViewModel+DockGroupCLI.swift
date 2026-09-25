//
//  PickySessionViewModel+DockGroupCLI.swift
//  Picky
//
//  CLI group mutation orchestration over the app-owned dock layout.
//

import Foundation

@MainActor
extension PickySessionListViewModel {
    func dockGroupsSnapshotForCLI() -> [PickyDockGroupPayload] {
        PickyDockGroupCLIPolicy.snapshot(for: dockLayout)
    }

    /// Applies main-agent group operations through the same controller used by
    /// dock drag/drop, so there is one persisted layout source of truth.
    func manageDockGroups(_ request: PickyDockGroupManagementRequest) async throws -> [PickyDockGroupPayload] {
        switch request.action {
        case .list:
            break
        case .create:
            let name = try PickyDockGroupCLIPolicy.validatedName(request.name)
            try PickyDockGroupCLIPolicy.validateKnownSessionIDs(
                request.sessionIds,
                activeSessionIDs: sessions.map(\.id),
                archivedSessionIDs: archivedSessions.map(\.id)
            )
            _ = try await dockLayoutController.createGroupPersisting(name: name, withMemberIDs: request.sessionIds)
            dockLayout = dockLayoutController.layout
        case .addMembers:
            let group = try PickyDockGroupCLIPolicy.validatedGroup(id: request.groupId, in: dockLayout)
            try PickyDockGroupCLIPolicy.validateKnownSessionIDs(
                request.sessionIds,
                activeSessionIDs: sessions.map(\.id),
                archivedSessionIDs: archivedSessions.map(\.id)
            )
            guard !request.sessionIds.isEmpty else { throw PickyDockGroupManagementError.emptySessionIDs }
            guard try await dockLayoutController.addSessionsPersisting(request.sessionIds, toGroup: group.id) else { break }
            dockLayout = dockLayoutController.layout
        case .removeMembers:
            let group = try PickyDockGroupCLIPolicy.validatedGroup(id: request.groupId, in: dockLayout)
            try PickyDockGroupCLIPolicy.validateMembers(request.sessionIds, in: group)
            guard try await dockLayoutController.removeSessionsFromGroupPersisting(request.sessionIds) else { break }
            dockLayout = dockLayoutController.layout
        case .removeGroup:
            let group = try PickyDockGroupCLIPolicy.validatedGroup(id: request.groupId, in: dockLayout)
            _ = try await dockLayoutController.removeGroupPersisting(id: group.id, keepMembers: true)
            dockLayout = dockLayoutController.layout
        case .archiveGroup:
            let group = try PickyDockGroupCLIPolicy.validatedGroup(id: request.groupId, in: dockLayout)
            beginDockStateMutation()
            defer { endDockStateMutation() }
            dockLayoutReconciliationSuspensionDepth += 1
            defer {
                dockLayoutReconciliationSuspensionDepth -= 1
                reconcileDockLayout()
            }
            // Owner changes are not reversible by a failed local save. Keep the
            // group until every member has settled and the layout save succeeds.
            for sessionID in group.memberSessionIDs where !archivedSessions.contains(where: { $0.id == sessionID }) {
                try await archiveSessionConfirmed(sessionID: sessionID, mode: request.archiveMode)
            }
            _ = try await dockLayoutController.removeGroupPersisting(id: group.id, keepMembers: false)
            dockLayout = dockLayoutController.layout
        }
        return dockGroupsSnapshotForCLI()
    }
}
