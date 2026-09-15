//
//  PickyHUDDockGroupListDragPolicyTests.swift
//  PickyTests
//
//  Row drag contract for the group list. A drag stays inert inside its source
//  panel and only becomes an external dock drag after a horizontal pull-out.
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListDragPolicyTests {
    @Test func releasingInsideThePanelCancelsWithoutChangingMemberOrder() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isOutsidePanelHorizontally: false,
            isDraggedRowStillPresent: true
        )

        #expect(outcome == .cancel)
    }

    @Test func crossAxisExitPromotesToExternalDragWithoutAResidenceTimer() {
        let isOutsidePanel = PickyHUDDockGroupListDragPolicy.isOutsidePanelHorizontally(
            pointerX: 241,
            panelWidth: 240
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isOutsidePanelHorizontally: isOutsidePanel,
            isDraggedRowStillPresent: true
        )

        #expect(isOutsidePanel)
        #expect(outcome == .promote)
    }

    @Test func verticalTravelStaysInTheSourcePanelAndCancelsOnRelease() {
        let isOutsidePanel = PickyHUDDockGroupListDragPolicy.isOutsidePanelHorizontally(
            pointerX: 120,
            panelWidth: 240
        )
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isOutsidePanelHorizontally: isOutsidePanel,
            isDraggedRowStillPresent: true
        )

        #expect(!isOutsidePanel)
        #expect(outcome == .cancel)
    }

    @Test func aRowThatDisappearsMidDragCancelsEvenWhenPulledOut() {
        let outcome = PickyHUDDockGroupListDragPolicy.outcome(
            isOutsidePanelHorizontally: true,
            isDraggedRowStillPresent: false
        )

        #expect(outcome == .cancel)
    }
}

@MainActor
extension PickyHUDDockGroupListDragPolicyTests {
    @Test func monitorInstallationRequiresACompleteSetAndRemovesPartialTokens() {
        var removed: [Any] = []
        let complete = PickyHUDDockGroupListDragMonitorPolicy.completeSet(
            from: [NSObject(), NSObject(), NSObject(), NSObject()],
            remove: { removed.append($0) }
        )
        #expect(complete?.count == 4)
        #expect(removed.isEmpty)

        let partial = PickyHUDDockGroupListDragMonitorPolicy.completeSet(
            from: [NSObject(), NSObject(), nil, NSObject()],
            remove: { removed.append($0) }
        )
        #expect(partial == nil)
        #expect(removed.count == 3)
    }

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

    @Test func liveMembershipRejectsPromotionAfterStructureChangeBeforeRender() {
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

    @Test func liveMembershipPermitsPromotionAfterContentOnlyUpdates() {
        let membership = PickyHUDDockGroupListLiveMembership(rowIDs: ["alpha", "bravo"])
        let frozenIDs = membership.rowIDs

        membership.update(rowIDs: ["alpha", "bravo"])
        #expect(PickyHUDDockGroupListDragPolicy.isCurrent(
            referenceRowIDs: frozenIDs,
            currentRowIDs: membership.rowIDs
        ))
    }
}
