//
//  PickyHUDDockNewPicklePopoverPolicy.swift
//  Picky
//
//  Selects the one anchor that owns the shared new-Pickle popover.
//

enum PickyHUDDockGroupTilePresentation: Equatable {
    case empty
    case singleSession(sessionID: String)
    case folder

    static func resolve(visibleMemberIDs: [String]) -> Self {
        switch visibleMemberIDs.count {
        case 0: .empty
        case 1: .singleSession(sessionID: visibleMemberIDs[0])
        default: .folder
        }
    }
}

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
