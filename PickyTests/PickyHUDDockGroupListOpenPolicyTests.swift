//
//  PickyHUDDockGroupListOpenPolicyTests.swift
//  PickyTests
//
//  The group list is an accordion that never touches the conversation card's
//  own open state.
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListOpenPolicyTests {
    @Test func tappingAClosedFolderOpensItAndTappingItAgainCloses() {
        #expect(PickyHUDDockGroupListOpenPolicy.toggled(openGroupID: nil, tappedGroupID: "a") == "a")
        #expect(PickyHUDDockGroupListOpenPolicy.toggled(openGroupID: "a", tappedGroupID: "a") == nil)
    }

    @Test func tappingAnotherFolderReplacesTheOpenListInOneStep() {
        #expect(PickyHUDDockGroupListOpenPolicy.toggled(openGroupID: "a", tappedGroupID: "b") == "b")
    }

    @Test func selectingARowClosesTheListSoTheCardIsNeverCovered() {
        #expect(PickyHUDDockGroupListOpenPolicy.afterSelectingRow(openGroupID: "a") == nil)
    }

    @Test func removingTheOwningGroupClosesTheListAndOtherRemovalsDoNot() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterGroupRemoved(
                openGroupID: "a",
                removedGroupID: "a"
            ) == nil
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterGroupRemoved(
                openGroupID: "a",
                removedGroupID: "b"
            ) == "a"
        )
    }

    @Test func anchorInvalidationClosesRatherThanReanchoring() {
        #expect(PickyHUDDockGroupListOpenPolicy.afterAnchorInvalidated() == nil)
    }

    @Test func legacyLayoutsWithSeveralExpandedGroupsKeepOnlyTheFirstInDockOrder() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.normalizedLegacyOpenState(
                groupIDsInDockOrder: ["a", "b", "c"],
                expandedGroupIDs: ["c", "b"]
            ) == "b"
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.normalizedLegacyOpenState(
                groupIDsInDockOrder: ["a", "b"],
                expandedGroupIDs: []
            ) == nil
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.normalizedLegacyOpenState(
                groupIDsInDockOrder: ["a", "b"],
                expandedGroupIDs: ["missing"]
            ) == nil
        )
    }
}
