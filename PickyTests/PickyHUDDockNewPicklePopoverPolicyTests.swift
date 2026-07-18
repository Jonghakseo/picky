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
            activeTargetGroupID: "group-b",
            anchorGroupID: "group-b"
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeTargetGroupID: "group-b",
            anchorGroupID: "group-a"
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeTargetGroupID: "group-b",
            anchorGroupID: nil
        ))
    }

    @Test func dockTargetPresentsFromBottomAnchorAndExpandsAddSlot() {
        #expect(PickyHUDDockNewPicklePopoverPolicy.isPresented(
            pickerIsPresented: true,
            activeTargetGroupID: nil,
            anchorGroupID: nil
        ))
        #expect(PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: true,
            activeTargetGroupID: nil
        ))
        #expect(!PickyHUDDockNewPicklePopoverPolicy.shouldExpandDockAddSlot(
            pickerIsPresented: true,
            activeTargetGroupID: "group-b"
        ))
    }
}
