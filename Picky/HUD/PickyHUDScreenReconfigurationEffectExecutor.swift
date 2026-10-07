//
//  PickyHUDScreenReconfigurationEffectExecutor.swift
//  Picky
//
//  Keeps screen reconfiguration ordering explicit: disconnected displays are
//  torn down before live parents are repositioned, and toasts follow their
//  parent's new frame.
//

import CoreGraphics
import Foundation

@MainActor
final class PickyHUDScreenReconfigExecutor {
    struct Effects {
        let removeParent: (CGDirectDisplayID) -> Void
        let removeToast: (CGDirectDisplayID) -> Void
        let synchronizeParent: (CGDirectDisplayID) -> Void
        let synchronizeToast: (CGDirectDisplayID) -> Void
    }

    func synchronize(
        liveDisplayIDs: Set<CGDirectDisplayID>,
        parentDisplayIDs: Set<CGDirectDisplayID>,
        toastDisplayIDs: Set<CGDirectDisplayID>,
        effects: Effects
    ) {
        for displayID in parentDisplayIDs.subtracting(liveDisplayIDs) {
            effects.removeParent(displayID)
        }
        for displayID in toastDisplayIDs.subtracting(liveDisplayIDs) {
            effects.removeToast(displayID)
        }
        // A toast is anchored to its owning HUD panel, so it must not observe
        // stale parent geometry during a display reconfiguration.
        for displayID in liveDisplayIDs {
            effects.synchronizeParent(displayID)
        }
        for displayID in liveDisplayIDs.intersection(toastDisplayIDs) {
            effects.synchronizeToast(displayID)
        }
    }
}
