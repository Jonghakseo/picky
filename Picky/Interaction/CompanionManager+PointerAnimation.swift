//
//  CompanionManager+PointerAnimation.swift
//  Picky
//
//  Reducer-driven pointer/annotation animation surface, split out of
//  CompanionManager to keep the facade under the architecture line-count line.
//

import Foundation

@MainActor
extension CompanionManager {
    /// Applies the reducer-owned pointer target to the existing BlueCursorView.
    /// Clearing the id first cancels stale view callbacks without feeding a second
    /// completion event back into the reducer.
    func startPointerAnimation(target: PickyPointerTarget) {
        detectedElementPointerID = nil
        detectedElementDisplayFrame = target.displayFrame
        detectedElementBubbleText = target.bubbleText
        detectedElementDisplayDuration = target.duration
        detectedElementReturnsToCursor = target.returnsToCursor
        detectedElementParksAtTarget = target.parksAtTarget
        detectedElementScreenLocation = target.screenLocation
        detectedElementPointerID = target.id
        setLocalOverlayReason(.activePointerAnimation, visible: true)
    }

    func setPointerReturnsToCursor(pointerID: String, returnsToCursor: Bool) {
        guard detectedElementPointerID == pointerID else { return }
        detectedElementReturnsToCursor = returnsToCursor
    }

    func setPointerParksAtTarget(pointerID: String, parksAtTarget: Bool) {
        guard detectedElementPointerID == pointerID else { return }
        detectedElementParksAtTarget = parksAtTarget
    }

    /// Records that the view has finished hovering and is holding this annotation target.
    func parkPointerAnimation(pointerID: String) {
        guard detectedElementPointerID == pointerID else { return }
        interactionCoordinator.accept(
            .pointerAnimationParked(pointerID: pointerID),
            correlation: PickyInteractionCorrelation(pointerID: pointerID, source: .pointer)
        )
    }

    /// Advances an annotation sequence without clearing visual target properties, so the
    /// buddy can fly directly from its current shape to the next queued shape.
    func advancePointerAnimation(pointerID: String) {
        guard detectedElementPointerID == pointerID else { return }
        interactionCoordinator.accept(
            .pointerAnimationFinished(pointerID: pointerID),
            correlation: PickyInteractionCorrelation(pointerID: pointerID, source: .pointer)
        )
    }

    func cancelPointerAnimation(pointerID: String?) {
        guard pointerID == nil || detectedElementPointerID == pointerID else { return }
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementDisplayDuration = nil
        detectedElementReturnsToCursor = true
        detectedElementParksAtTarget = false
        detectedElementPointerID = nil
        setLocalOverlayReason(.activePointerAnimation, visible: false)
        scheduleTransientHideIfNeeded()
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    func clearDetectedElementLocation(pointerID: String? = nil) {
        if let pointerID, detectedElementPointerID != pointerID { return }
        let clearedPointerID = detectedElementPointerID
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementDisplayDuration = nil
        detectedElementReturnsToCursor = true
        detectedElementParksAtTarget = false
        detectedElementPointerID = nil
        if let clearedPointerID {
            interactionCoordinator.accept(
                .pointerAnimationFinished(pointerID: clearedPointerID),
                correlation: PickyInteractionCorrelation(pointerID: clearedPointerID, source: .pointer)
            )
        }
        setLocalOverlayReason(.activePointerAnimation, visible: false)
        scheduleTransientHideIfNeeded()
    }
}
