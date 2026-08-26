//
//  PickyHUDDockGroupListFocusStore.swift
//  Picky
//
//  Mirrors the manager-owned group list open state back into the SwiftUI views
//  that need it. The HUD root needs it to route number keys, arrows, and Esc;
//  the list panel needs it to paint the highlight. Keeping one published
//  snapshot per display keeps those two surfaces from disagreeing.
//

import Combine
import CoreGraphics
import Foundation

struct PickyHUDDockGroupListFocus: Equatable {
    var openGroupID: String?
    var rowIDs: [String] = []
    var highlightedRowID: String?

    var isOpen: Bool { openGroupID != nil }
}

@MainActor
final class PickyHUDDockGroupListFocusStore: ObservableObject {
    @Published private(set) var focusByDisplayID: [CGDirectDisplayID: PickyHUDDockGroupListFocus] = [:]

    func focus(for displayID: CGDirectDisplayID?) -> PickyHUDDockGroupListFocus {
        guard let displayID else { return PickyHUDDockGroupListFocus() }
        return focusByDisplayID[displayID] ?? PickyHUDDockGroupListFocus()
    }

    func open(displayID: CGDirectDisplayID, groupID: String, rowIDs: [String], openedSessionID: String?) {
        focusByDisplayID[displayID] = PickyHUDDockGroupListFocus(
            openGroupID: groupID,
            rowIDs: rowIDs,
            highlightedRowID: PickyHUDDockGroupListKeyboardPolicy.initialHighlight(
                rowIDs: rowIDs,
                openedSessionID: openedSessionID
            )
        )
    }

    /// Membership changes while the list stays open: keep the highlight when its
    /// row survived, otherwise fall back to the first row.
    func updateRows(displayID: CGDirectDisplayID, rowIDs: [String]) {
        guard var focus = focusByDisplayID[displayID], focus.isOpen else { return }
        focus.rowIDs = rowIDs
        focus.highlightedRowID = PickyHUDDockGroupListKeyboardPolicy.reconciledHighlight(
            current: focus.highlightedRowID,
            rowIDs: rowIDs
        )
        focusByDisplayID[displayID] = focus
    }

    func moveHighlight(displayID: CGDirectDisplayID?, direction: PickyHUDDockGroupListArrowDirection) -> String? {
        guard let displayID, var focus = focusByDisplayID[displayID], focus.isOpen else { return nil }
        let next = PickyHUDDockGroupListKeyboardPolicy.highlight(
            after: direction,
            current: focus.highlightedRowID,
            rowIDs: focus.rowIDs
        )
        focus.highlightedRowID = next
        focusByDisplayID[displayID] = focus
        return next
    }

    func close(displayID: CGDirectDisplayID) {
        focusByDisplayID.removeValue(forKey: displayID)
    }

    func closeAll() {
        focusByDisplayID.removeAll()
    }
}
