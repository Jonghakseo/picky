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
            (firstDisplay, CGSize(width: 168, height: 450)),
            (PickyHUDPlacement(dockSide: .left), CGSize(width: 168, height: 450)),
            (secondDisplay, CGSize(width: 450, height: 66)),
            (PickyHUDPlacement(dockSide: .top), CGSize(width: 450, height: 66))
        ] {
            let origin = PickyHUDPlacement.minimizedButtonOrigin(
                dockSide: placement.dockSide, metrics: metrics, railSize: size
            )
            let buttonCenter = CGPoint(x: origin.x + 16, y: origin.y + 16)
            if placement.dockSide.orientation == .vertical {
                #expect(buttonCenter.x == (placement.dockSide == .left ? 18 : size.width - 18))
                #expect(buttonCenter.y == metrics.handleInset / 2)
            } else {
                #expect(buttonCenter.x == 10)
                #expect(buttonCenter.y == (placement.dockSide == .top ? 18 : size.height - 18))
            }
        }

        firstDisplay.isMinimized = false
        #expect(!firstDisplay.isMinimized)
        #expect(!secondDisplay.isMinimized)
    }
}
