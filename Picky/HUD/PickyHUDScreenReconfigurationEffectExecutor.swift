//
//  PickyHUDScreenReconfigurationEffectExecutor.swift
//  Picky
//
//  Keeps screen reconfiguration ordering explicit: every parent HUD must have
//  its new frame before an anchored child list reads that parent frame.
//

import CoreGraphics
import Foundation

@MainActor
final class PickyHUDScreenReconfigExecutor {
    struct Effects {
        let removeParent: (CGDirectDisplayID) -> Void
        let removeToast: (CGDirectDisplayID) -> Void
        let removeChild: (CGDirectDisplayID) -> Void
        let synchronizeParent: (CGDirectDisplayID) -> Void
        let synchronizeChild: (CGDirectDisplayID) -> Void
        let synchronizeToast: (CGDirectDisplayID) -> Void
    }

    func synchronize(
        liveDisplayIDs: Set<CGDirectDisplayID>,
        parentDisplayIDs: Set<CGDirectDisplayID>,
        toastDisplayIDs: Set<CGDirectDisplayID>,
        childDisplayIDs: Set<CGDirectDisplayID>,
        effects: Effects
    ) {
        for displayID in parentDisplayIDs.subtracting(liveDisplayIDs) {
            effects.removeParent(displayID)
        }
        for displayID in toastDisplayIDs.subtracting(liveDisplayIDs) {
            effects.removeToast(displayID)
        }
        for displayID in childDisplayIDs.subtracting(liveDisplayIDs) {
            effects.removeChild(displayID)
        }

        // A child panel is anchored to its owning HUD panel, so do not let it
        // observe stale parent geometry during a display reconfiguration.
        for displayID in liveDisplayIDs {
            effects.synchronizeParent(displayID)
        }
        for displayID in liveDisplayIDs.intersection(toastDisplayIDs) {
            effects.synchronizeToast(displayID)
        }
        for displayID in liveDisplayIDs.intersection(childDisplayIDs) {
            effects.synchronizeChild(displayID)
        }
    }
}
