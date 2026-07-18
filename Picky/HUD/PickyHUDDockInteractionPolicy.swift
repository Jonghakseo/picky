//
//  PickyHUDDockInteractionPolicy.swift
//  Picky
//
//  Pure HUD dock interaction transitions. Layout math stays in
//  PickyHUDDockLayout; held/open/hover state policy lives here.
//

import Foundation

/// Timing and geometry constants for the dock's hold-to-archive interaction.
enum PickyHUDArchiveHoldPolicy {
    static let duration: TimeInterval = 1.2
    static let feedbackStartDelay: TimeInterval = 0.2
    static let feedbackStartDelayNanoseconds: UInt64 = 200_000_000
    static let maximumDistance: CGFloat = 10
    static let ringGapStartFraction = 0.22
    static let ringUsableFraction = 0.73

    static var feedbackAnimationDuration: TimeInterval {
        max(0, duration - feedbackStartDelay)
    }
}

enum PickyHUDDockInteractionPolicy {
    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?, previewID: String?) -> String? {
        if let held, visibleIDs.contains(held.sessionID) { return held.sessionID }
        if let previewID, visibleIDs.contains(previewID) { return previewID }
        return nil
    }

    static func previewSessionID(hoveredID: String?, heldID: String?) -> String? {
        heldID == nil ? hoveredID : nil
    }

    static func previewSessionIDAfterDockHover(current: String?, sessionID: String) -> String? {
        sessionID
    }

    static func previewSessionIDAfterCloseTimeout(current: String?, isDockHovered: Bool) -> String? {
        isDockHovered ? current : nil
    }

    static func heldSessionAfterCloseTimeout(current: PickyHUDDockHold?, isHUDHovered: Bool) -> PickyHUDDockHold? {
        // Timeout clears transient hover preview state only; manually held sessions stay open.
        current
    }

    static func heldSessionAfterClick(current: PickyHUDDockHold?, clicked: String) -> PickyHUDDockHold? {
        switch current {
        case .open(clicked):
            return nil
        case .open, nil:
            return .open(clicked)
        }
    }

    static func manualAutoOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        guard let pendingSessionID, visibleIDs.contains(pendingSessionID) else { return nil }
        return .open(pendingSessionID)
    }

    static func requestedOpenResolution(pendingSessionID: String?, visibleIDs: [String]) -> PickyHUDDockHold? {
        guard let pendingSessionID, visibleIDs.contains(pendingSessionID) else { return nil }
        return .open(pendingSessionID)
    }

    static func numberShortcutForSessionIndex(_ index: Int) -> Int? {
        guard index >= 0, index < 9 else { return nil }
        return index + 1
    }

    static func sessionIDForNumberShortcut(visibleIDs: [String], number: Int) -> String? {
        guard number >= 1, number <= visibleIDs.count else { return nil }
        return visibleIDs[number - 1]
    }

    static func heldSessionAfterNumberShortcut(current: PickyHUDDockHold?, visibleIDs: [String], number: Int) -> PickyHUDDockHold? {
        guard let targetID = sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: number) else { return current }
        return heldSessionAfterClick(current: current, clicked: targetID)
    }

    static func heldSessionAfterCycleShortcut(current: PickyHUDDockHold?, visibleIDs: [String], direction: Int) -> PickyHUDDockHold? {
        guard !visibleIDs.isEmpty else { return current }
        let currentIndex = current.flatMap { held in visibleIDs.firstIndex(of: held.sessionID) }
        let baseIndex = currentIndex ?? (direction >= 0 ? -1 : 0)
        let nextIndex = (baseIndex + direction + visibleIDs.count) % visibleIDs.count
        return .open(visibleIDs[nextIndex])
    }
}
