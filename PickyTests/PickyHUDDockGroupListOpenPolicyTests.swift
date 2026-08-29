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

    @Test func openingANonMemberClosesTheListAndOpeningAMemberKeepsItOpen() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "a",
                openedSessionID: "member",
                memberSessionIDs: ["member", "archived"]
            ) == "a"
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "a",
                openedSessionID: "other",
                memberSessionIDs: ["member", "archived"]
            ) == nil
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "a",
                openedSessionID: nil,
                memberSessionIDs: ["member"]
            ) == "a"
        )
    }

    @Test func railReflowKeepsAListTheUserOpenedOverAnUnrelatedCard() {
        // Opening group B while a group A member holds the card is legitimate.
        // Only a genuine card-open transition may close it, otherwise a member
        // drag's own rail reflow tears the list down mid-gesture.
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "b",
                previousOpenedSessionID: "a-member",
                openedSessionID: "a-member",
                memberSessionIDs: ["b-member"]
            ) == "b"
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "b",
                previousOpenedSessionID: "b-member",
                openedSessionID: "a-member",
                memberSessionIDs: ["b-member"]
            ) == nil
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.afterOpeningSession(
                openGroupID: "b",
                previousOpenedSessionID: "a-member",
                openedSessionID: nil,
                memberSessionIDs: ["b-member"]
            ) == "b"
        )
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

    @Test func tapBeforeGeometryKeepsTheLatestFolderRequestPending() {
        #expect(PickyHUDDockGroupListOpenPolicy.pendingGroupID(afterRequestFor: "a") == "a")
        #expect(PickyHUDDockGroupListOpenPolicy.pendingGroupID(afterRequestFor: "b") == "b")
    }

    @Test func geometryArrivalOpensThePendingFolderOnlyWhenItsAnchorIsReady() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.pendingGroupIDReadyToOpen(
                "a",
                anchoredGroupIDs: ["a"],
                hasRailFrame: true
            ) == "a"
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.pendingGroupIDReadyToOpen(
                "a",
                anchoredGroupIDs: ["a"],
                hasRailFrame: false
            ) == nil
        )
    }

    @Test func pendingOpenRequiresAnExistingGroupEligibleForMemberDisclosure() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
                "a",
                existingGroupIDs: ["a", "b"],
                visibleMemberGroupIDs: ["a"]
            ) == "a"
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
                "a",
                existingGroupIDs: ["b"],
                visibleMemberGroupIDs: ["a"]
            ) == nil
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
                "a",
                existingGroupIDs: ["a"],
                visibleMemberGroupIDs: []
            ) == nil
        )
    }

    @Test func reconciliationKeepsAListOpenWhileAtLeastOneVisibleRowRemains() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciliation(
                openGroupID: "group",
                visibleRowIDs: ["first", "second"]
            ) == .keepOpen(groupID: "group")
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciliation(
                openGroupID: "group",
                visibleRowIDs: ["only"]
            ) == .keepOpen(groupID: "group")
        )
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciliation(
                openGroupID: "group",
                visibleRowIDs: []
            ) == .tearDown
        )
    }

    @Test func reconciliationRequiresAnOpenGroupEvenWhenSeveralRowsRemain() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciliation(
                openGroupID: nil,
                visibleRowIDs: ["first", "second", "third"]
            ) == .tearDown
        )
    }
}
