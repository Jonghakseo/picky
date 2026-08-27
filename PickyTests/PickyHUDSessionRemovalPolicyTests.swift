//
//  PickyHUDSessionRemovalPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyHUDSessionRemovalPolicyTests {
    private func state() -> PickyHUDSessionRemovalState {
        PickyHUDSessionRemovalState(
            heldSession: .open("removed"),
            pendingManualAutoOpenSessionID: "removed",
            pendingRequestedOpenSessionID: "keep",
            hoverPreviewSessionID: "removed",
            suppressedHoverSessionID: "keep",
            utilityPanelOpenSessionIDs: ["removed", "keep"]
        )
    }

    @Test func removalClearsOnlyMatchingHUDLocalIdentityState() throws {
        let result = PickyHUDSessionRemovalPolicy.applying(
            .init(revision: 3, sessionIDs: ["removed"]),
            after: 2,
            to: state()
        )

        let applied = try #require(result)
        #expect(applied.handledRevision == 3)
        #expect(applied.state.heldSession == nil)
        #expect(applied.state.pendingManualAutoOpenSessionID == nil)
        #expect(applied.state.pendingRequestedOpenSessionID == "keep")
        #expect(applied.state.hoverPreviewSessionID == nil)
        #expect(applied.state.suppressedHoverSessionID == "keep")
        #expect(applied.state.utilityPanelOpenSessionIDs == ["keep"])
    }

    @Test func replayedRevisionIsIdempotent() throws {
        let event = PickyHUDDockRemovalEvent(revision: 3, sessionIDs: ["removed"])
        let first = try #require(PickyHUDSessionRemovalPolicy.applying(event, after: 2, to: state()))

        #expect(PickyHUDSessionRemovalPolicy.applying(
            event,
            after: first.handledRevision,
            to: first.state
        ) == nil)
    }

    @Test func rehydratedSameIDSurvivesAnAlreadyHandledRemovalRevision() {
        let rehydrated = PickyHUDSessionRemovalState(
            heldSession: .open("removed"),
            pendingManualAutoOpenSessionID: "removed",
            pendingRequestedOpenSessionID: nil,
            hoverPreviewSessionID: "removed",
            suppressedHoverSessionID: nil,
            utilityPanelOpenSessionIDs: ["removed"]
        )

        #expect(PickyHUDSessionRemovalPolicy.applying(
            .init(revision: 3, sessionIDs: ["removed"]),
            after: 3,
            to: rehydrated
        ) == nil)
    }

    @Test func toastInvalidationMatchesOnlyAuthoritativelyRemovedSessions() {
        #expect(PickyHUDArchiveUndoToastRemovalPolicy.shouldInvalidate(
            toastSessionID: "removed",
            removedSessionIDs: ["removed"]
        ))
        #expect(!PickyHUDArchiveUndoToastRemovalPolicy.shouldInvalidate(
            toastSessionID: "keep",
            removedSessionIDs: ["removed"]
        ))
    }
}
