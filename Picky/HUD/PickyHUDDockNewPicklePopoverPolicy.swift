//
//  PickyHUDDockNewPicklePopoverPolicy.swift
//  Picky
//
//  Selects the one anchor that owns the shared new-Pickle popover.
//

enum PickyHUDDockGroupTileAction: Equatable {
    case showFolderPicker
    case toggleMemberList
}

enum PickyHUDDockNewPicklePopoverPolicy {
    /// A group without a visible member has no list to disclose. Its one rail
    /// slot is instead the targeted create affordance while remaining a drag
    /// destination in the projection.
    static func groupTileAction(hasVisibleMembers: Bool) -> PickyHUDDockGroupTileAction {
        hasVisibleMembers ? .toggleMemberList : .showFolderPicker
    }

    static func isPresented(
        pickerIsPresented: Bool,
        activeAnchorGroupID: String?,
        anchorGroupID: String?
    ) -> Bool {
        pickerIsPresented && activeAnchorGroupID == anchorGroupID
    }

    static func shouldExpandDockAddSlot(
        pickerIsPresented: Bool,
        activeAnchorGroupID: String?
    ) -> Bool {
        isPresented(
            pickerIsPresented: pickerIsPresented,
            activeAnchorGroupID: activeAnchorGroupID,
            anchorGroupID: nil
        )
    }
}
