//
//  CompanionManager+PendingInkCapture.swift
//  Picky
//

import Foundation

@MainActor
extension CompanionManager {
    /// Retains a completed PTT ink capture until its matching context packet is
    /// assembled. The store is keyed by input ID to reject stale submissions.
    func finishInkCapture(inputID: UUID?) {
        let capture = inkCaptureCoordinator.finish()
        if let inputID, let capture, capture.hasVisibleInk {
            pendingInkCaptures.store(capture, for: inputID)
        }
        setLocalOverlayReason(.activeInkCapture, visible: false)
    }

    func finishInkCaptureForDeferredTextSubmission() -> PickyInkCapture? {
        let capture = inkCaptureCoordinator.finish()
        setLocalOverlayReason(.activeInkCapture, visible: false)
        return capture?.hasVisibleInk == true ? capture : nil
    }
}
