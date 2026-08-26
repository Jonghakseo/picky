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

    @Test func openingHighlightsTheAlreadyOpenMember() {
        let store = PickyHUDDockGroupListFocusStore()

        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b"], openedSessionID: "b")

        #expect(store.focus(for: displayA).openGroupID == "g1")
        #expect(store.focus(for: displayA).highlightedRowID == "b")
    }

    @Test func eachDisplayKeepsItsOwnOpenList() {
        let store = PickyHUDDockGroupListFocusStore()

        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a"], openedSessionID: nil)
        store.open(displayID: displayB, groupID: "g2", rowIDs: ["x", "y"], openedSessionID: nil)

        #expect(store.focus(for: displayA).openGroupID == "g1")
        #expect(store.focus(for: displayB).openGroupID == "g2")

        store.close(displayID: displayA)

        #expect(store.focus(for: displayA).isOpen == false)
        #expect(store.focus(for: displayB).openGroupID == "g2")
    }

    @Test func arrowsMoveTheHighlightAndClampAtTheEnd() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b"], openedSessionID: "a")

        #expect(store.moveHighlight(displayID: displayA, direction: .down) == "b")
        #expect(store.moveHighlight(displayID: displayA, direction: .down) == "b")
        #expect(store.moveHighlight(displayID: displayA, direction: .up) == "a")
        #expect(store.focus(for: displayA).highlightedRowID == "a")
    }

    @Test func arrowsDoNothingWhileNoListIsOpen() {
        let store = PickyHUDDockGroupListFocusStore()

        #expect(store.moveHighlight(displayID: displayA, direction: .down) == nil)
        #expect(store.moveHighlight(displayID: nil, direction: .down) == nil)
    }

    /// Archiving the highlighted Pickle must not leave the highlight pointing at
    /// a row that no longer exists.
    @Test func membershipChangesRecoverTheHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b", "c"], openedSessionID: "b")

        store.updateRows(displayID: displayA, rowIDs: ["a", "c"])

        #expect(store.focus(for: displayA).rowIDs == ["a", "c"])
        #expect(store.focus(for: displayA).highlightedRowID == "a")
    }

    @Test func membershipChangesKeepASurvivingHighlight() {
        let store = PickyHUDDockGroupListFocusStore()
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a", "b", "c"], openedSessionID: "c")

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
        store.open(displayID: displayA, groupID: "g1", rowIDs: ["a"], openedSessionID: nil)
        store.open(displayID: displayB, groupID: "g2", rowIDs: ["b"], openedSessionID: nil)

        store.closeAll()

        #expect(store.focus(for: displayA).isOpen == false)
        #expect(store.focus(for: displayB).isOpen == false)
    }
}
