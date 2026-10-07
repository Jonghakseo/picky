//
//  PickyHUDDockInteractionPolicyTests.swift
//  PickyTests
//
//  HUD dock held/open transition policy.
//

import Testing
@testable import Picky

struct PickyHUDDockInteractionPolicyTests {
    @Test func activeTargetIsTheHeldSessionOnlyWhileVisible() {
        let visibleIDs = ["first", "opened"]

        #expect(PickyHUDDockInteractionPolicy.activeSessionID(visibleIDs: visibleIDs, held: .open("opened")) == "opened")
        #expect(PickyHUDDockInteractionPolicy.activeSessionID(visibleIDs: visibleIDs, held: .open("missing")) == nil)
        #expect(PickyHUDDockInteractionPolicy.activeSessionID(visibleIDs: visibleIDs, held: nil) == nil)
    }

    @Test func pointerLeavingTheHUDKeepsAManuallyOpenedCard() {
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: true) == .open("opened"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCloseTimeout(current: .open("opened"), isHUDHovered: false) == .open("opened"))
    }

    @Test func clickAndExplicitOpenResolutionKeepHeldStateExclusiveAndVisibleOnly() {
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterClick(current: nil, clicked: "agent-a") == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-a") == nil)
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterClick(current: .open("agent-a"), clicked: "agent-b") == .open("agent-b"))

        #expect(PickyHUDDockInteractionPolicy.manualAutoOpenResolution(pendingSessionID: nil, visibleIDs: ["manual-pickle"]) == nil)
        #expect(PickyHUDDockInteractionPolicy.manualAutoOpenResolution(pendingSessionID: "manual-pickle", visibleIDs: ["other"]) == nil)
        #expect(PickyHUDDockInteractionPolicy.manualAutoOpenResolution(pendingSessionID: "manual-pickle", visibleIDs: ["other", "manual-pickle"]) == .open("manual-pickle"))

        #expect(PickyHUDDockInteractionPolicy.requestedOpenResolution(pendingSessionID: nil, visibleIDs: ["notified-pickle"]) == nil)
        #expect(PickyHUDDockInteractionPolicy.requestedOpenResolution(pendingSessionID: "notified-pickle", visibleIDs: ["other"]) == nil)
        #expect(PickyHUDDockInteractionPolicy.requestedOpenResolution(pendingSessionID: "notified-pickle", visibleIDs: ["other", "notified-pickle"]) == .open("notified-pickle"))
    }

    @Test func numberAndCycleShortcutsResolveStableHeldState() {
        let visibleIDs = ["agent-a", "agent-b", "agent-c"]

        #expect(PickyHUDDockInteractionPolicy.numberShortcutForSessionIndex(0) == 1)
        #expect(PickyHUDDockInteractionPolicy.numberShortcutForSessionIndex(8) == 9)
        #expect(PickyHUDDockInteractionPolicy.numberShortcutForSessionIndex(9) == nil)
        #expect(PickyHUDDockInteractionPolicy.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: 1) == "agent-a")
        #expect(PickyHUDDockInteractionPolicy.sessionIDForNumberShortcut(visibleIDs: visibleIDs, number: 4) == nil)
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(current: nil, visibleIDs: visibleIDs, number: 1) == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(current: nil, visibleIDs: visibleIDs, number: 3) == .open("agent-c"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 1) == nil)
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 2) == .open("agent-b"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterNumberShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, number: 4) == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: nil, visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, direction: 1) == .open("agent-b"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: .open("agent-c"), visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: visibleIDs, direction: -1) == .open("agent-c"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: .open("missing"), visibleIDs: visibleIDs, direction: 1) == .open("agent-a"))
        #expect(PickyHUDDockInteractionPolicy.heldSessionAfterCycleShortcut(current: .open("agent-a"), visibleIDs: [], direction: 1) == .open("agent-a"))
    }
}
