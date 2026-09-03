//
//  PickyDockManualOrderPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("Dock manual order policy")
struct PickyDockManualOrderPolicyTests {
    @Test("Files unknown active sessions into the newest slot, newest first")
    func insertsUnknownActiveIDsAtNewestSlot() {
        let order = PickyDockManualOrderPolicy.reconciled(
            manualOrder: ["b", "a"],
            activeIDsNewestFirst: ["new2", "new1", "b", "a"],
            archivedIDs: []
        )

        #expect(order == ["new2", "new1", "b", "a"])
    }

    @Test("Drops ids that left the active and archived universe")
    func dropsIDsOutsideUniverse() {
        let order = PickyDockManualOrderPolicy.reconciled(
            manualOrder: ["gone", "b", "archived", "a"],
            activeIDsNewestFirst: ["b", "a"],
            archivedIDs: ["archived"]
        )

        #expect(order == ["b", "archived", "a"])
    }

    @Test("Leaves a fully reconciled order untouched")
    func reconciliationIsIdempotent() {
        let input = ["b", "archived", "a"]
        let once = PickyDockManualOrderPolicy.reconciled(
            manualOrder: input,
            activeIDsNewestFirst: ["b", "a"],
            archivedIDs: ["archived"]
        )
        let twice = PickyDockManualOrderPolicy.reconciled(
            manualOrder: once,
            activeIDsNewestFirst: ["b", "a"],
            archivedIDs: ["archived"]
        )

        #expect(once == input)
        #expect(twice == input)
    }

    @Test("Counts active ids so interleaved archived slots do not shift the drop")
    func skipsArchivedSlotsWhenCountingTarget() {
        let order = PickyDockManualOrderPolicy.moved(
            manualOrder: ["a", "archived1", "b", "archived2", "c"],
            sessionID: "c",
            activeIDs: ["a", "b", "c"],
            underlyingTarget: 1
        )

        // Target 1 counts active ids only, so "c" lands immediately after the
        // first active id and ahead of the archived slots that follow it. The
        // active-only order becomes a, c, b as the drop intended, and every
        // archived id keeps its relative position for a later unarchive.
        #expect(order == ["a", "c", "archived1", "b", "archived2"])
        #expect(order?.filter { !$0.hasPrefix("archived") } == ["a", "c", "b"])
    }

    @Test("Moving to the newest slot puts the session first")
    func movesToNewestSlot() {
        let order = PickyDockManualOrderPolicy.moved(
            manualOrder: ["a", "b", "c"],
            sessionID: "c",
            activeIDs: ["a", "b", "c"],
            underlyingTarget: 0
        )

        #expect(order == ["c", "a", "b"])
    }

    @Test("Moving past the last active id appends to the end")
    func movesToOldestSlot() {
        let order = PickyDockManualOrderPolicy.moved(
            manualOrder: ["a", "b", "c"],
            sessionID: "a",
            activeIDs: ["a", "b", "c"],
            underlyingTarget: 2
        )

        #expect(order == ["b", "c", "a"])
    }

    @Test("An unknown session leaves the persisted order untouched")
    func unknownSessionReturnsNil() {
        #expect(PickyDockManualOrderPolicy.moved(
            manualOrder: ["a", "b"],
            sessionID: "missing",
            activeIDs: ["a", "b"],
            underlyingTarget: 0
        ) == nil)
    }

    @Test("Unarchive restores the session to the newest slot without disturbing others")
    func promotesToNewestSlot() {
        #expect(PickyDockManualOrderPolicy.promotedToNewest(
            manualOrder: ["a", "restored", "b"],
            sessionID: "restored"
        ) == ["restored", "a", "b"])
        #expect(PickyDockManualOrderPolicy.promotedToNewest(
            manualOrder: ["a", "b"],
            sessionID: "restored"
        ) == ["restored", "a", "b"])
    }

    @Test("Visible and underlying indices are the same reflection")
    func indexTranslationIsSymmetric() {
        for count in 1...5 {
            for index in 0..<count {
                let reflected = PickyDockManualOrderPolicy.underlyingIndex(visibleIndex: index, count: count)
                #expect(PickyDockManualOrderPolicy.underlyingIndex(visibleIndex: reflected, count: count) == index)
            }
        }
    }

    @Test("Raw drop indices clamp into visible space")
    func clampsDropIndex() {
        #expect(PickyDockManualOrderPolicy.clampedVisibleIndex(-3, count: 4) == 0)
        #expect(PickyDockManualOrderPolicy.clampedVisibleIndex(9, count: 4) == 3)
        #expect(PickyDockManualOrderPolicy.clampedVisibleIndex(2, count: 4) == 2)
    }
}
