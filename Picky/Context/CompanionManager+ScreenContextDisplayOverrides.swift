//
//  CompanionManager+ScreenContextDisplayOverrides.swift
//  Picky
//

import AppKit
import CoreGraphics

@MainActor
extension CompanionManager {
    /// True during PTT recording or while Quick Input is open.
    var isCapturingScreenContext: Bool {
        voiceState == .listening || isQuickInputPanelVisible
    }

    func isScreenIncludedAsContext(
        displayID: CGDirectDisplayID,
        isFocused: Bool,
        hasInk: Bool
    ) -> Bool {
        PickyScreenContextInclusionPolicy.isSentAsContext(
            scope: screenContextScope,
            onlyWhenInked: attachScreenshotsOnlyWhenInked,
            isFocused: isFocused,
            hasInk: hasInk,
            displayOverride: screenContextDisplayOverrides[displayID]
        )
    }

    func toggleScreenContextDisplay(
        displayID: CGDirectDisplayID,
        isFocused: Bool,
        hasInk: Bool
    ) {
        let isIncluded = isScreenIncludedAsContext(
            displayID: displayID,
            isFocused: isFocused,
            hasInk: hasInk
        )
        screenContextDisplayOverrides[displayID] = isIncluded ? .excluded : .included
    }

    func updateScreenContextFocusedDisplayID(_ displayID: CGDirectDisplayID?) {
        guard screenContextFocusedDisplayID != displayID else { return }
        screenContextFocusedDisplayID = displayID
    }

    func resetScreenContextDisplayOverrides() {
        screenContextDisplayOverrides = [:]
    }

    /// Freezes the effective display IDs while topology and AppKit pointer state
    /// are still synchronous. ScreenCaptureKit may enumerate later, but it must
    /// not widen this submitted turn's context.
    func captureScreenContextDisplaySelectionSnapshot(
        inkCapture: PickyInkCapture?,
        displayOverrides: PickyScreenContextDisplayOverrides
    ) -> PickyScreenContextDisplaySelectionSnapshot {
        let pointerLocation = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let pointerDisplayID = screens.first(where: { $0.frame.contains(pointerLocation) })?.pickyDisplayID
        let displays = screens.compactMap { screen -> PickyScreenContextDisplaySelectionSnapshot.Display? in
            guard let id = screen.pickyDisplayID else { return nil }
            return .init(id: id, frame: screen.frame)
        }
        let inkGlobalPoints = (inkCapture?.strokes ?? []).flatMap { stroke in
            stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        }
        return .capture(
            scope: screenContextScope,
            onlyWhenInked: attachScreenshotsOnlyWhenInked,
            displays: displays,
            pointerLocation: pointerLocation,
            focusedDisplayID: pointerDisplayID ?? screenContextFocusedDisplayID,
            inkGlobalPoints: inkGlobalPoints,
            displayOverrides: displayOverrides
        )
    }

    func setScreenContextControlHitTest(_ hitTest: ((CGPoint) -> Bool)?) {
        screenContextControlHitTest = hitTest ?? { _ in false }
    }
}
