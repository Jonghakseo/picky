//
//  PickyDockGroupCLIPolicy.swift
//  Picky
//
//  Pure snapshot and validation policy for CLI-managed Pickle dock groups.
//

import Foundation

enum PickyDockGroupCLIPolicy {
    static func snapshot(for layout: PickyDockLayout) -> [PickyDockGroupPayload] {
        layout.groups.map { group in
            PickyDockGroupPayload(
                id: group.id,
                name: group.name,
                color: group.colorRaw,
                memberSessionIds: group.memberSessionIDs,
                collapsed: group.isCollapsed
            )
        }
    }

    static func validatedName(_ value: String?) throws -> String {
        let name = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !name.isEmpty else { throw PickyDockGroupManagementError.emptyGroupName }
        return name
    }

    static func validatedGroup(id value: String?, in layout: PickyDockLayout) throws -> PickyDockGroup {
        let groupID = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !groupID.isEmpty else { throw PickyDockGroupManagementError.emptyGroupID }
        guard let group = layout.group(withID: groupID) else {
            throw PickyDockGroupManagementError.groupNotFound(groupID)
        }
        return group
    }

    static func validateKnownSessionIDs(
        _ sessionIDs: [String],
        activeSessionIDs: [String],
        archivedSessionIDs: [String]
    ) throws {
        let knownSessionIDs = Set(activeSessionIDs + archivedSessionIDs)
        for sessionID in sessionIDs where !knownSessionIDs.contains(sessionID) {
            throw PickyDockGroupManagementError.sessionNotFound(sessionID)
        }
    }

    static func validateMembers(_ sessionIDs: [String], in group: PickyDockGroup) throws {
        guard !sessionIDs.isEmpty else { throw PickyDockGroupManagementError.emptySessionIDs }
        for sessionID in sessionIDs where !group.memberSessionIDs.contains(sessionID) {
            throw PickyDockGroupManagementError.sessionNotInGroup(sessionID: sessionID, groupID: group.id)
        }
    }
}

enum PickyDockGroupManagementError: LocalizedError, Equatable {
    case emptyGroupName
    case emptyGroupID
    case emptySessionIDs
    case groupNotFound(String)
    case sessionNotFound(String)
    case sessionNotInGroup(sessionID: String, groupID: String)

    var errorDescription: String? {
        switch self {
        case .emptyGroupName:
            "A non-empty Pickle group name is required."
        case .emptyGroupID:
            "An exact Pickle group ID is required."
        case .emptySessionIDs:
            "At least one Pickle session ID is required."
        case .groupNotFound(let groupID):
            "Pickle group not found: \(groupID)"
        case .sessionNotFound(let sessionID):
            "Pickle session not found: \(sessionID)"
        case .sessionNotInGroup(let sessionID, let groupID):
            "Pickle session \(sessionID) is not a member of group \(groupID)."
        }
    }
}
