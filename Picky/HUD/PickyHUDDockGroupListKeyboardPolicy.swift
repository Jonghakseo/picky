//
//  PickyHUDDockGroupListKeyboardPolicy.swift
//  Picky
//
//  Keyboard routing for the dock group list. Numbers, arrows, and Esc are all
//  context dependent: whichever surface is frontmost on the display owns them.
//  Keeping that decision here means the view never has to guess.
//

import Foundation

/// Which target set `Command-1`...`Command-9` and the hint overlay resolve
/// against right now.
enum PickyHUDDockShortcutContext: Equatable {
    case rail
    case groupList(groupID: String)

    var isGroupList: Bool {
        if case .groupList = self { return true }
        return false
    }
}

enum PickyHUDDockGroupListArrowDirection: Equatable {
    case up
    case down
}

/// The view maps this semantic choice to the design system's fast animation.
/// Keeping it value-based makes the Reduce Motion branch testable without a
/// live scroll view.
enum PickyHUDDockGroupListScrollMotion: Equatable {
    case none
    case fast
}

/// What `esc` should do, given what is currently open and focused.
enum PickyHUDDockEscapeOutcome: Equatable {
    case closeGroupList
    case passThrough
}

enum PickyHUDDockGroupListKeyboardPolicy {
    /// The list wins the number keys whenever it is open, so a folder's own
    /// number cannot both open the list and address a row in the same context.
    static func shortcutContext(openGroupID: String?) -> PickyHUDDockShortcutContext {
        guard let openGroupID else { return .rail }
        return .groupList(groupID: openGroupID)
    }

    /// Rows past the ninth are unreachable by number and show no hint, matching
    /// the rail's existing cap.
    static func shortcutNumber(forRowIndex index: Int) -> Int? {
        guard index >= 0, index < 9 else { return nil }
        return index + 1
    }

    static func rowID(forShortcutNumber number: Int, rowIDs: [String]) -> String? {
        guard number >= 1, number <= 9, number <= rowIDs.count else { return nil }
        return rowIDs[number - 1]
    }

    /// Opening a list highlights the Pickle already on screen when it belongs to
    /// this group, otherwise the first row.
    static func initialHighlight(rowIDs: [String], openedSessionID: String?) -> String? {
        if let openedSessionID, rowIDs.contains(openedSessionID) { return openedSessionID }
        return rowIDs.first
    }

    /// Arrow navigation clamps at both ends rather than wrapping.
    static func highlight(
        after direction: PickyHUDDockGroupListArrowDirection,
        current: String?,
        rowIDs: [String]
    ) -> String? {
        guard !rowIDs.isEmpty else { return nil }
        guard let current, let index = rowIDs.firstIndex(of: current) else {
            return direction == .down ? rowIDs.first : rowIDs.last
        }
        let next = direction == .down ? index + 1 : index - 1
        guard next >= 0, next < rowIDs.count else { return current }
        return rowIDs[next]
    }

    /// Membership changes must not strand the highlight on a row that is gone.
    static func reconciledHighlight(current: String?, rowIDs: [String]) -> String? {
        guard let current else { return rowIDs.first }
        return rowIDs.contains(current) ? current : rowIDs.first
    }

    static func scrollMotion(reduceMotion: Bool) -> PickyHUDDockGroupListScrollMotion {
        reduceMotion ? .none : .fast
    }

    /// The list only owns arrows and Return while no text input has focus, so
    /// the composer keeps its own editing keys.
    static func ownsListNavigationKeys(isListOpen: Bool, isTextInputFocused: Bool) -> Bool {
        isListOpen && !isTextInputFocused
    }

    /// Esc closes the list first, even while a text input is focused, and only
    /// then defers to the composer's or card's own Esc behavior.
    static func escapeOutcome(isListOpen: Bool) -> PickyHUDDockEscapeOutcome {
        isListOpen ? .closeGroupList : .passThrough
    }
}
