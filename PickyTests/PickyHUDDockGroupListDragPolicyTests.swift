//
//  PickyHUDDockGroupListDragPolicyTests.swift
//  PickyTests
//
//  Row drag contract for the group list, including the cases the old rail-based
//  resolver tests used to protect: overshooting past the last row, dropping
//  above the first one, and leaving the group by dragging clear of the panel.
//

import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Picky

private final class PickyHUDDockGroupListFlippedDocumentView: NSView {
    override var isFlipped: Bool { true }
}

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
            insertionIndex: 2,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .reorder(visibleIndex: 2))
    }

    @Test func leavingThePanelImmediatelyPromotesToExternalDrag() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
            insertionIndex: 0,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .promote)
    }

    /// Cross-axis exit is one-way for this physical press.
    @Test func brieflyClippingTheEdgePromotesInsteadOfPersistingLocally() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
            insertionIndex: 0,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .promote)
    }

    @Test func aRowThatDisappearsMidDragCancelsEvenWhenPulledOut() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: false,
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

    @Test func visibleViewportEdgesScrollDespitePanelHeaderAndPadding() {
        // The scroll viewport begins below the panel's header and padding. A
        // pointer at its visible top edge must not be treated as panel middle.
        let viewport = CGRect(x: 12, y: 64, width: 216, height: 180)

        let top = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(
            pointerY: viewport.minY,
            viewportFrame: viewport
        )
        let middle = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(
            pointerY: viewport.midY,
            viewportFrame: viewport
        )
        let bottom = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(
            pointerY: viewport.maxY,
            viewportFrame: viewport
        )

        #expect(top == -PickyHUDDockGroupListDragPolicy.autoScrollPointsPerSecond)
        #expect(middle == 0)
        #expect(bottom == PickyHUDDockGroupListDragPolicy.autoScrollPointsPerSecond)
    }

    @Test func edgeHoldMovesScrollPositionAndInsertionDestination() {
        let pointerY: CGFloat = 296
        let panelHeight: CGFloat = 300
        let velocity = PickyHUDDockGroupListDragPolicy.autoScrollVelocity(
            pointerY: pointerY,
            panelHeight: panelHeight
        )
        let position = PickyHUDDockGroupListDragPolicy.autoScrollPosition(
            currentOffset: 0,
            velocity: velocity,
            elapsed: 0.25,
            maximumOffset: 152
        )
        let centersBeforeScroll = (0..<12).map { CGFloat(60 + ($0 * 38)) }
        let centersAfterScroll = centersBeforeScroll.map { $0 - position }

        #expect(position == 50)
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(
            pointerY: pointerY,
            rowCenters: centersBeforeScroll
        ) == 7)
        #expect(PickyHUDDockGroupListDragPolicy.insertionIndex(
            pointerY: pointerY,
            rowCenters: centersAfterScroll
        ) == 8)
    }

    @Test func primaryAxisEdgeHoldStaysInTheReorderLane() {
        let panelWidth: CGFloat = 240
        let isWithinReorderLane = PickyHUDDockGroupListDragPolicy.isWithinReorderLane(
            pointerX: panelWidth / 2,
            panelWidth: panelWidth
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: isWithinReorderLane,
            insertionIndex: 4,
            isDraggedRowStillPresent: true
        )

        #expect(PickyHUDDockGroupListDragPolicy.autoScrollVelocity(pointerY: 320, panelHeight: 300) > 0)
        #expect(outcome == .reorder(visibleIndex: 4))
    }

    @Test func crossAxisExitPromotesWithoutAResidenceTimer() {
        let isWithinReorderLane = PickyHUDDockGroupListDragPolicy.isWithinReorderLane(
            pointerX: 241,
            panelWidth: 240
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: isWithinReorderLane,
            insertionIndex: 0,
            isDraggedRowStillPresent: true
        )

        #expect(!isWithinReorderLane)
        #expect(outcome == .promote)
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


@MainActor
extension PickyHUDDockGroupListDragPolicyTests {
    @Test func leaseTransfersTerminalOwnershipOnceAndMakesLateListEventsInert() {
        let token = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let nextToken = UUID(uuidString: "00000000-0000-0000-0000-000000000011")!
        let lease = PickyHUDDockGroupListDragLease()

        #expect(lease.begin(token: token))
        #expect(lease.ownsList(token: token))
        #expect(lease.transferToExternal(token: token))
        #expect(!lease.ownsList(token: token))
        #expect(lease.ownsExternal(token: token))
        #expect(!lease.transferToExternal(token: token))
        lease.reset(token: token)
        #expect(lease.begin(token: nextToken))
    }

    @Test func liveMembershipRejectsImmediateCommitAfterStructureChangeBeforeRender() {
        let membership = PickyHUDDockGroupListLiveMembership(rowIDs: ["alpha", "bravo"])
        let frozenIDs = membership.rowIDs

        // This is the monitor's synchronous read, without a SwiftUI render
        // callback between the snapshot mutation and mouse-up.
        membership.update(rowIDs: ["bravo", "alpha"])
        #expect(!PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: frozenIDs,
            currentRowIDs: membership.rowIDs
        ))
    }

    @Test func liveMembershipPermitsContentOnlyUpdatesWithTheSameIDs() {
        let membership = PickyHUDDockGroupListLiveMembership(rowIDs: ["alpha", "bravo"])
        let frozenIDs = membership.rowIDs

        membership.update(rowIDs: ["alpha", "bravo"])
        #expect(PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: frozenIDs,
            currentRowIDs: membership.rowIDs
        ))
    }

    @Test func nativeScrollUpdatesImmediateDropGeometryAndCommitsOnce() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let documentView = PickyHUDDockGroupListFlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 600)
        )
        scrollView.documentView = documentView
        let controller = PickyHUDDockGroupListScrollController()
        controller.attach(to: scrollView)

        let result = try #require(controller.scroll(by: 240, elapsed: 0.25))
        let rowCenters = PickyHUDDockGroupListDragPolicy.rowCenters(
            afterVisualOffsetDelta: result.visualOffsetDelta,
            from: ["alpha": 50, "bravo": 90, "charlie": 130, "delta": 170]
        )
        let rawIndex = PickyHUDDockGroupListDragPolicy.insertionIndex(
            pointerY: 95,
            rowCenters: [rowCenters["alpha"], rowCenters["bravo"], rowCenters["charlie"], rowCenters["delta"]]
                .compactMap { $0 }
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isInsidePanel: true,
            insertionIndex: PickyHUDDockGroupListDragPolicy.normalizedInsertionIndex(rawIndex, draggedRowIndex: 0),
            isDraggedRowStillPresent: true
        )
        var committedIndexes: [Int] = []
        if case .reorder(let index) = outcome {
            committedIndexes.append(index)
        }

        #expect(result.visualOffsetDelta == -60)
        #expect(rawIndex == 3)
        #expect(committedIndexes == [2])
    }

    @Test func nativeScrollUpdatesCachedRowFramesWithTheSameVisualDeltaAsCenters() {
        let frames = PickyHUDDockGroupListDragPolicy.rowFrames(
            afterVisualOffsetDelta: -60,
            from: ["alpha": CGRect(x: 12, y: 50, width: 200, height: 38)]
        )

        #expect(frames["alpha"] == CGRect(x: 12, y: -10, width: 200, height: 38))
    }

    @Test func nativeScrollAtTheClampDoesNotMoveOrAlterDropGeometry() {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let documentView = PickyHUDDockGroupListFlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 200, height: 600)
        )
        scrollView.documentView = documentView
        let controller = PickyHUDDockGroupListScrollController()
        controller.attach(to: scrollView)

        #expect(controller.scroll(by: -240, elapsed: 0.25) == nil)
        #expect(PickyHUDDockGroupListDragPolicy.rowCenters(
            afterVisualOffsetDelta: 0,
            from: ["alpha": 50]
        ) == ["alpha": 50])
    }

    @Test func nativeUnflippedScrollReportsTheOppositeVisualCoordinateDelta() throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let documentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 600))
        scrollView.documentView = documentView
        let controller = PickyHUDDockGroupListScrollController()
        controller.attach(to: scrollView)

        let result = try #require(controller.scroll(by: -240, elapsed: 0.25))

        #expect(result.visualOffsetDelta == 60)
    }

    @Test func autoScrollTickerStartsOnlyForAnActiveDragAndStopsOnReset() {
        var startCount = 0
        var cancellationCount = 0
        let ticker = PickyHUDDockGroupListDragAutoScrollTicker { _ in
            startCount += 1
            return { cancellationCount += 1 }
        }

        ticker.setDragging(false)
        #expect(startCount == 0)
        #expect(!ticker.isRunning)

        ticker.setDragging(true)
        ticker.setDragging(true)
        #expect(startCount == 1)
        #expect(ticker.isRunning)

        ticker.setDragging(false)
        #expect(cancellationCount == 1)
        #expect(!ticker.isRunning)
    }

    @Test func autoScrollTickerCancelsItsActiveTimerDuringTeardown() {
        var cancellationCount = 0
        var ticker: PickyHUDDockGroupListDragAutoScrollTicker? = PickyHUDDockGroupListDragAutoScrollTicker { _ in
            { cancellationCount += 1 }
        }

        ticker?.setDragging(true)
        ticker = nil

        #expect(cancellationCount == 1)
    }
}
