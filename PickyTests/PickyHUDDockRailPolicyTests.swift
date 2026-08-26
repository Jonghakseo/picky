//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//

import AppKit
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
            let horizontalCrossSize = PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
                groupCount: groupCount,
                metrics: metrics
            )
            let expectedCrossSize: CGFloat
            switch preset {
            case .small: expectedCrossSize = 68
            case .medium: expectedCrossSize = 77
            case .large: expectedCrossSize = 90
            }

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
            // Independently calculated from the folder's actual cross-axis
            // stack: tile plus both outer paddings, then its header chrome.
            #expect(horizontalCrossSize == expectedCrossSize)
            #expect(horizontalCrossSize >= metrics.sessionTileHeight + (metrics.horizontalPadding * 2)
                + metrics.groupHeaderHitAreaHeight + metrics.groupHeaderContentSpacing)
        }
    }

    @Test func groupHeaderFitsFourCJKCharactersAtEveryDockPreset() {
        let font = PickyHUDDockGroupHeaderPresentation.labelFont(fontScale: 1)
        let fourCJKCharactersWidth = ("가나다라" as NSString).size(withAttributes: [.font: font]).width

        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            let availableLabelWidth = PickyHUDDockGroupHeaderPresentation.labelWidth(metrics: metrics)

            // Measure the actual AppKit font paired with the SwiftUI label
            // role, rather than relying on a brittle point-width constant.
            #expect(availableLabelWidth >= fourCJKCharactersWidth, "\(preset) header truncates before four CJK characters")
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

    @Test func structuralTopEntryChangeCancelsFrozenDragGeometry() {
        let reference = ["session:a", "group:group", "session:b"]

        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: reference,
            currentTopEntryIDs: ["session:a", "session:new", "group:group", "session:b"]
        ))
        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: reference,
            currentTopEntryIDs: ["session:a", "session:b"]
        ))
        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: reference,
            currentTopEntryIDs: ["group:group", "session:a", "session:b"]
        ))
        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: [],
            currentTopEntryIDs: ["session:a"]
        ) == false)
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
