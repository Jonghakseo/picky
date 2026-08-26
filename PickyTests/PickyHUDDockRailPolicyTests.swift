//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockRailPolicyTests {
    @Test func groupHeadersAddOnlyPerGroupChromeForEveryPresetAndOrientation() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            let groupCount = 2
            let vertical = PickyHUDDockRailLayoutPolicy.contentLength(
                sessionCount: 4,
                groupCount: groupCount,
                isAddSlotExpanded: false,
                dockSide: .left,
                metrics: metrics
            )
            let horizontal = PickyHUDDockRailLayoutPolicy.contentLength(
                sessionCount: 4,
                groupCount: groupCount,
                isAddSlotExpanded: false,
                dockSide: .bottom,
                metrics: metrics
            )

            #expect(vertical == PickyHUDDockLayout.dockRailHeight(
                sessionCount: 4,
                isAddSlotExpanded: false,
                metrics: metrics
            ) + PickyHUDDockLayout.dockGroupHeaderExtraLength(
                groupHeaderCount: groupCount,
                metrics: metrics
            ))
            #expect(horizontal == PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: 4,
                isAddSlotExpanded: false,
                metrics: metrics
            ))
            #expect(PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
                groupCount: groupCount,
                metrics: metrics
            ) == PickyHUDDockLayout.horizontalDockRailCrossSize(
                hasGroupHeaders: true,
                metrics: metrics
            ))
        }
    }

    @Test func groupReorderUsesFrozenTopEntryCentersWhenPreviewHasReflowed() {
        let layout = PickyDockLayout(entries: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "group", memberSessionIDs: ["archived", "visible"])),
            .session(id: "b")
        ])
        let entryIDs = PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: [
            .session(id: "a"),
            .group(PickyDockGroup(id: "group", memberSessionIDs: ["archived", "visible"])),
            .session(id: "b")
        ])
        let frozenCenters: [String: CGFloat] = [
            "session:a": 40,
            "group:group": 124,
            "session:b": 232
        ]

        let destination = PickyHUDDockRenderPolicy.nearestLayoutEntryIndex(
            cursorAxis: 218,
            visibleTopEntryIDs: entryIDs,
            referenceCenters: frozenCenters,
            layout: layout
        )

        #expect(destination == 2)
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
