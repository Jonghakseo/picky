//
//  PickyFullscreenTurnPolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite("PickyFullscreenTurnPolicy")
struct PickyFullscreenTurnPolicyTests {
    @Test func completedTurnShowsOnlyLastAgentTextAsFinalAnswer() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText, text: "Do it"),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "working"),
                msg("first", kind: .agentText, text: "first draft"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(read: 1)),
                msg("final", kind: .agentText, text: "final answer"),
                msg("system", kind: .system, text: "session compacted")
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["final"])
        #expect(model.statusMessages.map(\.id) == ["system"])
    }

    @Test func completedTurnFallsBackToLastAgentError() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(bash: 1)),
                msg("error-1", kind: .agentError, errorMessage: "first error"),
                msg("error-2", kind: .agentError, errorMessage: "last error")
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["error-2"])
    }

    @Test func completedTurnShowsAgentErrorWhenItFollowsAgentText() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "working"),
                msg("partial", kind: .agentText, text: "partial answer"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(bash: 1)),
                msg("error", kind: .agentError, errorMessage: "terminal failure")
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["error"])
    }

    @Test func completedTurnShowsAgentTextWhenItFollowsAgentError() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("error", kind: .agentError, errorMessage: "recoverable failure"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(read: 1)),
                msg("final", kind: .agentText, text: "recovered final answer")
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["final"])
    }

    @Test func completedTurnStillHidesThinkingAndActivityWhenFinalOutputExists() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "hidden thinking"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 1)),
                msg("final", kind: .agentText, text: "final answer")
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["final"])
    }

    @Test func completedTurnDoesNotUseSystemMessageAsFinalAnswer() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("answer", kind: .agentText, text: "answer"),
                msg("system", kind: .system, text: "system tail")
            ],
            isCurrent: false
        )

        #expect(group.collapsedRepresentativeMessage?.id == "system")

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["answer"])
    }

    @Test func completedTurnIntermediateMessagesIncludeWorkLogButExcludeThinkingAndFinalAnswer() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText, text: "Do it"),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "hidden thinking"),
                msg("draft", kind: .agentText, text: "draft answer"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(read: 1)),
                msg("error", kind: .agentError, errorMessage: "non-final error"),
                msg("final", kind: .agentText, text: "final answer")
            ],
            isCurrent: false
        )

        let messages = PickyFullscreenTurnPolicy.intermediateMessages(for: group, isCurrent: false)

        #expect(messages.map(\.id) == ["draft", "activity", "error"])
    }

    @Test func currentTurnIntermediateMessagesAreEmpty() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("draft", kind: .agentText, text: "draft answer"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(read: 1))
            ],
            isCurrent: true
        )

        let messages = PickyFullscreenTurnPolicy.intermediateMessages(for: group, isCurrent: true)

        #expect(messages.isEmpty)
    }

    @Test func completedTurnWorkDurationUsesFirstAndLastMessageTimestamps() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText, createdAt: Date(timeIntervalSince1970: 100)),
            bodyMessages: [
                msg("draft", kind: .agentText, createdAt: Date(timeIntervalSince1970: 125)),
                msg("final", kind: .agentText, createdAt: Date(timeIntervalSince1970: 153))
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.workDurationSeconds == 53)
    }

    @Test func completedTurnWorkDurationBelowOneSecondIsHidden() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText, createdAt: Date(timeIntervalSince1970: 100)),
            bodyMessages: [
                msg("final", kind: .agentText, createdAt: Date(timeIntervalSince1970: 100.5))
            ],
            isCurrent: false
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.workDurationSeconds == nil)
    }

    @Test func currentTurnShowsLiveProgressAndLatestAssistantTextOnly() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "thinking"),
                msg("first", kind: .agentText, text: "draft"),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 1)),
                msg("latest", kind: .agentText, text: "latest"),
                msg("empty-activity", kind: .agentActivity, activitySnapshot: .zero)
            ],
            isCurrent: true,
            liveActivitySummary: PickyActivitySummary(bash: 2)
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["thinking", "activity", "latest"])
        #expect(model.liveActivitySummary == PickyActivitySummary(bash: 2))
    }

    @Test func currentTurnShowsThinkingOnlyProgress() {
        let group = PickyTurnGroup(
            id: "turn-1",
            userMessage: msg("u1", kind: .userText),
            bodyMessages: [
                msg("thinking", kind: .agentThinking, text: "still thinking")
            ],
            isCurrent: true
        )

        let model = PickyFullscreenTurnPolicy.renderModel(from: group)

        #expect(model.bodyMessages.map(\.id) == ["thinking"])
    }

    @Test func renderModelsMarksLatestActiveTurnCurrent() {
        let models = PickyFullscreenTurnPolicy.renderModels(
            from: [
                msg("u1", kind: .userText),
                msg("a1", kind: .agentText),
                msg("u2", kind: .userText),
                msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(read: 1))
            ],
            sessionStatus: .running,
            liveActivitySummary: PickyActivitySummary(read: 2)
        )

        #expect(models.count == 2)
        #expect(models[0].isCurrent == false)
        #expect(models[1].isCurrent == true)
        #expect(models[1].bodyMessages.map(\.id) == ["activity"])
    }

    @Test func latchedCompletedTurnDoesNotReturnToCurrentProgressDuringFollowUpRace() {
        let messages = [
            msg("u1", kind: .userText, text: "first request"),
            msg("thinking", kind: .agentThinking, text: "hidden thinking"),
            msg("activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(bash: 1)),
            msg("final", kind: .agentText, text: "final answer")
        ]
        let completedGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)
        let completedTurnIDs = Set(completedGroups.filter { !$0.isCurrent }.map(\.id))

        let raceGroups = PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: .running,
            liveActivitySummary: PickyActivitySummary(bash: 2)
        )
        let raceModels = PickyFullscreenTurnPolicy.renderModels(
            from: raceGroups,
            completedTurnIDs: completedTurnIDs
        )

        #expect(raceModels.count == 1)
        #expect(raceModels[0].id == "u1")
        #expect(raceModels[0].isCurrent == false)
        #expect(raceModels[0].bodyMessages.map(\.id) == ["final"])
        #expect(raceModels[0].liveActivitySummary == nil)
    }

    @Test func newFollowUpTurnCanBecomeCurrentAfterCompletedTurnWasLatched() {
        let messages = [
            msg("u1", kind: .userText, text: "first request"),
            msg("final", kind: .agentText, text: "final answer"),
            msg("u2", kind: .userText, text: "follow up"),
            msg("thinking-2", kind: .agentThinking, text: "working on follow-up")
        ]
        let groups = PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: .running,
            liveActivitySummary: PickyActivitySummary(read: 1)
        )

        let models = PickyFullscreenTurnPolicy.renderModels(
            from: groups,
            completedTurnIDs: ["u1"]
        )

        #expect(models.count == 2)
        #expect(models[0].id == "u1")
        #expect(models[0].isCurrent == false)
        #expect(models[0].bodyMessages.map(\.id) == ["final"])
        #expect(models[1].id == "u2")
        #expect(models[1].isCurrent == true)
        #expect(models[1].bodyMessages.map(\.id) == ["thinking-2"])
        #expect(models[1].liveActivitySummary == PickyActivitySummary(read: 1))
    }

    private func msg(
        _ id: String,
        kind: PickySessionMessageKind,
        text: String? = nil,
        activitySnapshot: PickyActivitySummary? = nil,
        errorMessage: String? = nil,
        createdAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> PickySessionMessage {
        PickySessionMessage(
            id: id,
            kind: kind,
            createdAt: createdAt,
            originatedBy: nil,
            text: text,
            question: nil,
            cancelledAt: nil,
            activitySnapshot: activitySnapshot,
            errorContext: nil,
            errorMessage: errorMessage
        )
    }
}
