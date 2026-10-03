//
//  PickyHUDDockGroupListChildEffectExecutor.swift
//  Picky
//
//  Executes the dock group child-list lifecycle effects. The overlay manager
//  supplies production effects while tests can observe the same boundary
//  without constructing or showing an AppKit panel.
//

import Foundation

@MainActor
final class PickyHUDDockGroupListChildEffectExecutor {
    struct OpeningEffects {
        let tearDown: () -> Void
        let updateModel: () -> Void
        let synchronizeHost: () -> Void
        let position: () -> Void
        let present: () -> Void
    }

    struct SynchronizationEffects {
        let tearDown: () -> Void
        let updateModel: () -> Void
        let updateFocus: () -> Void
        let position: () -> Void
    }

    struct PendingEffects {
        let tearDown: () -> Void
        let updatePendingGroupID: (String) -> Void
        let open: (String) -> Void
    }

    func open(
        groupID: String,
        visibleRowIDs: [String],
        effects: OpeningEffects
    ) {
        guard case .keepOpen = PickyHUDDockGroupListOpenPolicy.reconciliation(
            openGroupID: groupID,
            visibleRowIDs: visibleRowIDs
        ) else {
            effects.tearDown()
            return
        }
        effects.updateModel()
        effects.synchronizeHost()
        effects.position()
        effects.present()
    }

    func synchronize(
        groupID: String,
        visibleRowIDs: [String],
        effects: SynchronizationEffects
    ) {
        guard case .keepOpen = PickyHUDDockGroupListOpenPolicy.reconciliation(
            openGroupID: groupID,
            visibleRowIDs: visibleRowIDs
        ) else {
            effects.tearDown()
            return
        }
        effects.updateModel()
        effects.updateFocus()
        effects.position()
    }

    /// Returns whether a pending request was handled. A pending request is
    /// always consumed here so callers never continue into open-list syncing.
    @discardableResult
    func reconcilePending(
        pendingGroupID: String?,
        existingGroupIDs: Set<String>,
        visibleMemberGroupIDs: Set<String>,
        effects: PendingEffects
    ) -> Bool {
        guard let pendingGroupID else { return false }
        guard let reconciledGroupID = PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
            pendingGroupID,
            existingGroupIDs: existingGroupIDs,
            visibleMemberGroupIDs: visibleMemberGroupIDs
        ) else {
            effects.tearDown()
            return true
        }
        effects.updatePendingGroupID(reconciledGroupID)
        effects.open(reconciledGroupID)
        return true
    }
}
