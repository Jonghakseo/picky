//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockRailPolicyTests {
    @Test func railLengthUsesOnlyTopLevelSlotCountForEveryPresetAndOrientation() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for dockSide in [PickyHUDDockSide.left, .bottom] {
                let actual = PickyHUDDockRailLayoutPolicy.contentLength(
                    sessionCount: 4,
                    isAddSlotExpanded: false,
                    dockSide: dockSide,
                    metrics: metrics
                )
                let expected: CGFloat = dockSide.orientation == .vertical
                    ? PickyHUDDockLayout.dockRailHeight(sessionCount: 4, isAddSlotExpanded: false, metrics: metrics)
                    : PickyHUDDockLayout.horizontalDockRailLength(sessionCount: 4, isAddSlotExpanded: false, metrics: metrics)
                #expect(actual == expected)
            }
        }
    }

    @Test func dragGeometryRespectsDockAxisAndOutwardDirection() {
        let translation = CGSize(width: 30, height: 45)
        let metrics = PickyHUDDockMetrics(preset: .medium)

        #expect(PickyHUDDockDragGeometry.axisDelta(translation, orientation: .horizontal) == 30)
        #expect(PickyHUDDockDragGeometry.axisDelta(translation, orientation: .vertical) == 45)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .left) == 30)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .right) == -30)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .top) == 45)
        #expect(PickyHUDDockDragGeometry.pullOutDistance(translation, dockSide: .bottom) == -45)
        #expect(PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics) == metrics.railWidth * 0.5 + 40)
    }
}
