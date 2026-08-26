//
//  PickyHUDDockGroupListDragPolicyTests.swift
//  PickyTests
//
//  Row drag contract for the group list, including the cases the old rail-based
//  resolver tests used to protect: overshooting past the last row, dropping
//  above the first one, and leaving the group by dragging clear of the panel.
//

import CoreGraphics
import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListDragPolicyTests {
    /// Three 38pt rows starting under a 22pt header.
    private let rowCenters: [CGFloat] = [41, 79, 117]
    private let rowIDs = ["alpha", "bravo", "charlie"]

    // MARK: - Insertion index

    @Test func aDropAboveEveryRowLandsFirst() {
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 10, rowCenters: rowCenters) == 0)
    }

    @Test func aDropBetweenRowsLandsBetweenThem() {
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 60, rowCenters: rowCenters) == 1)
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 100, rowCenters: rowCenters) == 2)
    }

    /// Overshooting past the last row appends instead of doing nothing, which is
    /// what the removed rail resolver test guarded on the old surface.
    @Test func overshootingPastTheLastRowAppends() {
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 400, rowCenters: rowCenters) == 3)
    }

    @Test func anEmptyListAlwaysResolvesToTheOnlyPosition() {
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 0, rowCenters: []) == 0)
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 999, rowCenters: []) == 0)
    }

    @Test func indexIsCompensatedForTheDraggedRowsOwnGap() {
        // Dragging the first row down past the second: raw index 2, but the list
        // it lands in no longer contains the dragged row.
        #expect(PickyHUDDockGroupListDragPolicy.normalizedInsertionIndex(2, draggedRowIndex: 0) == 1)
        // Dragging the last row up: nothing before it shifted.
        #expect(PickyHUDDockGroupListDragPolicy.normalizedInsertionIndex(0, draggedRowIndex: 2) == 0)
    }

    // MARK: - Preview

    @Test func previewMovesTheDraggedRowAndShiftsTheRest() {
        let preview = PickyHUDDockGroupListDragPolicy.previewOrder(
            rowIDs: rowIDs,
            draggedRowID: "alpha",
            insertionIndex: 2
        )

        #expect(preview == ["bravo", "charlie", "alpha"])
    }

    @Test func previewClampsAnOutOfRangeInsertion() {
        let preview = PickyHUDDockGroupListDragPolicy.previewOrder(
            rowIDs: rowIDs,
            draggedRowID: "charlie",
            insertionIndex: 99
        )

        #expect(preview == ["alpha", "bravo", "charlie"])
    }

    @Test func previewOfAnUnknownRowLeavesTheOrderAlone() {
        let preview = PickyHUDDockGroupListDragPolicy.previewOrder(
            rowIDs: rowIDs,
            draggedRowID: "ghost",
            insertionIndex: 0
        )

        #expect(preview == rowIDs)
    }

    // MARK: - Outcome

    @Test func releasingInsideThePanelReorders() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: true,
            timeOutsidePanel: 0,
            insertionIndex: 2,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .reorder(visibleIndex: 2))
    }

    @Test func leavingThePanelLongEnoughUngroups() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
            timeOutsidePanel: PickyHUDDockGroupListDragPolicy.pullOutDwell,
            insertionIndex: 0,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .ungroup)
    }

    /// Clipping the panel edge mid-reorder must not be read as "leave the group".
    @Test func brieflyClippingTheEdgeCancelsInsteadOfUngrouping() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
            timeOutsidePanel: 0.05,
            insertionIndex: 0,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .cancel)
    }

    @Test func aRowThatDisappearsMidDragCancelsEvenWhenPulledOut() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
            timeOutsidePanel: 5,
            insertionIndex: 0,
            isDraggedRowStillPresent: false
        )

        #expect(outcome == .cancel)
    }

    // MARK: - Auto-scroll

    @Test func theMiddleOfThePanelDoesNotScroll() {
        #expect(PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 150, panelHeight: 300) == 0)
    }

    @Test func edgeBandsScrollTowardTheirOwnEdge() {
        let top = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 0, panelHeight: 300)
        let bottom = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 300, panelHeight: 300)

        #expect(top == -PickyHUDDockGroupListDragPolicy.autoScrollPointsPerSecond)
        #expect(bottom == PickyHUDDockGroupListDragPolicy.autoScrollPointsPerSecond)
    }

    @Test func theScrollRampIsLinearWithinTheBand() {
        let halfway = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 12, panelHeight: 300)

        #expect(halfway == -PickyHUDDockGroupListDragPolicy.autoScrollPointsPerSecond / 2)
    }

    @Test func aPanelShorterThanTwoBandsNeverAutoScrolls() {
        #expect(PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 5, panelHeight: 40) == 0)
    }

    // MARK: - Stored index translation

    /// The archived-member invariant, exercised end to end from a drop position:
    /// a visible drop index is not a stored index.
    @Test func aVisibleDropPositionTranslatesPastHiddenArchivedMembers() {
        let memberSessionIDs = ["archived-1", "alpha", "archived-2", "bravo"]
        let activeSessionIDs: Set<String> = ["alpha", "bravo"]

        let dropBeforeAlpha = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: 0,
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: activeSessionIDs
        )
        let dropBeforeBravo = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: 1,
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: activeSessionIDs
        )
        let dropAtEnd = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: 2,
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: activeSessionIDs
        )

        #expect(dropBeforeAlpha == 1)
        #expect(dropBeforeBravo == 3)
        #expect(dropAtEnd == 4)
    }

    @Test func anOvershootingDropStillTranslatesToTheStoredTail() {
        let memberSessionIDs = ["alpha", "archived"]
        let translated = PickyDockGroupMemberIndexPolicy.fullMemberIndex(
            forVisibleIndex: PickyHUDDockGroupListDragPolicy.insertionIndex(pointerY: 999, rowCenters: [41]),
            memberSessionIDs: memberSessionIDs,
            activeSessionIDs: ["alpha"]
        )

        #expect(translated == 2)
    }
}
