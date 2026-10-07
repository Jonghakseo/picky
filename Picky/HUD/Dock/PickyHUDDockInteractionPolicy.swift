//
//  PickyHUDDockInteractionPolicy.swift
//  Picky
//
//  Pure HUD dock interaction transitions. Layout math stays in
//  PickyHUDDockLayout; held/open state policy lives here.
//

import Foundation

enum PickyHUDDockHoverDisclosurePolicy {
    static let closeGrace: TimeInterval = 0.4
    static let closeGraceNanoseconds: UInt64 = 400_000_000
}

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

/// Shared enablement projection for the per-Pickle dock menu.
struct PickyHUDDockSessionActionAvailability: Equatable {
    let canCompact: Bool
    let canStop: Bool

    static func resolve(status: PickySessionStatus, canRequestCompaction: Bool) -> Self {
        Self(
            canCompact: canRequestCompaction,
            canStop: !status.isTerminal
        )
    }
}

enum PickyHUDDockInteractionPolicy {
    static func activeSessionID(visibleIDs: [String], held: PickyHUDDockHold?) -> String? {
        guard let held, visibleIDs.contains(held.sessionID) else { return nil }
        return held.sessionID
    }

    static func heldSessionAfterCloseTimeout(current: PickyHUDDockHold?, isHUDHovered: Bool) -> PickyHUDDockHold? {
        // Manually held sessions stay open when the pointer leaves.
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
