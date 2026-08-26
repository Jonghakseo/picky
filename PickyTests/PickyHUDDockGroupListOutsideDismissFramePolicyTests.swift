//
//  PickyHUDDockGroupListOutsideDismissFramePolicyTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

struct PickyHUDDockGroupListOutsideDismissFramePolicyTests {
    @Test func productionDismissFrameUsesTheFullInteractionFrame() {
        let interaction = CGRect(x: 10, y: 20, width: 54, height: 82)
        let hudFrame = CGRect(x: 100, y: 200, width: 400, height: 300)

        let result = PickyHUDDockGroupListOutsideDismissFramePolicy.owningInteractionScreenFrame(
            openGroupID: "group",
            interactionFrames: ["group": interaction],
            hudPanelFrame: hudFrame
        )

        #expect(result == PickyHUDDockGroupListScreenLayout.screenFrame(
            hudPanelFrame: hudFrame,
            swiftUIOrigin: interaction.origin,
            panelSize: interaction.size
        ))
    }
}
