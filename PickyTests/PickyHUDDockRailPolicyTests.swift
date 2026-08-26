//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyHUDDockRailPolicyTests {
    @Test func folderLabelsUseTheRenderedIdentityFontForEveryPresetAndAppFontScale() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            let groupCount = 2
            for fontScale: CGFloat in [1, 1.3] {
                let vertical = PickyHUDDockRailLayoutPolicy.contentLength(
                    sessionCount: 4,
                    groupCount: groupCount,
                    isAddSlotExpanded: false,
                    dockSide: .left,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let horizontal = PickyHUDDockRailLayoutPolicy.contentLength(
                    sessionCount: 4,
                    groupCount: groupCount,
                    isAddSlotExpanded: false,
                    dockSide: .bottom,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let horizontalCrossSize = PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
                    groupCount: groupCount,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let folderCrossSize = max(
                    metrics.railWidth,
                    metrics.sessionTileHeight + (metrics.horizontalPadding * 2)
                )
                let renderedFont = PickyHUDDockGroupHeaderPresentation.labelFont(fontScale: fontScale)
                let renderedLineHeight = renderedFont.ascender - renderedFont.descender + renderedFont.leading
                let labelHeight = PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics,
                    fontScale: fontScale
                )
                let labelChrome = labelHeight + metrics.groupHeaderContentSpacing

                #expect(labelHeight >= renderedLineHeight)
                #expect(vertical == PickyHUDDockLayout.dockRailHeight(
                    sessionCount: 4,
                    isAddSlotExpanded: false,
                    metrics: metrics
                ) + PickyHUDDockLayout.dockGroupHeaderExtraLength(
                    groupHeaderCount: groupCount,
                    metrics: metrics,
                    fontScale: fontScale
                ))
                #expect(horizontal == PickyHUDDockLayout.horizontalDockRailLength(
                    sessionCount: 4,
                    isAddSlotExpanded: false,
                    metrics: metrics
                ))
                // A label below the tile grows only the cross axis in horizontal
                // orientation and never contributes one unit per member.
                #expect(horizontalCrossSize == folderCrossSize + labelChrome)
            }
        }
    }

    @Test func railLengthDependsOnProjectedTopLevelSlotsNotGroupMemberCount() {
        let compactLayout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "alpha", memberSessionIDs: ["a"])),
            .group(PickyDockGroup(id: "beta", memberSessionIDs: ["b"]))
        ])
        let expandedLayout = PickyDockLayout(entries: [
            .group(PickyDockGroup(id: "alpha", memberSessionIDs: ["a", "c", "d", "e", "f"])),
            .group(PickyDockGroup(id: "beta", memberSessionIDs: ["b", "g", "h", "i", "j"]))
        ])
        let compactProjection = PickyDockProjector.project(
            layout: compactLayout,
            visibleSessionIDs: ["a", "b"]
        )
        let expandedProjection = PickyDockProjector.project(
            layout: expandedLayout,
            visibleSessionIDs: ["a", "b", "c", "d", "e", "f", "g", "h", "i", "j"]
        )
        let metrics = PickyHUDDockMetrics(preset: .large)

        #expect(compactProjection.items.count == 2)
        #expect(compactProjection.slots.count == 2)
        #expect(expandedProjection.items.count == 2)
        #expect(expandedProjection.slots.count == 2)
        #expect(PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: compactProjection.slots.count,
            groupCount: compactProjection.items.count,
            isAddSlotExpanded: false,
            dockSide: .left,
            metrics: metrics,
            fontScale: 1
        ) == PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: expandedProjection.slots.count,
            groupCount: expandedProjection.items.count,
            isAddSlotExpanded: false,
            dockSide: .left,
            metrics: metrics,
            fontScale: 1
        ))
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

    @Test func persistedStructureIgnoresPreviewOnlyGroupReorder() {
        let persisted = PickyDockProjection(
            items: [.session(id: "a"), .session(id: "b")],
            slots: []
        )
        let preview = PickyDockProjection(
            items: [.session(id: "b"), .session(id: "a")],
            slots: []
        )
        let persistedStructure = PickyHUDDockRenderPolicy.persistedStructure(in: persisted)

        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: persistedStructure.topEntryIDs,
            currentTopEntryIDs: persistedStructure.topEntryIDs
        ) == false)
        #expect(PickyHUDDockRenderPolicy.visibleTopEntryIDs(in: preview.items) != persistedStructure.topEntryIDs)
    }

    @Test func persistedStructureCancelsAFolderDragAfterStructuralChange() {
        let before = PickyDockProjection(
            items: [.session(id: "a"), .session(id: "b")],
            slots: []
        )
        let after = PickyDockProjection(
            items: [.session(id: "a"), .session(id: "new"), .session(id: "b")],
            slots: []
        )

        #expect(PickyHUDDockRenderPolicy.shouldCancelDrag(
            referenceTopEntryIDs: PickyHUDDockRenderPolicy.persistedStructure(in: before).topEntryIDs,
            currentTopEntryIDs: PickyHUDDockRenderPolicy.persistedStructure(in: after).topEntryIDs
        ))
    }

    @Test func reorderAnimationTargetsEveryNonDraggedTopLevelSibling() {
        let session = PickyDockRenderItem.session(id: "session")
        let group = PickyDockRenderItem.group(PickyDockGroup(id: "group"))

        #expect(PickyHUDDockReorderAnimationPolicy.shouldAnimate(
            item: group,
            draggingSessionID: "session",
            draggingGroupID: nil,
            reduceMotion: false
        ))
        #expect(PickyHUDDockReorderAnimationPolicy.shouldAnimate(
            item: session,
            draggingSessionID: nil,
            draggingGroupID: "group",
            reduceMotion: false
        ))
        #expect(!PickyHUDDockReorderAnimationPolicy.shouldAnimate(
            item: group,
            draggingSessionID: nil,
            draggingGroupID: "group",
            reduceMotion: false
        ))
        #expect(!PickyHUDDockReorderAnimationPolicy.shouldAnimate(
            item: session,
            draggingSessionID: "session",
            draggingGroupID: nil,
            reduceMotion: true
        ))
    }

    @Test func sessionDragNeverShrinksRailBelowPersistedSlotCount() {
        #expect(PickyHUDDockReorderAnimationPolicy.sizingSlotCount(
            renderedSlotCount: 3,
            persistedSlotCount: 4,
            isSessionDragging: true
        ) == 4)
        #expect(PickyHUDDockReorderAnimationPolicy.sizingSlotCount(
            renderedSlotCount: 5,
            persistedSlotCount: 4,
            isSessionDragging: true
        ) == 5)
        #expect(PickyHUDDockReorderAnimationPolicy.sizingSlotCount(
            renderedSlotCount: 3,
            persistedSlotCount: 4,
            isSessionDragging: false
        ) == 3)
    }

    @Test func cursorLockedOffsetCompensatesForCurrentGroupHomeOnBothAxes() {
        let translation = CGSize(width: 30, height: 45)

        #expect(PickyHUDDockDragGeometry.cursorLockedOffset(
            translation: translation,
            dragStartCenter: 100,
            currentHomeCenter: 140,
            orientation: .horizontal
        ) == CGSize(width: -10, height: 45))
        #expect(PickyHUDDockDragGeometry.cursorLockedOffset(
            translation: translation,
            dragStartCenter: 100,
            currentHomeCenter: 140,
            orientation: .vertical
        ) == CGSize(width: 30, height: 5))
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
        #expect(PickyHUDDockDragGeometry.groupDropHalfExtent(
            orientation: .horizontal,
            metrics: metrics,
            fontScale: 1
        ) == metrics.sessionTileWidth * 0.5)
        #expect(PickyHUDDockDragGeometry.groupDropHalfExtent(
            orientation: .vertical,
            metrics: metrics,
            fontScale: 1
        ) > metrics.sessionTileHeight * 0.5)
    }
}
