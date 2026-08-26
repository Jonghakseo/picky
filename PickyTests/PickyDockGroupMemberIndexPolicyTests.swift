//
//  PickyDockGroupMemberIndexPolicyTests.swift
//  PickyTests
//
//  A group keeps archived members in `memberSessionIDs` while the list only
//  renders active ones, so a visible drop position must be translated before
//  it reaches `PickyDockContainer.group(memberIndex:)`.
//

import Foundation
import Testing
@testable import Picky

struct PickyDockGroupMemberIndexPolicyTests {
    private let members = ["archived", "active-a", "active-b"]
    private let active: Set<String> = ["active-a", "active-b"]

    @Test func visibleMembersDropArchivedEntriesAndKeepStoredOrder() {
        #expect(
            PickyDockGroupMemberIndexPolicy.visibleMemberIDs(
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == ["active-a", "active-b"]
        )
    }

    @Test func aHiddenLeadingMemberShiftsEveryVisibleDropPosition() {
        // Dropping onto the first visible row must land after the archived
        // member, not at stored index 0.
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 0,
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 1
        )
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 1,
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 2
        )
    }

    @Test func appendingPastTheLastVisibleRowLandsAtTheStoredTail() {
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 2,
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 3
        )
    }

    @Test func aHiddenMiddleMemberOnlyShiftsRowsAfterIt() {
        let stored = ["active-a", "archived", "active-b"]

        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 0,
                memberSessionIDs: stored,
                activeSessionIDs: active
            ) == 0
        )
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 1,
                memberSessionIDs: stored,
                activeSessionIDs: active
            ) == 2
        )
    }

    @Test func aHiddenTrailingMemberKeepsAppendsBehindIt() {
        let stored = ["active-a", "active-b", "archived"]

        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 2,
                memberSessionIDs: stored,
                activeSessionIDs: active
            ) == 3
        )
    }

    @Test func groupsWithoutHiddenMembersTranslateOneToOne() {
        let stored = ["active-a", "active-b"]

        for index in 0...stored.count {
            #expect(
                PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                    forVisibleIndex: index,
                    memberSessionIDs: stored,
                    activeSessionIDs: active
                ) == index
            )
        }
    }

    @Test func fullyArchivedAndEmptyGroupsAppendAtTheTail() {
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 0,
                memberSessionIDs: ["archived", "gone"],
                activeSessionIDs: []
            ) == 2
        )
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 0,
                memberSessionIDs: [],
                activeSessionIDs: active
            ) == 0
        )
    }

    @Test func outOfRangeVisibleIndicesClampInsteadOfTrapping() {
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: -5,
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 1
        )
        #expect(
            PickyDockGroupMemberIndexPolicy.fullMemberIndex(
                forVisibleIndex: 99,
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 3
        )
    }

    @Test func visibleIndexLookupIgnoresArchivedMembers() {
        #expect(
            PickyDockGroupMemberIndexPolicy.visibleIndex(
                forMemberID: "active-b",
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == 1
        )
        #expect(
            PickyDockGroupMemberIndexPolicy.visibleIndex(
                forMemberID: "archived",
                memberSessionIDs: members,
                activeSessionIDs: active
            ) == nil
        )
    }
}
