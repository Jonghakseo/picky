//
//  PickyHUDDockNewPicklePopoverPolicy.swift
//  Picky
//
//  Selects the one anchor that owns the shared new-Pickle popover.
//

enum PickyHUDDockNewPicklePopoverPolicy {
    static func isPresented(
        pickerIsPresented: Bool,
        activeTargetGroupID: String?,
        anchorGroupID: String?
    ) -> Bool {
        pickerIsPresented && activeTargetGroupID == anchorGroupID
    }

    static func shouldExpandDockAddSlot(
        pickerIsPresented: Bool,
        activeTargetGroupID: String?
    ) -> Bool {
        isPresented(
            pickerIsPresented: pickerIsPresented,
            activeTargetGroupID: activeTargetGroupID,
            anchorGroupID: nil
        )
    }
}
