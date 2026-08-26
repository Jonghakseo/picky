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

    /// A persisted layout can carry several expanded groups from the old
    /// collapse model. Keep the first in dock order and close the rest.
    static func normalizedLegacyOpenState(
        groupIDsInDockOrder: [String],
        expandedGroupIDs: Set<String>
    ) -> String? {
        groupIDsInDockOrder.first { expandedGroupIDs.contains($0) }
    }
}
