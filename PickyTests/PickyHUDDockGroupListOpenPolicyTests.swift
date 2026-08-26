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

    @Test func deletingAPendingGroupClearsTheDeferredOpen() {
        #expect(
            PickyHUDDockGroupListOpenPolicy.reconciledPendingGroupID(
                "a",
                existingGroupIDs: ["b"]
            ) == nil
        )
    }
}
