//
//  PickyHUDDockGroupListHoverPolicy.swift
//  Picky
//
//  Hover disclosure for dock folders. A peek is a transient pointer-owned
//  presentation; a pin is a deliberate one. Only a pin takes the keyboard, so
//  the rail keeps Command-numbers, arrows, and Escape while a peek is showing.
//

import CoreGraphics
import Foundation

enum PickyHUDDockGroupListPresentation: Equatable {
    /// Opened by hovering the folder. Closes on its own once the pointer
    /// leaves, and never registers with the keyboard focus store.
    case peek
    /// Opened or confirmed by keyboard activation. Survives pointer movement
    /// and owns the list keyboard context until explicitly dismissed.
    case pinned
}

enum PickyHUDDockGroupListHoverPolicy {
    /// How long the pointer may sit outside the corridor before a peek closes.
    static let peekGrace: TimeInterval = 0.25
    /// Corridor sampling interval while a peek is open.
    static let peekPollInterval: TimeInterval = 0.1

    /// Hover never disturbs a pinned list: the user asked for that one
    /// explicitly, and the rail sits next to the work area where an accidental
    /// pass would otherwise replace it. A folder with no visible member routes
    /// to the create popover on click and has no list to disclose.
    static func shouldBeginPeek(
        hoveredGroupID: String,
        openGroupID: String?,
        presentation: PickyHUDDockGroupListPresentation?,
        hasVisibleMembers: Bool
    ) -> Bool {
        guard hasVisibleMembers else { return false }
        if presentation == .pinned { return false }
        return openGroupID != hoveredGroupID || presentation == nil
    }

    /// An explicit keyboard activation promotes a hover peek to a pinned list.
    /// Pointer interaction remains transient so leaving the folder corridor
    /// always closes a mouse-opened list.
    static func presentationAfterExplicitPin(
        current: PickyHUDDockGroupListPresentation?
    ) -> PickyHUDDockGroupListPresentation? {
        guard current != nil else { return nil }
        return .pinned
    }

    /// A regular Pickle tile is a more specific pointer target than the broad
    /// folder-panel corridor. Entering one ends only pointer-owned disclosure.
    static func shouldCloseForDockSessionHover(
        presentation: PickyHUDDockGroupListPresentation?
    ) -> Bool {
        presentation == .peek
    }

    /// The folder and its panel are separated by `panelGap`, so pointer
    /// containment alone would drop the peek mid-travel. Their bounding union
    /// spans that gap and stays generous on the diagonal, which is the path a
    /// pointer actually takes toward the panel.
    static func isPointerInPeekCorridor(
        pointer: CGPoint,
        folderScreenFrame: CGRect?,
        panelScreenFrame: CGRect
    ) -> Bool {
        guard pointer.x.isFinite, pointer.y.isFinite else { return false }
        guard let folderScreenFrame, !folderScreenFrame.isEmpty else {
            return panelScreenFrame.contains(pointer)
        }
        guard !panelScreenFrame.isEmpty else { return folderScreenFrame.contains(pointer) }
        return folderScreenFrame.union(panelScreenFrame).contains(pointer)
    }

    /// A peek closes only after the pointer has been continuously outside the
    /// corridor for the grace window, so a pause between the folder and the
    /// panel never dismisses it.
    static func shouldClosePeek(
        presentation: PickyHUDDockGroupListPresentation?,
        isPointerInCorridor: Bool,
        outsideSince: Date?,
        now: Date,
        grace: TimeInterval = peekGrace
    ) -> Bool {
        guard presentation == .peek, !isPointerInCorridor, let outsideSince else { return false }
        return now.timeIntervalSince(outsideSince) >= grace
    }

    /// Tracks the moment the pointer first left the corridor. Re-entering
    /// clears it so the next exit starts a fresh grace window.
    static func outsideSince(
        current: Date?,
        isPointerInCorridor: Bool,
        now: Date
    ) -> Date? {
        if isPointerInCorridor { return nil }
        return current ?? now
    }
}
