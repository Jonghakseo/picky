//
//  PickyHUDDockGroupListOpenPolicy.swift
//  Picky
//
//  Display-local open state for the dock group list panel. At most one group
//  list is open per display, and the panel is independent of whichever Pickle
//  the conversation card currently shows.
//

enum PickyHUDDockGroupListOpenReconciliation: Equatable {
    /// Tear down before the panel model can receive an empty row projection.
    case tearDown
    case keepOpen(groupID: String)
}

enum PickyHUDDockGroupListOpenPolicy {
    /// Tapping the owning folder closes the list; tapping another folder
    /// replaces it with no intermediate closed state.
    static func toggled(openGroupID: String?, tappedGroupID: String) -> String? {
        openGroupID == tappedGroupID ? nil : tappedGroupID
    }

    /// Selecting a row opens the Pickle and closes the list, so the card is
    /// never left covered.
    static func afterSelectingRow(openGroupID: String?) -> String? {
        _ = openGroupID
        return nil
    }

    /// An open card outside the folder makes the list stale. All card-opening
    /// paths converge on the geometry update, so this rule remains independent
    /// of the initiating shortcut, rail tile, or daemon request.
    static func afterOpeningSession(
        openGroupID: String?,
        openedSessionID: String?,
        memberSessionIDs: [String]
    ) -> String? {
        guard let openGroupID, let openedSessionID else { return openGroupID }
        return memberSessionIDs.contains(openedSessionID) ? openGroupID : nil
    }

    /// The geometry update that carries the open card also fires for rail
    /// reflow that has nothing to do with the card, so the rule must key off
    /// the transition rather than the standing value. Re-running it on every
    /// report closed a list the user had deliberately opened over an unrelated
    /// card, which also tore down an in-flight member drag.
    static func afterOpeningSession(
        openGroupID: String?,
        previousOpenedSessionID: String?,
        openedSessionID: String?,
        memberSessionIDs: [String]
    ) -> String? {
        guard previousOpenedSessionID != openedSessionID else { return openGroupID }
        return afterOpeningSession(
            openGroupID: openGroupID,
            openedSessionID: openedSessionID,
            memberSessionIDs: memberSessionIDs
        )
    }

    /// The list cannot outlive its group.
    static func afterGroupRemoved(openGroupID: String?, removedGroupID: String) -> String? {
        openGroupID == removedGroupID ? nil : openGroupID
    }

    /// Anything that invalidates the folder anchor closes the list rather than
    /// re-anchoring, so the panel never appears to drift on its own.
    static func afterAnchorInvalidated() -> String? { nil }

    /// A folder tap that arrives before SwiftUI publishes its anchor remains
    /// pending. A newer tap simply replaces the prior pending request.
    static func pendingGroupID(afterRequestFor groupID: String) -> String { groupID }

    /// A pending request survives missing geometry, but is discarded as soon
    /// as its group leaves the layout or loses every visible Pickle. This keeps
    /// an empty child panel from appearing when a stale anchor arrives.
    static func reconciledPendingGroupID(
        _ pendingGroupID: String?,
        existingGroupIDs: Set<String>,
        visibleMemberGroupIDs: Set<String>
    ) -> String? {
        guard let pendingGroupID,
              existingGroupIDs.contains(pendingGroupID),
              visibleMemberGroupIDs.contains(pendingGroupID)
        else { return nil }
        return pendingGroupID
    }

    /// A group-list child exists while at least one visible row remains. A
    /// single remaining Pickle may render as a full dock tile while retaining
    /// the same hover list. Callers tear down before updating an empty model.
    static func reconciliation(
        openGroupID: String?,
        visibleRowIDs: [String]
    ) -> PickyHUDDockGroupListOpenReconciliation {
        guard let openGroupID, !visibleRowIDs.isEmpty else { return .tearDown }
        return .keepOpen(groupID: openGroupID)
    }

    /// Geometry completes a pending open only when both the folder frame and
    /// the rail frame are available.
    static func pendingGroupIDReadyToOpen(
        _ pendingGroupID: String?,
        anchoredGroupIDs: Set<String>,
        hasRailFrame: Bool
    ) -> String? {
        guard hasRailFrame,
              let pendingGroupID,
              anchoredGroupIDs.contains(pendingGroupID)
        else { return nil }
        return pendingGroupID
    }
}
