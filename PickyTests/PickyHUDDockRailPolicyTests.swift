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
                let verticalCrossSize = PickyHUDDockRailLayoutPolicy.verticalCrossSize(
                    groupCount: groupCount,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let horizontalCrossSize = PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
                    groupCount: groupCount,
                    metrics: metrics,
                    fontScale: fontScale
                )
                let labelWidth = PickyHUDDockGroupHeaderPresentation.labelWidth(
                    metrics: metrics,
                    fontScale: fontScale
                )
                let folderCrossSize = max(
                    metrics.railWidth,
                    labelWidth + (metrics.horizontalPadding * 2)
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
                // A CJK-safe label grows the rail's cross axis once per
                // folder block, never once per member.
                #expect(verticalCrossSize == folderCrossSize)
                #expect(horizontalCrossSize == folderCrossSize + labelChrome)
            }
        }
    }

    @Test func verticalRailLengthUsesHalfHeightForEmptyGroupSlotsOnly() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let fullVerticalLength = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 2,
            groupCount: 1,
            emptyGroupCount: 0,
            isAddSlotExpanded: false,
            dockSide: .left,
            metrics: metrics
        )
        let emptyVerticalLength = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 2,
            groupCount: 1,
            emptyGroupCount: 1,
            isAddSlotExpanded: false,
            dockSide: .left,
            metrics: metrics
        )
        let fullHorizontalLength = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 2,
            groupCount: 1,
            emptyGroupCount: 0,
            isAddSlotExpanded: false,
            dockSide: .bottom,
            metrics: metrics
        )
        let emptyHorizontalLength = PickyHUDDockRailLayoutPolicy.contentLength(
            sessionCount: 2,
            groupCount: 1,
            emptyGroupCount: 1,
            isAddSlotExpanded: false,
            dockSide: .bottom,
            metrics: metrics
        )

        #expect(fullVerticalLength - emptyVerticalLength == metrics.sessionTileHeight - metrics.emptyGroupSlotHeight)
        #expect(fullHorizontalLength == emptyHorizontalLength)
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

    @Test func groupHeaderFitsFourCJKCharactersAtEveryDockPresetAndFontScale() {
        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                let font = PickyHUDDockGroupHeaderPresentation.labelFont(fontScale: fontScale)
                let fourCJKCharactersWidth = ("가나다라" as NSString).size(withAttributes: [.font: font]).width
                let availableLabelWidth = PickyHUDDockGroupHeaderPresentation.labelWidth(
                    metrics: metrics,
                    fontScale: fontScale
                )

                // Measure the actual AppKit font paired with the SwiftUI label
                // role, rather than relying on a brittle point-width constant.
                #expect(
                    availableLabelWidth >= fourCJKCharactersWidth + metrics.groupHeaderContentSpacing,
                    "\(preset) at \(fontScale)x truncates before four CJK characters"
                )
            }
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

    @Test func adjacentTopLevelEntriesExposeInsertionTargetsAtFrozenMidpoints() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha")),
            .group(PickyDockGroup(id: "beta")),
        ])
        let candidates = PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: ["session:loose", "group:alpha", "group:beta"],
            referenceCenters: [
                "session:loose": 0,
                "group:alpha": 100,
                "group:beta": 200,
            ],
            draggedSessionID: "loose",
            layout: layout
        )

        #expect(candidates == [
            .init(topLevelIndex: 0, center: 50),
            .init(topLevelIndex: 1, center: 150),
        ])
    }

    @Test func adjacentUngroupedSessionsKeepExistingCenterBasedReorderPolicy() {
        let layout = PickyDockLayout(entries: [
            .session(id: "alpha"),
            .session(id: "beta"),
        ])

        #expect(PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: ["session:alpha", "session:beta"],
            referenceCenters: ["session:alpha": 0, "session:beta": 100],
            draggedSessionID: "alpha",
            layout: layout
        ).isEmpty)
    }

    @Test func adjacentFolderBoundaryResolvesToTopLevelInsertion() throws {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha")),
            .group(PickyDockGroup(id: "beta")),
        ])

        let destination = try #require(PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 150,
            slotCandidates: [.init(container: .topLevel(index: 0), center: 0)],
            topLevelInsertionCandidates: [.init(topLevelIndex: 1, center: 150)],
            emptyGroupCandidates: [
                .init(groupID: "alpha", center: 100, halfExtent: 27),
                .init(groupID: "beta", center: 200, halfExtent: 27),
            ],
            layout: layout,
            slotPitch: 100
        ))

        #expect(destination == .topLevel(index: 1))

        let preview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
            layout: layout,
            draggedSessionID: "loose",
            destination: destination
        )
        #expect(preview.entries == [
            .group(PickyDockGroup(id: "alpha")),
            .session(id: "loose"),
            .group(PickyDockGroup(id: "beta")),
        ])
    }

    @Test func folderBoundsTakePriorityOverNearbyTopLevelInsertionTarget() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha")),
            .group(PickyDockGroup(id: "beta")),
        ])

        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 127,
            slotCandidates: [.init(container: .topLevel(index: 0), center: 0)],
            topLevelInsertionCandidates: [.init(topLevelIndex: 2, center: 150)],
            emptyGroupCandidates: [
                .init(groupID: "alpha", center: 100, halfExtent: 27),
                .init(groupID: "beta", center: 200, halfExtent: 27),
            ],
            layout: layout,
            slotPitch: 100
        )

        #expect(destination == .group(id: "alpha", memberIndex: 0))
    }

    @Test func openedGroupMemberSelectsItsOwningFolderExceptDuringDrag() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha", memberSessionIDs: ["grouped"])),
            .group(PickyDockGroup(id: "beta", memberSessionIDs: ["other"])),
        ])

        #expect(PickyHUDDockRenderPolicy.selectedGroupID(
            openedSessionID: "grouped",
            draggingSessionID: nil,
            layout: layout
        ) == "alpha")
        #expect(PickyHUDDockRenderPolicy.selectedGroupID(
            openedSessionID: "loose",
            draggingSessionID: nil,
            layout: layout
        ) == nil)
        #expect(PickyHUDDockRenderPolicy.selectedGroupID(
            openedSessionID: "grouped",
            draggingSessionID: "loose",
            layout: layout
        ) == nil)
    }

    @Test func dropFeedbackTargetsOnlyPendingGroupDuringSessionDrag() {
        #expect(PickyHUDDockRenderPolicy.dropTargetedGroupID(
            draggingSessionID: "loose",
            destination: .group(id: "alpha", memberIndex: 0)
        ) == "alpha")
        #expect(PickyHUDDockRenderPolicy.dropTargetedGroupID(
            draggingSessionID: "loose",
            destination: .topLevel(index: 1)
        ) == nil)
        #expect(PickyHUDDockRenderPolicy.dropTargetedGroupID(
            draggingSessionID: nil,
            destination: .group(id: "alpha", memberIndex: 0)
        ) == nil)
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

    @Test func groupDestinationKeepsSourcePlaceholderUntilDropWhileTopLevelDestinationReflows() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "group", memberSessionIDs: ["member"])),
        ])

        let groupPreview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
            layout: layout,
            draggedSessionID: "loose",
            destination: .group(id: "group", memberIndex: 1)
        )
        let bottomPreview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
            layout: layout,
            draggedSessionID: "loose",
            destination: .topLevel(index: 2)
        )

        #expect(PickyDockProjector.project(
            layout: groupPreview,
            visibleSessionIDs: ["loose", "member"]
        ).items.map(\.stableID) == ["session:loose", "group:group"])
        #expect(PickyDockProjector.project(
            layout: bottomPreview,
            visibleSessionIDs: ["loose", "member"]
        ).items.map(\.stableID) == ["group:group", "session:loose"])
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

    @Test func reorderRequiresAFiniteMeasuredSourceCenter() {
        #expect(PickyHUDDockDragGeometry.validSourceCenter(nil) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: CGFloat.nan, y: 80)) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: 40, y: CGFloat.infinity)) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: -CGFloat.infinity, y: 80)) == nil)

        let sourceCenter = CGPoint(x: 120, y: 80)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(sourceCenter) == sourceCenter)
    }

    @Test func floatingIconKeepsTheCapturedSourceCenterAcrossDockSidesAndFolderChrome() {
        let translation = CGSize(width: 17, height: -13)

        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                let labelChrome = PickyHUDDockGroupHeaderPresentation.labelHeight(
                    metrics: metrics,
                    fontScale: fontScale
                ) + metrics.groupHeaderContentSpacing

                for dockSide in PickyHUDDockSide.allCases {
                    let railCrossSize = dockSide.orientation == .horizontal
                        ? PickyHUDDockRailLayoutPolicy.horizontalCrossSize(
                            groupCount: 1,
                            metrics: metrics,
                            fontScale: fontScale
                        )
                        : PickyHUDDockRailLayoutPolicy.verticalCrossSize(
                            groupCount: 1,
                            metrics: metrics,
                            fontScale: fontScale
                        )
                    let sourceCenter: CGPoint
                    if dockSide.orientation == .horizontal {
                        // `horizontalSessionsAndAddSlot` bottom-aligns a loose
                        // Pickle with folder tiles, placing it below the rail
                        // center by the folder identity chrome.
                        sourceCenter = CGPoint(
                            x: 120,
                            y: railCrossSize - metrics.horizontalPadding - (metrics.sessionTileHeight / 2)
                        )
                        #expect(sourceCenter.y > railCrossSize / 2)
                        #expect(railCrossSize >= metrics.sessionTileHeight
                            + (metrics.horizontalPadding * 2)
                            + labelChrome)
                    } else {
                        sourceCenter = CGPoint(x: railCrossSize / 2, y: 120)
                    }

                    #expect(PickyHUDDockDragGeometry.floatingIconCenter(
                        dragStartCenter: sourceCenter,
                        translation: .zero
                    ) == sourceCenter)
                    #expect(PickyHUDDockDragGeometry.floatingIconCenter(
                        dragStartCenter: sourceCenter,
                        translation: translation
                    ) == CGPoint(
                        x: sourceCenter.x + translation.width,
                        y: sourceCenter.y + translation.height
                    ))
                }
            }
        }
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
    }
}
