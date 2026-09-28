//
//  PickyHUDUtilityPanelPolicyTests.swift
//  PickyTests
//

import AppKit
import SwiftUI
import Testing
@testable import Picky

struct PickyHUDUtilityPanelPolicyTests {
    @Test func hiddenTerminalRequestsFocusOnlyWhenEligible() {
        #expect(PickySessionExtendedTerminalFocusPolicy.shouldRequestFocus(isFocusEligible: true))
        #expect(!PickySessionExtendedTerminalFocusPolicy.shouldRequestFocus(isFocusEligible: false))
    }

    @Test @MainActor func switchingAwayFromTerminalResignsTerminalOrDescendantFocus() {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let terminal = PickySwiftTermView(frame: panel.contentView?.bounds ?? .zero)
        let descendant = NSTextView(frame: terminal.bounds)
        terminal.addSubview(descendant)
        panel.contentView = terminal
        defer { panel.close() }

        #expect(panel.makeFirstResponder(descendant))
        #expect(PickySessionExtendedTerminalFocusPolicy.terminalOwnsFirstResponder(panel.firstResponder, terminalView: terminal))
        #expect(PickySessionExtendedTerminalFocusPolicy.resignTerminalFocusIfIneligible(terminal, isFocusEligible: false))
        #expect(!PickySessionExtendedTerminalFocusPolicy.terminalOwnsFirstResponder(panel.firstResponder, terminalView: terminal))
    }

    /// Heights saved by the former `@AppStorage` (a Double under the same key)
    /// must survive the move to explicit persistence.
    @Test func storedPanelHeightKeepsExistingDefaultsFormat() throws {
        let suiteName = "PickyHUDUtilityPanelPolicyTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(PickyHUDUtilityPanelPolicy.storedHeight(in: defaults) == PickyHUDUtilityPanelPolicy.defaultHeight)

        defaults.set(Double(312), forKey: "pickyHUD.utilityPanel.height")
        #expect(PickyHUDUtilityPanelPolicy.storedHeight(in: defaults) == 312)

        PickyHUDUtilityPanelPolicy.storeHeight(180, in: defaults)
        #expect(defaults.double(forKey: "pickyHUD.utilityPanel.height") == 180)
        #expect(PickyHUDUtilityPanelPolicy.storedHeight(in: defaults) == 180)
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
