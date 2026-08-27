//
//  PickySessionViewModel+DockGroups.swift
//  Picky
//
//  Dock layout reconciliation and group mutation facade.
//

import Foundation

extension PickySessionListViewModel {
    /// Clear manual reorder for the dock so sessions fall back to creation
    /// time order. Useful as a "Reset order" menu action and from tests.
    func resetManualSessionOrder() {
        guard !manualOrder.isEmpty else { return }
        manualOrder = []
        manualOrderStore.manualOrder = []
        applyManualOrder()
    }

    // MARK: - Dock layout / groups

    /// Drop dock-layout references whose session id no longer exists and
    /// append brand-new active sessions at the bottom of the dock (= end of
    /// `entries`). Called after every `sessions` mutation so the persisted
    /// layout stays in lockstep with the daemon's session universe.
    ///
    /// First-run migration: when the persisted layout is empty but the
    /// legacy `manualOrder` UserDefaults has user-driven reorders, seed the
    /// layout from that ordering (reversed because manualOrder stores newest
    /// first and `entries` is top-down = oldest first). New sessions then
    /// fall through to the standard "append to end" branch below.
    internal func reconcileDockLayout() {
        guard dockLayoutReconciliationSuspensionDepth == 0 else { return }
        let changed = dockLayoutController.reconcile(
            activeSessionIDs: sessions.map(\.id),
            archivedSessionIDs: archivedSessions.map(\.id),
            legacyManualOrder: manualOrder
        )
        if changed { dockLayout = dockLayoutController.layout }
        drainPendingDockGroupAssignments()
    }

    /// V2 bootstrap is incremental, so admit only the session proven active by
    /// this snapshot. Full reconciliation would prune persisted group members
    /// whose own bootstrap snapshots have not arrived yet.
    internal func admitActiveSessionToDockLayout(_ sessionID: String) {
        let changed = dockLayoutController.admitActiveSessionIfMissing(sessionID)
        if changed { dockLayout = dockLayoutController.layout }
        drainPendingDockGroupAssignments()
    }

    func assignSessionToDockGroup(sessionID: String, groupName: String) {
        if !applyDockGroupAssignment(sessionID: sessionID, groupName: groupName) {
            pendingDockGroupAssignments[sessionID] = .groupName(groupName)
        }
    }

    /// Assign a newly-created Pickle to an exact dock group. Manual Pickle
    /// creation returns its session id before that session necessarily appears
    /// in the dock universe, so defer the move until reconciliation observes it.
    func assignSessionToDockGroup(sessionID: String, groupID: String) {
        if !applyDockGroupAssignment(sessionID: sessionID, groupID: groupID) {
            pendingDockGroupAssignments[sessionID] = .groupID(groupID)
        }
    }

    private func drainPendingDockGroupAssignments() {
        guard !pendingDockGroupAssignments.isEmpty else { return }
        for (sessionID, assignment) in Array(pendingDockGroupAssignments) {
            let applied: Bool
            switch assignment {
            case .groupName(let groupName):
                applied = applyDockGroupAssignment(sessionID: sessionID, groupName: groupName)
            case .groupID(let groupID):
                applied = applyDockGroupAssignment(sessionID: sessionID, groupID: groupID)
            }
            if applied {
                pendingDockGroupAssignments.removeValue(forKey: sessionID)
            }
        }
    }

    private func applyDockGroupAssignment(sessionID: String, groupName: String) -> Bool {
        guard dockLayout.allKnownSessionIDs.contains(sessionID) else { return false }
        let target = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return true }
        let existing = dockLayout.groups.first {
            $0.name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(target) == .orderedSame
        }
        let groupID = existing?.id ?? createDockGroup(name: target)
        let memberIndex = dockLayout.group(withID: groupID)?.memberSessionIDs.count ?? 0
        moveSessionInDock(sessionID: sessionID, to: .group(id: groupID, memberIndex: memberIndex))
        return true
    }

    private func applyDockGroupAssignment(sessionID: String, groupID: String) -> Bool {
        guard dockLayout.allKnownSessionIDs.contains(sessionID) else { return false }
        guard let group = dockLayout.group(withID: groupID) else {
            // The user may delete the target group while the folder picker or
            // child creation is in flight. Keep the Pickle at top level rather
            // than recreating a group the user explicitly removed.
            return true
        }
        moveSessionInDock(
            sessionID: sessionID,
            to: .group(id: groupID, memberIndex: group.memberSessionIDs.count)
        )
        return true
    }

    /// Create a new group at the bottom of the dock (just above the `+`
    /// slot) with the next color in rotation. `memberSessionIDs` may include
    /// sessions that already live elsewhere in the layout — they are atomic
    /// ally removed from their previous container and inserted into the new
    /// group in the order provided. Returns the new group's id so callers
    /// can focus a rename input on it or run further operations.
    @discardableResult
    func createDockGroup(name: String = "", withMemberIDs memberSessionIDs: [String] = []) -> String {
        let groupID = dockLayoutController.createGroup(name: name, withMemberIDs: memberSessionIDs)
        dockLayout = dockLayoutController.layout
        return groupID
    }

    func renameDockGroup(id: String, to name: String) {
        guard dockLayoutController.renameGroup(id: id, to: name) else { return }
        dockLayout = dockLayoutController.layout
    }

    func setDockGroupColor(id: String, color: PickyDockGroupColor) {
        guard dockLayoutController.setGroupColor(id: id, color: color) else { return }
        dockLayout = dockLayoutController.layout
    }

    /// Remove a group. When `keepMembers` is true, the members are spliced
    /// back into the top-level layout at the group's previous position (the
    /// "Ungroup" action). When false, the group's member sessions are
    /// archived too ("Delete group + archive pickles").
    func removeDockGroup(id: String, keepMembers: Bool) {
        beginDockStateMutation()
        defer { endDockStateMutation() }

        let removedMemberIDs = dockLayoutController.removeGroup(id: id, keepMembers: keepMembers)
        dockLayout = dockLayoutController.layout
        if !keepMembers {
            for memberID in removedMemberIDs {
                archive(sessionID: memberID)
            }
        }
    }

    /// Move a session to an explicit dock container/position. Used by the
    /// drag handler after it hit-tests the cursor against the current
    /// rendered slots.
    func moveSessionInDock(sessionID: String, to destination: PickyDockContainer) {
        guard dockLayoutController.moveSession(sessionID: sessionID, to: destination) else { return }
        dockLayout = dockLayoutController.layout
    }

    /// Reorder a group as a whole within the top-level layout. `target` is
    /// the post-removal index (0 = top of dock).
    func moveDockGroup(id: String, toTopLevelIndex target: Int) {
        guard dockLayoutController.moveGroup(id: id, toTopLevelIndex: target) else { return }
        dockLayout = dockLayoutController.layout
    }

}
