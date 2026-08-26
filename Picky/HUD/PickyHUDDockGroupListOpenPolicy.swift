//
//  PickyHUDDockGroupListOpenPolicy.swift
//  Picky
//
//  Display-local open state for the dock group list panel. At most one group
//  list is open per display, and the panel is independent of whichever Pickle
//  the conversation card currently shows.
//

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
    /// as its group leaves the layout.
    static func reconciledPendingGroupID(_ pendingGroupID: String?, existingGroupIDs: Set<String>) -> String? {
        guard let pendingGroupID, existingGroupIDs.contains(pendingGroupID) else { return nil }
        return pendingGroupID
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
