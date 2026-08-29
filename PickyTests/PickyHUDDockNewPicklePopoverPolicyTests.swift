//
//  PickyHUDDockNewPicklePopoverPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyHUDDockNewPicklePopoverPolicyTests {
    @Test func groupTargetPresentsOnlyFromMatchingGroupAnchor() {
        #expect(PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeAnchorGroupID: "group-b",
            anchorGroupID: "group-b"
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeAnchorGroupID: "group-b",
            anchorGroupID: "group-a"
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeAnchorGroupID: "group-b",
            anchorGroupID: nil
        ))
    }

    @Test func dockTargetPresentsFromBottomAnchorAndExpandsAddSlot() {
        #expect(PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeAnchorGroupID: nil,
            anchorGroupID: nil
        ))
        #expect(PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: true,
            activeAnchorGroupID: nil
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: true,
            activeAnchorGroupID: "group-b"
        ))
    }

    @Test func pickerSelectionReadsRoutingStateBeforeDismissalClearsIt() {
        var activeTargetGroupID: String? = "group-b"
        var receivedTargetGroupID: String?

        PickyRecentPickleFolderPickerSelection.perform(
            action: { receivedTargetGroupID = activeTargetGroupID },
            dismiss: { activeTargetGroupID = nil }
        )

        #expect(receivedTargetGroupID == "group-b")
        #expect(activeTargetGroupID == nil)
    }

    @Test func groupTilePromotesExactlyOneVisibleMemberToAFullSession() {
        #expect(PickyHUDDockGroupTilePresentation.resolve(visibleMemberIDs: []) == .empty)
        #expect(PickyHUDDockGroupTilePresentation.resolve(visibleMemberIDs: ["only"]) == .singleSession(sessionID: "only"))
        #expect(PickyHUDDockGroupTilePresentation.resolve(visibleMemberIDs: ["first", "second"]) == .folder)
    }

    @Test func emptyGroupSlotRemainsADropDestination() {
        let layout = PickyDockLayout(entries: [
            .session(id: "loose"),
            .group(PickyDockGroup(id: "empty", memberSessionIDs: []))
        ])
        let projection = PickyDockProjector.project(layout: layout, visibleSessionIDs: ["loose"])
        let slots = projection.slots.compactMap { slot -> PickyDockDropResolver.SlotCandidate? in
            guard let container = slot.container else { return nil }
            return .init(container: container, center: 0)
        }

        let destination = PickyDockDropResolver.resolveDropContainer(
            draggedSessionID: "loose",
            cursorAxis: 100,
            slotCandidates: slots,
            emptyGroupCandidates: [.init(groupID: "empty", center: 100)],
            layout: layout,
            slotPitch: 100
        )

        #expect(destination == .group(id: "empty", memberIndex: 0))
    }
}
