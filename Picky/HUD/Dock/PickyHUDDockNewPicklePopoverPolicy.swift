//
//  PickyHUDDockNewPicklePopoverPolicy.swift
//  Picky
//
//  Selects the one anchor that owns the shared new-Pickle popover.
//

enum PickyHUDDockNewPicklePopoverPolicy {
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
