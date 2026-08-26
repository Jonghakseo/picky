//
//  PickyHUDDockGroupListFocusStoreTests.swift
//  PickyTests
//
//  The focus store is the single copy of "which list is open on this display".
//  These tests pin the behavior the HUD root and the list panel both read.
//

import CoreGraphics
import Testing
@testable import Picky

@MainActor
struct PickyHUDDockGroupListFocusStoreTests {
    private let displayA: CGDirectDisplayID = 1
    private let displayB: CGDirectDisplayID = 2

    @Test func aDisplayWithNoOpenListReportsClosed() {
        let store = PickyHUDDockGroupListFocusStore()

        #expect(store.focus(for: displayA).isOpen == false)
        #expect(store.focus(for: nil).isOpen == false)
        #expect(store.focus(for: displayA).rowIDs.isEmpty)
    }

    @Test func openingAListStartsWithoutKeyboardHighlight() {
        let store = PickyHUDDockGroupListFocusStore()

        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b"])

        #expect(store.focus(for: displayA).openGroupID == "g1")
        #expect(store.focus(for: displayA).highlightedRowID == nil)
    }

    @Test func eachDisplayKeepsItsOwnOpenList() {
        let store = PickyHUDDockGroupListFocusStore()

        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a"])
        store.open(displayID: displayB, groupID: "g2", rowIDs: ["x", "y"])

        #expect(store.focus(for: displayA).openGroupID == "g1")
        #expect(store.focus(for: displayB).openGroupID == "g2")

        store.close(displayID: displayA)

        #expect(store.focus(for: displayA).isOpen == false)
        #expect(store.focus(for: displayB).openGroupID == "g2")
    }

    @Test func arrowsActivateAnEndRowThenMoveAndClampTheHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b"])

        #expect(store.moveHighlight(displayID: displayA, direction: .down) == "a")
        #expect(store.moveHighlight(displayID: displayA, direction: .down) == "b")
        #expect(store.moveHighlight(displayID: displayA, direction: .down) == "b")
        #expect(store.moveHighlight(displayID: displayA, direction: .up) == "a")

        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b"])
        #expect(store.moveHighlight(displayID: displayA, direction: .up) == "b")
        #expect(store.focus(for: displayA).highlightedRowID == "b")
    }

    @Test func arrowsDoNothingWhileNoListIsOpen() {
        let store = PickyHUDDockGroupListFocusStore()

        #expect(store.moveHighlight(displayID: displayA, direction: .down) == nil)
        #expect(store.moveHighlight(displayID: nil, direction: .down) == nil)
    }

    @Test func passiveMembershipChangesPreserveNoKeyboardHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b", "c"])

        store.updateRows(displayID: displayA, rowIDs: ["a", "c", "d"])

        #expect(store.focus(for: displayA).rowIDs == ["a", "c", "d"])
        #expect(store.focus(for: displayA).highlightedRowID == nil)
    }

    /// Archiving the highlighted Pickle must not leave the highlight pointing at
    /// a row that no longer exists.
    @Test func membershipChangesRecoverAnActiveHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b", "c"])
        _ = store.moveHighlight(displayID: displayA, direction: .down)
        _ = store.moveHighlight(displayID: displayA, direction: .down)

        store.updateRows(displayID: displayA, rowIDs: ["a", "c"])

        #expect(store.focus(for: displayA).highlightedRowID == "a")
    }

    @Test func membershipChangesKeepASurvivingActiveHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b", "c"])
        _ = store.moveHighlight(displayID: displayA, direction: .up)

        store.updateRows(displayID: displayA, rowIDs: ["b", "c"])

        #expect(store.focus(for: displayA).highlightedRowID == "c")
    }

    @Test func updatingRowsForAClosedDisplayIsIgnored() {
        let store = PickyHUDDockGroupListFocusStore()

        store.updateRows(displayID: displayA, rowIDs: ["a"])

        #expect(store.focus(for: displayA).isOpen == false)
    }

    @Test func closeAllClearsEveryDisplay() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a"])
        store.open(displayID: displayB, groupID: "g2", rowIDs: ["b"])

        store.closeAll()

        #expect(store.focus(for: displayA).isOpen == false)
        #expect(store.focus(for: displayB).isOpen == false)
    }
}
