//
//  CompanionManager+ScreenContextDisplayOverrides.swift
//  Picky
//

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

    func setScreenContextControlHitTest(_ hitTest: ((CGPoint) -> Bool)?) {
        screenContextControlHitTest = hitTest ?? { _ in false }
    }
}
