//
//  PickyMainAgentActivityStoreTests.swift
//  PickyTests
//
//  Live turn presence contract: which chips are shown, when a finished turn
//  stops counting as in flight, and how the pending question is cleared.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMainAgentActivityStoreTests {
    private func toolActivity(
        id: String,
        name: String = "Read",
        status: String = "running"
    ) -> PickyMainActivity {
        PickyMainActivity(kind: .tool, toolCallId: id, toolName: name, status: status)
    }

    private func question(id: String) -> PickyExtensionUiRequest {
        PickyExtensionUiRequest(
            id: id,
            sessionId: "main",
            method: "ask",
            prompt: "Pick one",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    /// A scheduled clear is an afterglow: chips stay on screen but the turn is
    /// finished, so the cancel pill must stop treating them as in flight.
    @Test func scheduledClearKeepsChipsVisibleButEndsTheLiveTurn() {
        let store = PickyMainAgentActivityStore()
        store.apply(toolActivity(id: "call-1"))
        #expect(store.hasLiveTurnActivities)

        store.scheduleClear()

        #expect(store.liveActivities.count == 1)
        #expect(!store.hasLiveTurnActivities)
    }

    /// A new turn starting during the afterglow must re-arm the cancel pill
    /// instead of inheriting the finished turn's pending clear.
    @Test func aFreshActivityCancelsAPendingClear() {
        let store = PickyMainAgentActivityStore()
        store.apply(toolActivity(id: "call-1"))
        store.scheduleClear()
        #expect(!store.hasLiveTurnActivities)

        store.apply(toolActivity(id: "call-2", status: "running"))

        #expect(store.hasLiveTurnActivities)
        #expect(store.liveActivities.contains { $0.toolCallId == "call-2" })
    }

    @Test func clearImmediatelyDropsChipsWithoutWaiting() {
        let store = PickyMainAgentActivityStore()
        store.apply(toolActivity(id: "call-1"))
        store.scheduleClear()

        store.clearImmediately()

        #expect(store.liveActivities.isEmpty)
        #expect(!store.hasLiveTurnActivities)
    }

    @Test func presenceChangesNotifyTheOwnerOnceEach() {
        let store = PickyMainAgentActivityStore()
        var notifications = 0
        store.onLiveTurnPresenceChanged = { notifications += 1 }

        store.apply(toolActivity(id: "call-1"))
        store.clearImmediately()

        #expect(notifications == 2)
    }

    @Test func onlyTheMatchingQuestionIsCleared() {
        let store = PickyMainAgentActivityStore()
        store.setPendingQuestion(question(id: "req-1"))

        store.clearPendingQuestion(id: "req-other")
        #expect(store.pendingQuestion?.id == "req-1")

        store.clearPendingQuestion(id: "req-1")
        #expect(store.pendingQuestion == nil)
    }
}
