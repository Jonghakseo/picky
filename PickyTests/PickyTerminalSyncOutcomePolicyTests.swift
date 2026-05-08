//
//  PickyTerminalSyncOutcomePolicyTests.swift
//  PickyTests
//
//  Verifies which terminal-overlay sync outcomes earn a HUD banner.
//

import Foundation
import Testing
@testable import Picky

@Suite(.serialized)
struct PickyTerminalSyncOutcomePolicyTests {

    @Test func nothingNewOutcomeIsSuppressed() {
        let outcome = PickyTerminalSessionSyncOutcome(
            sessionId: "session-1",
            baselineFound: true,
            importedMessageCount: 0,
            activeLastMessageId: "a1",
            baselinePiMessageId: "a1"
        )

        #expect(PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) == false)
    }

    @Test func importedMessagesSurfaceBanner() {
        let outcome = PickyTerminalSessionSyncOutcome(
            sessionId: "session-1",
            baselineFound: true,
            importedMessageCount: 3,
            activeLastMessageId: "a4",
            baselinePiMessageId: "a1"
        )

        #expect(PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) == true)
    }

    @Test func baselineMissingSurfaceBannerEvenWithZeroImports() {
        // Baseline missing typically means pi compacted or branched the
        // transcript silently; the user still needs to know the card was
        // not updated even though no messages were imported.
        let outcome = PickyTerminalSessionSyncOutcome(
            sessionId: "session-1",
            baselineFound: false,
            importedMessageCount: 0,
            activeLastMessageId: nil,
            baselinePiMessageId: nil
        )

        #expect(PickyTerminalSyncOutcomePolicy.shouldSurfaceBanner(for: outcome) == true)
    }
}
