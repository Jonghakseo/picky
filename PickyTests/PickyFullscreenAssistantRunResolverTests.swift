//
//  PickyFullscreenAssistantRunResolverTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenAssistantRunResolver")
struct PickyFullscreenAssistantRunResolverTests {
    @Test func currentAssistantRunWins() {
        let current = PickyAssistantRunMetadata(model: "openai/gpt-current", thinkingLevel: .high)
        let historical = PickyAssistantRunMetadata(model: "openai/gpt-old", thinkingLevel: .low)

        let resolved = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(
            currentAssistantRun: current,
            messages: [message("m1", kind: .agentText, assistantRun: historical)]
        )

        #expect(resolved == current)
    }

    @Test func fallsBackToMostRecentMessageAssistantRun() {
        let old = PickyAssistantRunMetadata(model: "openai/gpt-old", thinkingLevel: .low)
        let latest = PickyAssistantRunMetadata(model: "openai/gpt-latest", thinkingLevel: .medium)

        let resolved = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(
            currentAssistantRun: nil,
            messages: [
                message("m1", kind: .agentText, assistantRun: old),
                message("m2", kind: .agentActivity),
                message("m3", kind: .agentText, assistantRun: latest)
            ]
        )

        #expect(resolved == latest)
    }

    @Test func returnsNilWithoutCurrentOrHistoricalRun() {
        let resolved = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(
            currentAssistantRun: nil,
            messages: [message("m1", kind: .agentText)]
        )

        #expect(resolved == nil)
    }

    private func message(
        _ id: String,
        kind: PickySessionMessageKind,
        assistantRun: PickyAssistantRunMetadata? = nil
    ) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            originatedBy: nil,
            text: nil,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: nil,
            assistantRun: assistantRun,
            errorContext: nil,
            errorMessage: nil
        )
    }
}
