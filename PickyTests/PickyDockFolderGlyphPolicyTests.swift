//
//  PickyDockFolderGlyphPolicyTests.swift
//  PickyTests
//
//  Folder badges pick members by attention priority, because unread only
//  tracks completed/failed/waiting and would hide running or blocked work.
//

import Foundation
import Testing
@testable import Picky

struct PickyDockFolderGlyphPolicyTests {
    @Test func attentionStatesOutrankFinishedOnes() {
        let statuses: [PickySessionStatus] = [.completed, .completed, .running, .blocked]

        #expect(
            PickyDockFolderGlyphPolicy.glyphIndices(statuses: statuses, cellCount: 3) == [3, 2, 0]
        )
    }

    @Test func tiesKeepStoredOrderSoTheBadgeDoesNotShuffleOnItsOwn() {
        let statuses: [PickySessionStatus] = [.running, .running, .running]

        #expect(
            PickyDockFolderGlyphPolicy.glyphIndices(statuses: statuses, cellCount: 3) == [0, 1, 2]
        )
    }

    @Test func priorityOrderMatchesTheSpecFromBlockedToCancelled() {
        let ordered: [PickySessionStatus] = [
            .blocked, .waiting_for_input, .failed, .running, .queued, .completed, .cancelled,
        ]
        let priorities = ordered.map(PickyDockFolderGlyphPolicy.statusPriority)

        #expect(priorities == priorities.sorted())
        #expect(Set(priorities).count == ordered.count)
    }

    @Test func glyphSelectionNeverReturnsMoreCellsThanAsked() {
        let statuses: [PickySessionStatus] = [.running, .completed]

        #expect(PickyDockFolderGlyphPolicy.glyphIndices(statuses: statuses, cellCount: 3).count == 2)
        #expect(PickyDockFolderGlyphPolicy.glyphIndices(statuses: statuses, cellCount: 0).isEmpty)
        #expect(PickyDockFolderGlyphPolicy.glyphIndices(statuses: [], cellCount: 3).isEmpty)
    }

    @Test func overflowCountsOnlyTheMembersBehindTheBadge() {
        #expect(PickyDockFolderGlyphPolicy.overflowCount(memberCount: 7, glyphCellCount: 3) == 4)
        #expect(PickyDockFolderGlyphPolicy.overflowCount(memberCount: 3, glyphCellCount: 3) == 0)
        #expect(PickyDockFolderGlyphPolicy.overflowCount(memberCount: 1, glyphCellCount: 4) == 0)
    }
}
