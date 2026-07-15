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

    @Test func commandReceiptsStartTheirOwnGroup() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1", kind: .agentText, secondsOffset: 1),
            msg("cmd", kind: .commandReceipt, secondsOffset: 2, text: "/c"),
            msg("a2", kind: .agentText, secondsOffset: 3)
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.map(\.id) == ["u1", "cmd"])
        #expect(groups[0].bodyMessages.map(\.id) == ["a1"])
        #expect(groups[1].userMessage?.kind == .commandReceipt)
        #expect(groups[1].bodyMessages.map(\.id) == ["a2"])
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

    // MARK: - Expansion policy (race-window latch)

    @Test func expansionPolicyDefaultsToIsCurrentBeforeAnyObservation() {
        let policy = PickyTurnExpansionPolicy()
        #expect(policy.isExpanded(isCurrent: true) == true)
        #expect(policy.isExpanded(isCurrent: false) == false)
    }

    @Test func expansionPolicyLatchesCollapsedOnceObservedNonCurrent() {
        // Simulates the snapshot-loaded "past" turn: onAppear observes
        // isCurrent=false, then a follow-up submit briefly flips isCurrent=true
        // (race between status:running and the deferred user_text journal
        // write). The latch must keep the card collapsed for the flicker.
        var policy = PickyTurnExpansionPolicy()
        policy.observe(isCurrent: false)
        #expect(policy.isExpanded(isCurrent: true) == false)
        #expect(policy.isExpanded(isCurrent: false) == false)
    }

    @Test func expansionPolicyLatchesCollapsedAfterCurrentToNonCurrentTransition() {
        // Simulates a normal completion: the turn was current (expanded),
        // then the session went idle (isCurrent=false, auto-collapsed).
        // A later follow-up that briefly re-flags the same group as current
        // must NOT re-expand it.
        var policy = PickyTurnExpansionPolicy()
        policy.observe(isCurrent: true)
        #expect(policy.isExpanded(isCurrent: true) == true)
        policy.observe(isCurrent: false)
        #expect(policy.isExpanded(isCurrent: false) == false)
        // The race-window flip back to true must stay collapsed.
        #expect(policy.isExpanded(isCurrent: true) == false)
    }

    @Test func expansionPolicyManualToggleOverridesLatch() {
        var policy = PickyTurnExpansionPolicy()
        policy.observe(isCurrent: false) // latched collapsed
        policy.setManualExpansion(true)
        #expect(policy.isExpanded(isCurrent: false) == true)
        #expect(policy.isExpanded(isCurrent: true) == true)
        policy.setManualExpansion(false)
        #expect(policy.isExpanded(isCurrent: true) == false)
    }

    @Test func expansionPolicyPreservesCurrentTurnExpansionWhenNeverObservedNonCurrent() {
        // A brand-new turn appears as current and has never been observed
        // non-current. It should remain expanded across re-renders.
        var policy = PickyTurnExpansionPolicy()
        policy.observe(isCurrent: true)
        policy.observe(isCurrent: true)
        #expect(policy.isExpanded(isCurrent: true) == true)
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

    @Test func grouperPullsCompactSystemMessagesOutOfBodyIntoTrailing() {
        // Auto-compaction system messages must render outside the (possibly
        // collapsed) turn card so they stay visible no matter the card's
        // expansion state. The grouper extracts them into `trailingMessages`.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a-text", kind: .agentText, secondsOffset: 1, text: "real answer"),
            msg("a-compact-ok", kind: .system, secondsOffset: 2, text: "Session compacted"),
            msg("a-compact-fail", kind: .system, secondsOffset: 3, text: "Auto-compaction failed\n\nSummarization failed.\n\nContext was not reduced.")
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        #expect(groups[0].bodyMessages.map(\.id) == ["a-text"])
        #expect(groups[0].trailingMessages.map(\.id) == ["a-compact-ok", "a-compact-fail"])
        // Once compact messages live outside the body, the collapsed representative
        // is just the latest agent text — no special-case filter needed.
        #expect(groups[0].collapsedRepresentativeMessage?.id == "a-text")
    }

    @Test func grouperKeepsCompactTrailingWhenSessionIsActive() {
        // The compaction tail can land on the current turn too (mid-turn
        // overflow compaction). The trailing slot must survive when the
        // grouper re-wraps the last group as `isCurrent`.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a-text", kind: .agentText, secondsOffset: 1, text: "step"),
            msg("a-compact-ok", kind: .system, secondsOffset: 2, text: "Session compacted after context overflow")
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .running)

        #expect(groups.count == 1)
        #expect(groups[0].isCurrent)
        #expect(groups[0].bodyMessages.map(\.id) == ["a-text"])
        #expect(groups[0].trailingMessages.map(\.id) == ["a-compact-ok"])
    }

    @Test func grouperHoistsPendingQuestionOutOfBodyIntoTrailing() {
        // A pending extension-ui question must never hide behind a collapsed
        // turn card. When the question lands in a turn without its own leading
        // user message (follow-up on an idle session whose user_text only
        // drains after the turn ends), the previous completed turn's collapsed
        // card would swallow the INPUT NEEDED bubble.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a-text", kind: .agentText, secondsOffset: 1, text: "report"),
            questionMsg("q-pending", requestID: "req-1", secondsOffset: 2)
        ]

        let groups = PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: .waiting_for_input,
            pendingQuestionRequestID: "req-1"
        )

        #expect(groups.count == 1)
        #expect(groups[0].bodyMessages.map(\.id) == ["a-text"])
        #expect(groups[0].trailingMessages.map(\.id) == ["q-pending"])
    }

    @Test func grouperKeepsAnsweredQuestionInBody() {
        // Once the request is answered/cancelled the pending id no longer
        // matches, so the question returns to the body as regular history.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            questionMsg("q-old", requestID: "req-1", secondsOffset: 1),
            msg("a-text", kind: .agentText, secondsOffset: 2, text: "done")
        ]

        let answered = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed, pendingQuestionRequestID: nil)
        #expect(answered[0].bodyMessages.map(\.id) == ["q-old", "a-text"])
        #expect(answered[0].trailingMessages.isEmpty)

        let otherPending = PickyTurnGrouper.groups(from: messages, sessionStatus: .waiting_for_input, pendingQuestionRequestID: "req-2")
        #expect(otherPending[0].bodyMessages.map(\.id) == ["q-old", "a-text"])
        #expect(otherPending[0].trailingMessages.isEmpty)
    }

    // MARK: - Summary chip

    @Test func completedSummaryReportsToolsAndElapsedWithoutSteps() {
        // agentActivity snapshots are cumulative across the live turn, so the
        // last snapshot in the body holds the turn's running total. Earlier
        // snapshots are subsumed by it; the summary uses only the latest.
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act-1", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(edit: 2, bash: 1)),
                msg("a1", kind: .agentText, secondsOffset: 5, text: "ok"),
                msg("a-act-2", kind: .agentActivity, secondsOffset: 6, activitySnapshot: PickyActivitySummary(edit: 2, bash: 1, read: 1)),
                msg("a2", kind: .agentText, secondsOffset: 12, text: "done")
            ],
            isCurrent: false
        )

        #expect(group.summary.stepCount == 4)
        #expect(!group.summary.showsStepCount)
        #expect(group.summary.toolCount == 4)
        #expect(group.summary.elapsedSeconds == 12)
        #expect(group.summary.displayText == "4 tools · 12s")
    }

    @Test func completedSummaryUsesSingularToolFormForCountOne() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act", kind: .agentActivity, secondsOffset: 30, activitySnapshot: PickyActivitySummary(bash: 1))
            ],
            isCurrent: false
        )

        #expect(group.summary.displayText == "1 tool · 30s")
    }

    @Test func summaryFormatsElapsedInMinutesAndHours() {
        let oneMinute = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 90)
        #expect(oneMinute.elapsedDisplayText == "1m")

        let twoHours = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 7200)
        #expect(twoHours.elapsedDisplayText == "2h")

        let twoHoursFifteen = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 8100)
        #expect(twoHoursFifteen.elapsedDisplayText == "2h 15m")
    }

    @Test func currentSummaryUsesInjectedNowForLiveElapsedTime() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("t", kind: .agentThinking, secondsOffset: 5)],
            isCurrent: true
        )

        #expect(group.summary(now: originDate.addingTimeInterval(22)).elapsedSeconds == 22)
        #expect(group.summary(now: originDate.addingTimeInterval(22)).displayText == "1 step · 22s")
    }

    @Test func completedSummaryIgnoresInjectedNowAndStaysFixed() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("a", kind: .agentText, secondsOffset: 5)],
            isCurrent: false
        )

        #expect(group.summary(now: originDate.addingTimeInterval(22)).elapsedSeconds == 5)
        #expect(group.summary(now: originDate.addingTimeInterval(22)).displayText == "5s")
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
        // `0 tools` is dropped so thinking-only turns and pre-tool moments
        // don't carry a meaningless zero count in the header.
        #expect(group.summary.displayText == "0 steps · 0s")
    }

    @Test func summaryOmitsToolSegmentWhenNoToolsHaveRun() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("t", kind: .agentThinking, secondsOffset: 5)],
            isCurrent: true,
            liveActivitySummary: PickyActivitySummary(thinking: 4)
        )

        // thinking is not counted as a tool invocation, so the segment drops.
        #expect(group.summary.toolCount == 0)
        #expect(group.summary.displayText == "1 step · 5s")
        #expect(!group.summary.displayText.contains("tool"))
    }

    // MARK: - Live activity counter

    @Test func activeTurnReadsLiveActivitySummaryBeforeAgentActivityIsCommitted() {
        // agentd only commits the agentActivity message at turn boundary,
        // so the in-progress turn carries no snapshot inside its body. The
        // header still needs an up-to-date "N tools" count, which it pulls
        // from `liveActivitySummary` (= session.activitySummary).
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("t", kind: .agentThinking, secondsOffset: 1)],
            isCurrent: true,
            liveActivitySummary: PickyActivitySummary(bash: 12, thinking: 3, other: 4, read: 2)
        )

        // thinking is excluded from the tool count by design.
        #expect(group.summary.toolCount == 18)
        #expect(group.summary.displayText.contains("18 tools"))
    }

    @Test func completedTurnIgnoresLiveActivitySummary() {
        // Live counter belongs to the in-progress turn only. Past turns must
        // keep reading their own committed agentActivity snapshot so a new
        // turn's live counter does not bleed into the previous turn's header.
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [
                msg("a-act", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(bash: 1, read: 3))
            ],
            isCurrent: false,
            liveActivitySummary: PickyActivitySummary(read: 99)
        )

        #expect(group.summary.toolCount == 4)
    }

    @Test func grouperRoutesLiveActivitySummaryIntoCurrentTurnOnly() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1-act", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(read: 5)),
            msg("a1", kind: .agentText, secondsOffset: 2),
            msg("u2", kind: .userText, secondsOffset: 3),
            msg("t2", kind: .agentThinking, secondsOffset: 4)
        ]
        let live = PickyActivitySummary(bash: 7)

        let groups = PickyTurnGrouper.groups(
            from: messages,
            sessionStatus: .running,
            liveActivitySummary: live
        )

        #expect(groups.count == 2)
        #expect(groups[0].liveActivitySummary == nil)
        #expect(groups[0].summary.toolCount == 5)
        #expect(groups[1].isCurrent)
        #expect(groups[1].liveActivitySummary == live)
        #expect(groups[1].summary.toolCount == 7)
    }

    // MARK: - Active tool indicator

    @Test func mergeActivitySnapshotsCollapsesPerEntryActivityIntoOneChip() {
        // Pi terminal sync emits one `agent_activity` per Pi assistant entry,
        // so a single turn can carry many small snapshots (read 1, bash 1, …).
        // The grouper should collapse them into one chip at the position of the
        // last activity, preserving its id/createdAt for tool-history scoping.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a-think-1", kind: .agentThinking, secondsOffset: 1, text: "plan"),
            msg("a-act-1", kind: .agentActivity, secondsOffset: 2, activitySnapshot: PickyActivitySummary(read: 1)),
            msg("a-text-1", kind: .agentText, secondsOffset: 3, text: "step one"),
            msg("a-act-2", kind: .agentActivity, secondsOffset: 4, activitySnapshot: PickyActivitySummary(bash: 1)),
            msg("a-text-2", kind: .agentText, secondsOffset: 5, text: "step two"),
            msg("a-act-3", kind: .agentActivity, secondsOffset: 6, activitySnapshot: PickyActivitySummary(edit: 2, bash: 1))
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        let body = groups[0].bodyMessages
        #expect(body.map(\.id) == ["a-think-1", "a-text-1", "a-text-2", "a-act-3"])
        #expect(body.last?.activitySnapshot == PickyActivitySummary(edit: 2, bash: 2, read: 1))
    }

    @Test func mergeActivitySnapshotsLeavesSingleActivityUntouched() {
        // The merge transform must be a no-op for live sessions — they already
        // commit one snapshot per turn via `commitTurnActivityNow`.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a-text", kind: .agentText, secondsOffset: 1, text: "reply"),
            msg("a-act", kind: .agentActivity, secondsOffset: 2, activitySnapshot: PickyActivitySummary(bash: 3, read: 4))
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        #expect(groups[0].bodyMessages.map(\.id) == ["a-text", "a-act"])
        #expect(groups[0].bodyMessages.last?.activitySnapshot == PickyActivitySummary(bash: 3, read: 4))
    }

    @Test func mergeActivitySnapshotsIsScopedPerTurn() {
        // Activities from different turns must not bleed into each other.
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1-act-a", kind: .agentActivity, secondsOffset: 1, activitySnapshot: PickyActivitySummary(read: 2)),
            msg("a1-act-b", kind: .agentActivity, secondsOffset: 2, activitySnapshot: PickyActivitySummary(bash: 1)),
            msg("u2", kind: .userText, secondsOffset: 10),
            msg("a2-act", kind: .agentActivity, secondsOffset: 11, activitySnapshot: PickyActivitySummary(edit: 5))
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 2)
        #expect(groups[0].bodyMessages.map(\.id) == ["a1-act-b"])
        #expect(groups[0].bodyMessages.last?.activitySnapshot == PickyActivitySummary(bash: 1, read: 2))
        #expect(groups[1].bodyMessages.map(\.id) == ["a2-act"])
        #expect(groups[1].bodyMessages.last?.activitySnapshot == PickyActivitySummary(edit: 5))
    }

    @Test func turnCardAcceptsActiveToolForLiveIndicator() {
        // Sanity check: the turn card simply stores the active-tool slot the
        // caller injects. The body renders it as `PickyToolCallInlineRow` on
        // the current turn so users see what's running in real time.
        let active = tool("live", name: "bash", secondsOffset: 0, status: "running")
        let card = PickyTurnCardView(
            group: PickyTurnGroup(
                id: "u1",
                userMessage: msg("u1", kind: .userText, secondsOffset: 0),
                bodyMessages: [msg("a", kind: .agentText, secondsOffset: 1)],
                isCurrent: true
            ),
            activeTool: active,
            onOpenActiveToolHistory: {}
        ) { _ in EmptyMessageContent() }

        #expect(card.activeTool?.toolCallId == "live")
        #expect(card.activeTool?.isActive == true)
        #expect(card.onOpenActiveToolHistory != nil)
    }
}

// Trivial placeholder for view-builder closures in pure-logic tests.
private struct EmptyMessageContent: View {
    var body: some View { Color.clear }
}

private let originDate = Date(timeIntervalSince1970: 1_700_000_000)


private func questionMsg(
    _ id: String,
    requestID: String,
    secondsOffset: TimeInterval
) -> PickySessionMessage {
    PickySessionMessage(
        id: id,
        kind: .agentQuestion,
        createdAt: originDate.addingTimeInterval(secondsOffset),
        originatedBy: nil,
        text: nil,
        question: PickyExtensionUiRequest(
            id: requestID,
            sessionId: "session-1",
            method: "confirm",
            title: "PR merge",
            prompt: "Merge?",
            createdAt: originDate.addingTimeInterval(secondsOffset)
        ),
        cancelledAt: nil,
        activitySnapshot: nil,
        assistantRun: nil,
        errorContext: nil,
        errorMessage: nil
    )
}

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

private func tool(
    _ id: String,
    name: String,
    secondsOffset: TimeInterval,
    status: String = "succeeded"
) -> PickyToolActivity {
    PickyToolActivity(
        toolCallId: id,
        name: name,
        status: status,
        startedAt: originDate.addingTimeInterval(secondsOffset)
    )
}
