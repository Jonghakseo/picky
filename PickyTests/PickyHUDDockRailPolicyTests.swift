//
//  PickyHUDDockRailPolicyTests.swift
//  PickyTests
//

import AppKit
import Foundation
import Testing
@testable import Picky

struct PickyHUDDockRailPolicyTests {
    @Test func groupDeletionOnlyConfirmsForActiveMembers() {
        let archivedOnly = PickyDockGroup(id: "archived-only", memberSessionIDs: ["archived"])
        let mixed = PickyDockGroup(id: "mixed", memberSessionIDs: ["archived", "active"])
        let activeIDs: Set<String> = ["active"]

        #expect(!PickyHUDDockGroupDeletePrompt.requiresConfirmation(group: archivedOnly, activeSessionIDs: activeIDs))
        #expect(!PickyHUDDockGroupDeletePrompt.requiresConfirmation(
            group: PickyDockGroup(id: "empty", memberSessionIDs: []), activeSessionIDs: activeIDs
        ))
        #expect(PickyHUDDockGroupDeletePrompt.requiresConfirmation(group: mixed, activeSessionIDs: activeIDs))
    }

    @MainActor @Test func archivedOnlyGroupDeletesImmediately() {
        let group = PickyDockGroup(id: "archived-only", memberSessionIDs: ["archived"])
        var didDelete = false
        PickyHUDDockGroupDeletePrompt.delete(group: group, activeSessionIDs: []) {
            didDelete = true
        }
        #expect(didDelete)
    }

    // MARK: List layout

    @Test func collapsedGroupContributesOnlyItsHeaderWhileExpandedAddsMemberRows() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        func length(collapsed: Bool) -> CGFloat {
            let layout = PickyDockLayout(entries: [
                .session(id: "loose"),
                .group(PickyDockGroup(id: "g", memberSessionIDs: ["a", "archived", "b"], isCollapsed: collapsed)),
            ])
            let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["loose", "a", "b"])
            return PickyHUDDockRailLayoutPolicy.listLength(
                projection: projection, activeSessionIDs: ["loose", "a", "b"],
                orientation: .vertical, metrics: metrics, fontScale: 1
            )
        }
        let row = metrics.rowHeight(fontScale: 1)
        let header = metrics.groupHeaderHeight(fontScale: 1)

        #expect(length(collapsed: true) == row + metrics.rowSpacing + metrics.groupHeaderTopGap + header)
        // Only the two active members render; the archived one is retained in the layout.
        #expect(length(collapsed: false) - length(collapsed: true) == 2 * (row + metrics.rowSpacing))
    }

    @Test func expandedEmptyGroupReservesOneDropPlaceholderRow() {
        let metrics = PickyHUDDockMetrics(preset: .large)
        let layout = PickyDockLayout(entries: [.group(PickyDockGroup(id: "g", isCollapsed: false))])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: [])

        #expect(PickyHUDDockRailLayoutPolicy.listLength(
            projection: projection, activeSessionIDs: [], orientation: .vertical, metrics: metrics, fontScale: 1
        ) == metrics.groupHeaderHeight(fontScale: 1) + metrics.rowHeight(fontScale: 1) + metrics.rowSpacing)
    }

    @Test func eachPresetSetsTheListWidthHorizontalThicknessAndRowShape() {
        let small = PickyHUDDockMetrics(preset: .small)
        let medium = PickyHUDDockMetrics(preset: .medium)
        let large = PickyHUDDockMetrics(preset: .large)

        #expect([small.railWidth, medium.railWidth, large.railWidth] == [112, 168, 200])
        #expect([small, medium, large].map { $0.horizontalThickness(fontScale: 1) } == [39, 39, 50])
        #expect(large.showsRowDetailLine && !medium.showsRowDetailLine && !small.showsRowDetailLine)
        // Every preset uses the same 13pt title, so rows only get narrower.
        #expect([small, medium].map { $0.rowHeight(fontScale: 1) } == [27, 28])
        // Rows keep a visible gap so neighboring fills never touch.
        #expect([small, medium, large].allSatisfy { $0.rowSpacing >= 2 })
        // Larger app text grows rows instead of clipping them.
        #expect(medium.rowHeight(fontScale: 1.3) > medium.rowHeight(fontScale: 1))
        // The move handle widens with the vertical list, never past 60pt.
        #expect([small.handleNotchWidth, medium.handleNotchWidth, large.handleNotchWidth] == [34, 50, 60])
    }

    @Test func horizontalChromeLaysTheTwoUtilitiesSideBySide() {
        let metrics = PickyHUDDockMetrics(preset: .small)
        let vertical = PickyHUDDockRailLayoutPolicy.fixedChromeLength(
            dockSide: .right, metrics: metrics, hasDockAddUtility: true)
        let horizontal = PickyHUDDockRailLayoutPolicy.fixedChromeLength(
            dockSide: .bottom, metrics: metrics, hasDockAddUtility: true)

        #expect(horizontal - vertical == metrics.utilityButtonSide + metrics.utilitySpacing)
    }

    @Test func horizontalHeaderChipCapsLongGroupNames() {
        let metrics = PickyHUDDockMetrics(preset: .medium)
        let short = PickyHUDDockGroupHeaderLayout.horizontalChipWidth(
            name: "PR", count: 3, metrics: metrics, fontScale: 1)
        let long = PickyHUDDockGroupHeaderLayout.horizontalChipWidth(
            name: String(repeating: "아주 긴 그룹 이름", count: 6), count: 3, metrics: metrics, fontScale: 1)
        let longer = PickyHUDDockGroupHeaderLayout.horizontalChipWidth(
            name: String(repeating: "아주 긴 그룹 이름", count: 12), count: 3, metrics: metrics, fontScale: 1)

        #expect(short < long)
        #expect(long == longer)
    }

    @Test func horizontalRailStopsAtItsMaximumLengthOnWideScreens() {
        #expect(PickyHUDDockLayout.horizontalDockRailLengthBudget(screenAvailableLength: 3000)
            == PickyHUDDockLayout.horizontalDockRailMaxLength)
        #expect(PickyHUDDockLayout.horizontalDockRailLengthBudget(screenAvailableLength: 400) == 400)
    }

    // MARK: Drag

    @Test func groupReorderUsesFrozenTopEntryExtentsWhenPreviewHasReflowed() {
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
        let frozenExtents: [String: PickyDockAxisExtent] = [
            "session:a": .init(lower: 27, upper: 53),
            "group:group": .init(lower: 100, upper: 148),
            "session:b": .init(lower: 219, upper: 245)
        ]

        let destination = PickyHUDDockRenderPolicy.nearestLayoutEntryIndex(
            cursorAxis: 218,
            visibleTopEntryIDs: entryIDs,
            referenceExtents: frozenExtents,
            layout: layout
        )

        #expect(destination == 2)
    }

    @Test func adjacentTopLevelEntriesExposeInsertionTargetsInTheGapBetweenTheirEdges() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha")),
            .group(PickyDockGroup(id: "beta")),
        ])
        // An expanded group block is tall; the boundary sits at its outer
        // edge, not at the block's center among its member rows.
        let candidates = PickyHUDDockRenderPolicy.topLevelInsertionCandidates(
            visibleTopEntryIDs: ["session:loose", "group:alpha", "group:beta"],
            referenceExtents: [
                "session:loose": .init(lower: 0, upper: 40),
                "group:alpha": .init(lower: 60, upper: 140),
                "group:beta": .init(lower: 160, upper: 184),
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
            referenceExtents: ["session:alpha": .init(lower: 0, upper: 26), "session:beta": .init(lower: 27, upper: 53)],
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

    @Test func openedMemberOfACollapsedGroupSelectsItsHeaderExceptDuringDrag() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "alpha", memberSessionIDs: ["grouped"])),
            .group(PickyDockGroup(id: "beta", memberSessionIDs: ["other"])),
            .group(PickyDockGroup(id: "open", memberSessionIDs: ["visible"], isCollapsed: false)),
        ])
        // An expanded group shows the opened row itself, so its header stays quiet.
        #expect(PickyHUDDockRenderPolicy.selectedGroupID(
            openedSessionID: "visible",
            draggingSessionID: nil,
            layout: layout
        ) == nil)

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

    @Test func collapsedGroupDestinationKeepsSourcePlaceholderUntilDropWhileTopLevelDestinationReflows() {
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

    @Test func expandedGroupDestinationReflowsToShowTheInsertionRow() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "group", memberSessionIDs: ["member"], isCollapsed: false)),
        ])

        let preview = PickyHUDDockRenderPolicy.sessionPreviewLayout(
            layout: layout,
            draggedSessionID: "loose",
            destination: .group(id: "group", memberIndex: 1)
        )

        #expect(PickyDockProjector.project(layout: preview, visibleSessionIDs: ["loose", "member"])
            .visibleMemberIDs(inGroup: "group") == ["member", "loose"])
    }

    @Test func sessionDragNeverShrinksRailBelowPersistedLength() {
        #expect(PickyHUDDockReorderAnimationPolicy.sizingLength(
            renderedLength: 300, persistedLength: 400, isSessionDragging: true
        ) == 400)
        #expect(PickyHUDDockReorderAnimationPolicy.sizingLength(
            renderedLength: 500, persistedLength: 400, isSessionDragging: true
        ) == 500)
        #expect(PickyHUDDockReorderAnimationPolicy.sizingLength(
            renderedLength: 300, persistedLength: 400, isSessionDragging: false
        ) == 300)
    }

    @Test func reorderRequiresAFiniteMeasuredSourceCenter() {
        #expect(PickyHUDDockDragGeometry.validSourceCenter(nil) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: CGFloat.nan, y: 80)) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: 40, y: CGFloat.infinity)) == nil)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(CGPoint(x: -CGFloat.infinity, y: 80)) == nil)

        let sourceCenter = CGPoint(x: 120, y: 80)
        #expect(PickyHUDDockDragGeometry.validSourceCenter(sourceCenter) == sourceCenter)
    }

    @Test func floatingRowKeepsTheCapturedSourceCenterAcrossDockSides() {
        let translation = CGSize(width: 17, height: -13)

        for preset in PickyHUDDockSizePreset.allCases {
            let metrics = PickyHUDDockMetrics(preset: preset)
            for fontScale: CGFloat in [1, 1.3] {
                for dockSide in PickyHUDDockSide.allCases {
                    let railCrossSize = PickyHUDDockRailLayoutPolicy.crossSize(
                        dockSide: dockSide,
                        metrics: metrics,
                        fontScale: fontScale
                    )
                    let sourceCenter: CGPoint
                    if dockSide.orientation == .horizontal {
                        sourceCenter = CGPoint(x: 120, y: railCrossSize / 2)
                        #expect(railCrossSize >= metrics.chipHeight(fontScale: fontScale) + metrics.horizontalPadding * 2)
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
        #expect(PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics, orientation: .vertical) == metrics.railWidth * 0.5 + 40)
        #expect(PickyHUDDockDragGeometry.pullOutThreshold(metrics: metrics, orientation: .horizontal, fontScale: 1)
            == metrics.horizontalThickness(fontScale: 1) * 0.5 + 40)
    }
}
