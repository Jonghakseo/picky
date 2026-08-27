//
//  PickyHUDSessionRemovalPolicy.swift
//  Picky
//
//  Replay-safe cleanup for session-scoped HUD-local interaction state.
//

import Foundation

struct PickyHUDSessionRemovalState: Equatable {
    var heldSession: PickyHUDDockHold?
    var pendingManualAutoOpenSessionID: String?
    var pendingRequestedOpenSessionID: String?
    var hoverPreviewSessionID: String?
    var suppressedHoverSessionID: String?
    var utilityPanelOpenSessionIDs: Set<String>
}

enum PickyHUDSessionRemovalPolicy {
    /// Returns nil for an already-consumed event. The caller persists the
    /// returned revision, so an old removal cannot clear a same-ID session
    /// after it is rehydrated in a later snapshot.
    static func applying(
        _ event: PickyHUDDockRemovalEvent?,
        after handledRevision: UInt64,
        to state: PickyHUDSessionRemovalState
    ) -> (state: PickyHUDSessionRemovalState, handledRevision: UInt64)? {
        guard let event, event.revision > handledRevision else { return nil }
        let removedSessionIDs = event.sessionIDs
        var next = state
        if next.heldSession.map({ removedSessionIDs.contains($0.sessionID) }) == true {
            next.heldSession = nil
        }
        if next.pendingManualAutoOpenSessionID.map(removedSessionIDs.contains) == true {
            next.pendingManualAutoOpenSessionID = nil
        }
        if next.pendingRequestedOpenSessionID.map(removedSessionIDs.contains) == true {
            next.pendingRequestedOpenSessionID = nil
        }
        if next.hoverPreviewSessionID.map(removedSessionIDs.contains) == true {
            next.hoverPreviewSessionID = nil
        }
        if next.suppressedHoverSessionID.map(removedSessionIDs.contains) == true {
            next.suppressedHoverSessionID = nil
        }
        next.utilityPanelOpenSessionIDs.subtract(removedSessionIDs)
        return (next, event.revision)
    }
}
