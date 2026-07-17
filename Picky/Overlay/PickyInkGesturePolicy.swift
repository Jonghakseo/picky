//
//  PickyInkGesturePolicy.swift
//  Picky
//
//  Pure ownership state machine for a single physical mouse click-drag while
//  Picky's ink capture is armed. Ownership is decided once at mouse-down and
//  held until mouse-up so a gesture never gets split between Picky's ink and
//  the app underneath — even when the cursor crosses into or out of the Quick
//  Input / HUD pass-through region mid-drag.
//
//  Kept side-effect free so the branching can be exercised without a live
//  CGEvent tap.
//

import Foundation

/// Who owns the current physical mouse gesture while ink capture is armed.
enum PickyInkGesturePhase: Equatable {
    /// No gesture in flight; the next mouse-down decides ownership.
    case idle
    /// Picky owns this click-drag: suppress it from the app and draw ink.
    case ink
    /// The gesture started over an interactive Picky surface (Quick Input pill
    /// or HUD): let the app/panel handle every event until release.
    case passthrough
    /// A malformed gesture — typically a drag that arrived with no matching
    /// mouse-down because capture armed a beat late. Suppressed (so the app
    /// cannot keep extending a selection) but never drawn.
    case invalid
}

/// Normalized mouse event the ownership machine reasons about.
enum PickyInkGestureInput: Equatable {
    case leftDown
    case leftDragged
    case leftUp
    /// Pointer motion with no button held.
    case moved
    /// Any non-left button activity (right/other/scroll).
    case other
}

/// Whether the resolved event should reach the app underneath or be swallowed.
enum PickyInkGestureAction: Equatable {
    case passThrough
    case suppress
}

/// Stroke bookkeeping the controller should apply for this event.
enum PickyInkStrokeCommand: Equatable {
    case begin
    case update
    case finish
}

struct PickyInkGestureDecision: Equatable {
    let phase: PickyInkGesturePhase
    let action: PickyInkGestureAction
    let strokeCommand: PickyInkStrokeCommand?
}

enum PickyInkGesturePolicy {
    /// Resolve the next ownership phase, delivery action, and stroke command for
    /// an incoming mouse event.
    ///
    /// - Parameters:
    ///   - phase: Ownership phase carried over from the previous event.
    ///   - input: The normalized incoming mouse event.
    ///   - isOverPassThroughRegion: True when the pointer currently sits over an
    ///     interactive Picky surface that should keep receiving clicks (Quick
    ///     Input pill or HUD). Only consulted when a gesture is *starting* or
    ///     between gestures; an in-flight gesture keeps its original owner.
    static func decide(
        phase: PickyInkGesturePhase,
        input: PickyInkGestureInput,
        isOverPassThroughRegion: Bool
    ) -> PickyInkGestureDecision {
        switch input {
        case .leftDown:
            // Ownership is decided here and held for the whole gesture.
            if isOverPassThroughRegion {
                return PickyInkGestureDecision(phase: .passthrough, action: .passThrough, strokeCommand: nil)
            }
            return PickyInkGestureDecision(phase: .ink, action: .suppress, strokeCommand: .begin)

        case .leftDragged:
            switch phase {
            case .passthrough:
                return PickyInkGestureDecision(phase: .passthrough, action: .passThrough, strokeCommand: nil)
            case .ink:
                return PickyInkGestureDecision(phase: .ink, action: .suppress, strokeCommand: .update)
            case .idle, .invalid:
                // Drag with no owning mouse-down: capture armed late. Suppress so
                // the app cannot keep extending a text selection, but draw nothing.
                return PickyInkGestureDecision(phase: .invalid, action: .suppress, strokeCommand: nil)
            }

        case .leftUp:
            switch phase {
            case .passthrough:
                return PickyInkGestureDecision(phase: .idle, action: .passThrough, strokeCommand: nil)
            case .ink:
                return PickyInkGestureDecision(phase: .idle, action: .suppress, strokeCommand: .finish)
            case .idle, .invalid:
                return PickyInkGestureDecision(phase: .idle, action: .suppress, strokeCommand: nil)
            }

        case .moved, .other:
            // Between gestures the pointer may glide over the Quick Input pill or
            // HUD; let those surfaces stay hoverable. Phase is untouched.
            let action: PickyInkGestureAction = isOverPassThroughRegion ? .passThrough : .suppress
            return PickyInkGestureDecision(phase: phase, action: action, strokeCommand: nil)
        }
    }
}
