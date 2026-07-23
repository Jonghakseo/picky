//
//  PickyScreenContextInclusionPolicy.swift
//  Picky
//
//  Single source of truth for "does this display go to the model as context".
//  Both the capture pipeline and the capture-context border read from here so
//  the invariant holds: a display's border is shown exactly when its pixels are
//  sent as context.
//
//  Two independent settings compose into that decision:
//    - screenContextScope (.allScreens / .focusedScreen): which displays are
//      capture candidates. Focused scope still captures any display the user
//      inked, so drawing on a secondary monitor pulls it into context.
//    - attachScreenshotsOnlyWhenInked: when on, only displays the user actually
//      drew on survive the attachment gate.
//

import CoreGraphics
import Foundation

/// Immutable topology-derived display set for one submitted input. Capture
/// enumeration may happen later, but it can only capture these display IDs.
struct PickyScreenContextDisplaySelectionSnapshot: Equatable {
    struct Display: Equatable {
        let id: CGDirectDisplayID
        let frame: CGRect
    }

    let includedDisplayIDs: Set<CGDirectDisplayID>

    static func capture(
        scope: PickyScreenContextScope,
        onlyWhenInked: Bool,
        displays: [Display],
        pointerLocation: CGPoint?,
        focusedDisplayID: CGDirectDisplayID?,
        inkGlobalPoints: [CGPoint],
        displayOverrides: PickyScreenContextDisplayOverrides
    ) -> Self {
        let focusedID = focusedDisplayID
            ?? displays.first(where: { display in
                pointerLocation.map(display.frame.contains) == true
            })?.id
        let hasAutomaticCandidate = displays.contains { display in
            PickyScreenContextInclusionPolicy.isCaptureCandidate(
                scope: scope,
                isFocused: display.id == focusedID,
                hasInk: inkGlobalPoints.contains(where: display.frame.contains)
            )
        }
        let fallbackFocusedID = scope == .focusedScreen && !hasAutomaticCandidate
            ? displays.first?.id
            : nil
        return Self(includedDisplayIDs: Set(displays.compactMap { display in
            PickyScreenContextInclusionPolicy.isSentAsContext(
                scope: scope,
                onlyWhenInked: onlyWhenInked,
                isFocused: display.id == focusedID || display.id == fallbackFocusedID,
                hasInk: inkGlobalPoints.contains(where: display.frame.contains),
                displayOverride: displayOverrides[display.id]
            ) ? display.id : nil
        }))
    }
}

enum PickyScreenContextDisplayOverride: Equatable {
    case included
    case excluded
}

typealias PickyScreenContextDisplayOverrides = [CGDirectDisplayID: PickyScreenContextDisplayOverride]

enum PickyScreenContextInclusionPolicy {
    /// Whether a display's pixels are eligible to be captured at all. Focused
    /// scope captures the cursor display plus any display carrying ink; all-
    /// screens scope captures every display.
    static func isCaptureCandidate(
        scope: PickyScreenContextScope,
        isFocused: Bool,
        hasInk: Bool
    ) -> Bool {
        scope == .allScreens || isFocused || hasInk
    }

    /// Whether a captured display survives the ink-only attachment gate. With
    /// the gate off every candidate is kept; with it on only inked displays are.
    static func passesInkAttachmentGate(
        onlyWhenInked: Bool,
        hasInk: Bool
    ) -> Bool {
        !onlyWhenInked || hasInk
    }

    /// Whether a display's pixels are actually sent to the model as context.
    /// This is the composition of the two stages above and drives the
    /// capture-context border.
    static func isSentAsContext(
        scope: PickyScreenContextScope,
        onlyWhenInked: Bool,
        isFocused: Bool,
        hasInk: Bool,
        displayOverride: PickyScreenContextDisplayOverride? = nil
    ) -> Bool {
        switch displayOverride {
        case .included:
            return true
        case .excluded:
            return false
        case nil:
            return isCaptureCandidate(scope: scope, isFocused: isFocused, hasInk: hasInk)
                && passesInkAttachmentGate(onlyWhenInked: onlyWhenInked, hasInk: hasInk)
        }
    }
}
