//
//  PickyHUDDockMinimizationTests.swift
//  PickyTests
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockMinimizationTests {
    @Test func minimizedDockStaysOnExpandedHandleAcrossOrientationsAndDisplays() {
        let firstDisplay = PickyHUDPlacement(dockSide: .right)
        let secondDisplay = PickyHUDPlacement(dockSide: .bottom)
        let metrics = PickyHUDDockMetrics(preset: .medium)

        firstDisplay.isMinimized = true
        #expect(firstDisplay.isMinimized)
        #expect(!secondDisplay.isMinimized)

        for (placement, size) in [
            (firstDisplay, CGSize(width: 58, height: 450)),
            (secondDisplay, CGSize(width: 450, height: 58))
        ] {
            let origin = PickyHUDPlacement.minimizedButtonOrigin(
                dockSide: placement.dockSide, metrics: metrics, railSize: size
            )
            let buttonCenter = CGPoint(x: origin.x + 16, y: origin.y + 16)
            if placement.dockSide.orientation == .vertical {
                #expect(buttonCenter.x == size.width / 2)
                #expect(buttonCenter.y == metrics.handleInset / 2)
            } else {
                #expect(buttonCenter.x == metrics.handleInset / 2)
                #expect(buttonCenter.y == size.height / 2)
            }
        }

        firstDisplay.isMinimized = false
        #expect(!firstDisplay.isMinimized)
        #expect(!secondDisplay.isMinimized)
    }
}
