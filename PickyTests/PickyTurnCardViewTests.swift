//
//  PickyTurnCardViewTests.swift
//  PickyTests
//
//  Unit tests for the turn grouping logic that backs PickyTurnCardView.
//

import Foundation
import SwiftUI
import Testing
@testable import Picky

@Suite(.serialized)
struct PickyTurnCardViewTests {

    // MARK: - Grouping

    @Test func groupsSplitOnEachUserText() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1", kind: .agentText, secondsOffset: 1),
            msg("u2", kind: .userText, secondsOffset: 5),
            msg("a2-act", kind: .agentActivity, secondsOffset: 6, activitySnapshot: PickyActivitySummary(bash: 2)),
            msg("a2", kind: .agentText, secondsOffset: 8)
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.map(\.id) == ["u1", "u2"])
        #expect(groups[0].bodyMessages.map(\.id) == ["a1"])
        #expect(groups[1].bodyMessages.map(\.id) == ["a2-act", "a2"])
    }

    @Test func messagesBeforeFirstUserTextBecomePreTurnGroup() {
        let messages: [PickySessionMessage] = [
            msg("a0", kind: .agentText, secondsOffset: 0),
            msg("u1", kind: .userText, secondsOffset: 1),
            msg("a1", kind: .agentText, secondsOffset: 2)
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 2)
        #expect(groups[0].id == PickyTurnGroup.preTurnID)
        #expect(groups[0].userMessage == nil)
        #expect(groups[0].bodyMessages.map(\.id) == ["a0"])
        #expect(groups[1].id == "u1")
    }

    @Test func currentTurnFlagSetOnlyForActiveSessions() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1", kind: .agentText, secondsOffset: 1),
            msg("u2", kind: .userText, secondsOffset: 5)
        ]

        let runningGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .running)
        #expect(runningGroups.map(\.isCurrent) == [false, true])

        let completedGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)
        #expect(completedGroups.map(\.isCurrent) == [false, false])

        let failedGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .failed)
        #expect(failedGroups.map(\.isCurrent) == [false, false])

        let waitingGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .waiting_for_input)
        #expect(waitingGroups.map(\.isCurrent) == [false, true])
    }

    @Test func emptyInputProducesNoGroups() {
        let groups = PickyTurnGrouper.groups(from: [], sessionStatus: .running)
        #expect(groups.isEmpty)
    }

    // MARK: - Default expansion policy

    @Test func turnCardDefaultExpansionFollowsIsCurrent() {
        let currentGroup = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("a1", kind: .agentText, secondsOffset: 1)],
            isCurrent: true
        )
        let pastGroup = PickyTurnGroup(
            id: "u0",
            userMessage: msg("u0", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("a0", kind: .agentText, secondsOffset: 1)],
            isCurrent: false
        )

        let currentCard = PickyTurnCardView(group: currentGroup) { _ in EmptyMessageContent() }
        let pastCard = PickyTurnCardView(group: pastGroup) { _ in EmptyMessageContent() }

        #expect(currentCard.isExpanded == true)
        #expect(pastCard.isExpanded == false)
    }

    // MARK: - Collapsed representative selection

    @Test func collapsedRepresentativeFavorsLastAgentText() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a1", kind: .agentText, secondsOffset: 1, text: "first"),
                msg("a-act", kind: .agentActivity, secondsOffset: 2, activitySnapshot: PickyActivitySummary(bash: 1)),
                msg("a2", kind: .agentText, secondsOffset: 3, text: "final")
            ],
            isCurrent: false
        )

        #expect(group.collapsedRepresentativeMessage?.id == "a2")
    }

    @Test func collapsedRepresentativeFallsBackToErrorWhenNoAgentText() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(bash: 1)),
                msg("a-err", kind: .agentError, secondsOffset: 2, errorMessage: "boom")
            ],
            isCurrent: false
        )

        #expect(group.collapsedRepresentativeMessage?.id == "a-err")
    }

    @Test func collapsedRepresentativeIsNilWhenNoTextOrError() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(bash: 1))
            ],
            isCurrent: false
        )

        #expect(group.collapsedRepresentativeMessage == nil)
    }

    @Test func collapsedRepresentativeSkipsCompactCompletionSystemMessages() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-text", kind: .agentText, secondsOffset: 1, text: "real answer"),
                msg("a-compact", kind: .system, secondsOffset: 2, text: "Session compacted")
            ],
            isCurrent: false
        )

        #expect(group.collapsedRepresentativeMessage?.id == "a-text")
    }

    // MARK: - Summary chip

    @Test func summaryReportsStepsToolsAndElapsed() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act-1", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(edit: 2, bash: 1)),
                msg("a1", kind: .agentText, secondsOffset: 5, text: "ok"),
                msg("a-act-2", kind: .agentActivity, secondsOffset: 6, activitySnapshot: PickyActivitySummary(read: 1)),
                msg("a2", kind: .agentText, secondsOffset: 12, text: "done")
            ],
            isCurrent: false
        )

        #expect(group.summary.stepCount == 4)
        #expect(group.summary.toolCount == 3)
        #expect(group.summary.elapsedSeconds == 12)
        #expect(group.summary.displayText == "4 steps · 3 tools · 12s")
    }

    @Test func summaryUsesSingularFormsForCountOne() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act", kind: .agentActivity, secondsOffset: 30, activitySnapshot: PickyActivitySummary(bash: 1))
            ],
            isCurrent: false
        )

        #expect(group.summary.displayText == "1 step · 1 tool · 30s")
    }

    @Test func summaryFormatsElapsedInMinutesAndHours() {
        let oneMinute = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 90)
        #expect(oneMinute.elapsedDisplayText == "1m")

        let twoHours = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 7200)
        #expect(twoHours.elapsedDisplayText == "2h")

        let twoHoursFifteen = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 8100)
        #expect(twoHoursFifteen.elapsedDisplayText == "2h 15m")
    }

    @Test func summaryWithNoBodyMessagesReportsZeroEverything() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [],
            isCurrent: true
        )

        #expect(group.summary.stepCount == 0)
        #expect(group.summary.toolCount == 0)
        #expect(group.summary.elapsedSeconds == 0)
        #expect(group.summary.displayText == "0 steps · 0 tools · 0s")
    }
}

// Trivial placeholder for view-builder closures in pure-logic tests.
private struct EmptyMessageContent: View {
    var body: some View { Color.clear }
}

private let originDate = Date(timeIntervalSince1970: 1_700_000_000)


private func msg(
    _ id: String,
    kind: PickySessionMessageKind,
    secondsOffset: TimeInterval,
    text: String? = nil,
    activitySnapshot: PickyActivitySummary? = nil,
    errorMessage: String? = nil
) -> PickySessionMessage {
    PickySessionMessage(
        id: id,
        kind: kind,
        createdAt: originDate.addingTimeInterval(secondsOffset),
        originatedBy: nil,
        text: text,
        question: nil,
        cancelledAt: nil,
        activitySnapshot: activitySnapshot,
        assistantRun: nil,
        errorContext: nil,
        errorMessage: errorMessage
    )
}
