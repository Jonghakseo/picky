//
//  PickyHUDUtilityPanelPolicyTests.swift
//  PickyTests
//

import SwiftUI
import Testing
@testable import Picky

struct PickyHUDUtilityPanelPolicyTests {
    @Test func tabSelectionDefaultsToTerminalAndRemainsScopedToItsSession() {
        let initial: [String: PickyHUDUtilityPanelTab] = ["other": .terminal]
        let selections = PickyHUDUtilityPanelPolicy.selectionsAfterSelecting(
            .changes,
            sessionID: "pickle-a",
            selections: initial
        )

        #expect(PickyHUDUtilityPanelPolicy.selectedTab(for: "pickle-a", selections: selections) == .changes)
        #expect(PickyHUDUtilityPanelPolicy.selectedTab(for: "other", selections: selections) == .terminal)
        #expect(PickyHUDUtilityPanelPolicy.selectedTab(for: "unseen", selections: selections) == .terminal)
    }

    @Test func panelHeightClampsToMinimumAndAvailableHeightFraction() {
        #expect(PickyHUDUtilityPanelPolicy.clampedHeight(20, availableCardHeight: 1_000) == 120)
        #expect(PickyHUDUtilityPanelPolicy.clampedHeight(400, availableCardHeight: 500) == 300)
        #expect(PickyHUDUtilityPanelPolicy.clampedHeight(240, availableCardHeight: 1_000) == 240)
    }

    @Test func openStateToggleOnlyChangesTheRequestedSession() {
        let initiallyOpen: Set<String> = ["pickle-a", "pickle-b"]
        let closed = PickyHUDUtilityPanelPolicy.openSessionIDsAfterToggling(
            sessionID: "pickle-a",
            openSessionIDs: initiallyOpen
        )
        let reopened = PickyHUDUtilityPanelPolicy.openSessionIDsAfterToggling(
            sessionID: "pickle-a",
            openSessionIDs: closed
        )

        #expect(closed == ["pickle-b"])
        #expect(reopened == initiallyOpen)
    }

    @Test func conversationCardHeightReservesDynamicPanelAndGrip() {
        #expect(
            PickyHUDUtilityPanelPolicy.conversationCardMaxHeight(
                availableCardHeight: 1_000,
                utilityPanelHeight: 280
            ) == 708
        )
        #expect(
            PickyHUDUtilityPanelPolicy.conversationCardMaxHeight(
                availableCardHeight: 400,
                utilityPanelHeight: 240
            ) == 320
        )
    }
}
