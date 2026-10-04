//
//  PickyOverlayVisibilityPolicy.swift
//  Picky
//
//  Pure decision rules for cursor overlay visibility. No state, no window
//  effects — `PickyOverlayVisibilityController` owns both.
//

import Foundation

enum PickyOverlayVisibilityPolicy {
    /// Reasons that represent an interaction still in flight. While any of them
    /// is active the transient-hide timer must not tear the overlay down.
    static let transientHideBlockers: Set<PickyOverlayReason> = [
        .activeVoiceInput,
        .waitingForVoiceResponse,
        .speakingResponse,
        .activePointerAnimation,
        .activeInkCapture,
        .screenContextTarget
    ]

    /// Visible reasons are the union of locally driven reasons (settings,
    /// permissions, ink, voice, screen-context target) and the reasons the
    /// interaction reducer projects.
    static func visibleReasons(
        local: Set<PickyOverlayReason>,
        interaction: Set<PickyOverlayReason>
    ) -> Set<PickyOverlayReason> {
        local.union(interaction)
    }

    /// The overlay is on screen exactly while at least one reason holds it up.
    static func shouldShowOverlay(for reasons: Set<PickyOverlayReason>) -> Bool {
        !reasons.isEmpty
    }

    static func blocksTransientHide(_ reasons: Set<PickyOverlayReason>) -> Bool {
        !reasons.intersection(transientHideBlockers).isEmpty
    }

    /// Flattens an interaction overlay phase into the reasons it contributes.
    /// A `.hiding` phase still contributes its reason so the overlay stays up
    /// until the reducer finishes the hide.
    static func interactionReasons(for phase: PickyOverlayPhase) -> Set<PickyOverlayReason> {
        switch phase {
        case .hidden:
            return []
        case .visible(let reasons):
            return reasons
        case .hiding(_, let reason):
            return [reason]
        }
    }
}
