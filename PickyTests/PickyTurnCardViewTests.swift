//
//  PickyTurnCardViewTests.swift
//  PickyTests
//
//  Unit tests for the turn grouping logic that backs PickyTurnCardView.
//

import AppKit
import Combine
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

    @Test func currentTurnFlagTracksActivityWhileLatestAlwaysTracksTheLastTurn() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("a1", kind: .agentText, secondsOffset: 1),
            msg("u2", kind: .userText, secondsOffset: 5)
        ]

        let runningGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .running)
        #expect(runningGroups.map(\.isCurrent) == [false, true])
        #expect(runningGroups.map(\.isLatest) == [false, true])

        let completedGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)
        #expect(completedGroups.map(\.isCurrent) == [false, false])
        #expect(completedGroups.map(\.isLatest) == [false, true])

        let failedGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .failed)
        #expect(failedGroups.map(\.isCurrent) == [false, false])
        #expect(failedGroups.map(\.isLatest) == [false, true])

        let waitingGroups = PickyTurnGrouper.groups(from: messages, sessionStatus: .waiting_for_input)
        #expect(waitingGroups.map(\.isCurrent) == [false, true])
        #expect(waitingGroups.map(\.isLatest) == [false, true])
    }

    @Test func emptyInputProducesNoGroups() {
        let groups = PickyTurnGrouper.groups(from: [], sessionStatus: .running)
        #expect(groups.isEmpty)
    }


    @MainActor
    @Test func expandedChapterKeepsRequestAndFirstResponseVisuallySeparated() {
        let detailWidth: CGFloat = 400
        let user = msg(
            "u1",
            kind: .userText,
            secondsOffset: 0,
            text: "나 뿐만 아니라 모든 팀원들의 데이터가 필요해서 깃헙 이력이 필요해."
        )
        let response = msg("a1", kind: .agentText, secondsOffset: 1, text: "reasoning")

        func fittingHeight<Content: View>(_ content: Content) -> CGFloat {
            let host = NSHostingView(rootView: content)
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.height
        }

        func renderedHeight(bodyMessages: [PickySessionMessage]) -> CGFloat {
            let group = PickyTurnGroup(
                id: user.id,
                userMessage: user,
                bodyMessages: bodyMessages,
                isCurrent: true,
                isLatest: true
            )
            return fittingHeight(
                PickyTurnCardView(group: group) { message in
                    if message.kind == .userText {
                        PickyUserBubbleView(message: message)
                    } else {
                        PickyAgentBubbleView(message: message)
                    }
                }
                .frame(width: detailWidth)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.pickyHUDDetailWidth, detailWidth)
            )
        }

        let responseHeight = fittingHeight(
            PickyAgentBubbleView(message: response)
                .frame(width: detailWidth)
                .fixedSize(horizontal: false, vertical: true)
                .environment(\.pickyHUDDetailWidth, detailWidth)
        )
        let measuredSpacing = renderedHeight(bodyMessages: [response])
            - renderedHeight(bodyMessages: [])
            - responseHeight

        #expect(abs(measuredSpacing - DS.Spacing.space5) < 0.5)
    }

    @MainActor
    @Test func completedRenderedChapterDoesNotReviveFinalToolDuringDelayedBoundary() {
        let user = msg("u1", kind: .userText, secondsOffset: 0, text: "first turn")
        let response = msg("a1", kind: .agentText, secondsOffset: 1, text: "done")
        let model = DelayedTurnBoundaryModel(group: PickyTurnGroup(
            id: user.id,
            userMessage: user,
            bodyMessages: [response],
            isCurrent: false,
            isLatest: true
        ))
        let staleTool = tool("previous-tool", name: "read", secondsOffset: 1, status: "succeeded")
        let host = NSHostingView(rootView:
            DelayedTurnBoundaryHarness(model: model, staleTool: staleTool)
                .frame(width: 400)
                .fixedSize(horizontal: false, vertical: true)
        )

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()
        let settledHeight = host.fittingSize.height

        model.group = PickyTurnGroup(
            id: user.id,
            userMessage: user,
            bodyMessages: [response],
            isCurrent: true,
            isLatest: true
        )
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        host.layoutSubtreeIfNeeded()

        #expect(abs(host.fittingSize.height - settledHeight) < 0.5)
    }

    // MARK: - Expansion policy (race-window latch)

    @Test func completedTurnStaysVisuallySettledDuringDelayedUserTextBoundary() {
        // The same status-before-user_text race must not recolor the completed
        // turn as current or revive its final tool call as a live inline row.
        var policy = PickyTurnLiveStatePolicy()
        policy.observe(isCurrent: false)

        #expect(!policy.isVisuallyCurrent(isCurrent: true))
        #expect(!policy.isVisuallyCurrent(isCurrent: false))
    }

    @Test func brandNewTurnCanPresentAsCurrentBeforeAnyCompletedObservation() {
        let policy = PickyTurnLiveStatePolicy()

        #expect(policy.isVisuallyCurrent(isCurrent: true))
        #expect(!policy.isVisuallyCurrent(isCurrent: false))
    }

    // MARK: - Collapsed representative selection

    // MARK: - Focus Stack prior chapter presentation

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
        #expect(group.summary.displayText == "\(L10n.t("hud.conversation.turn.tool.many", Int64(4))) · \(L10n.t("hud.conversation.duration.seconds", Int64(12)))")
        #expect(group.summary.expandedDisplayText == L10n.t("hud.conversation.duration.seconds", Int64(12)))
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

        #expect(group.summary.displayText == "\(L10n.t("hud.conversation.turn.tool.one", Int64(1))) · \(L10n.t("hud.conversation.duration.seconds", Int64(30)))")
    }

    @Test func summaryFormatsElapsedInMinutesAndHours() {
        let oneMinute = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 90)
        #expect(oneMinute.elapsedDisplayText == L10n.t("hud.conversation.duration.minutes", Int64(1)))

        let twoHours = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 7200)
        #expect(twoHours.elapsedDisplayText == L10n.t("hud.conversation.duration.hours", Int64(2)))

        let twoHoursFifteen = PickyTurnSummary(stepCount: 1, toolCount: 0, elapsedSeconds: 8100)
        #expect(twoHoursFifteen.elapsedDisplayText == L10n.t("hud.conversation.duration.hoursMinutes", Int64(2), Int64(15)))
    }

    @Test func currentSummaryUsesInjectedNowForLiveElapsedTime() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("t", kind: .agentThinking, secondsOffset: 5)],
            isCurrent: true
        )

        #expect(group.summary(now: originDate.addingTimeInterval(22)).elapsedSeconds == 22)
        #expect(group.summary(now: originDate.addingTimeInterval(22)).displayText == "\(L10n.t("hud.conversation.turn.step.one", Int64(1))) · \(L10n.t("hud.conversation.duration.seconds", Int64(22)))")
    }

    @Test func completedSummaryIgnoresInjectedNowAndStaysFixed() {
        let group = PickyTurnGroup(
            id: "u1",
            userMessage: msg("u1", kind: .userText, secondsOffset: 0),
            bodyMessages: [msg("a", kind: .agentText, secondsOffset: 5)],
            isCurrent: false
        )

        #expect(group.summary(now: originDate.addingTimeInterval(22)).elapsedSeconds == 5)
        #expect(group.summary(now: originDate.addingTimeInterval(22)).displayText == L10n.t("hud.conversation.duration.seconds", Int64(5)))
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
        #expect(group.summary.displayText == "\(L10n.t("hud.conversation.turn.step.many", Int64(0))) · \(L10n.t("hud.conversation.duration.seconds", Int64(0)))")
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
        #expect(group.summary.displayText == "\(L10n.t("hud.conversation.turn.step.one", Int64(1))) · \(L10n.t("hud.conversation.duration.seconds", Int64(5)))")
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
        #expect(group.summary.displayText.contains(L10n.t("hud.conversation.turn.tool.many", Int64(18))))
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

    // MARK: - Thinking phase merging

    @Test func mergeConsecutiveThinkingMergesAdjacentPhasesIntoSingleBubble() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("t1", kind: .agentThinking, secondsOffset: 1, text: "first pass"),
            msg("t2", kind: .agentThinking, secondsOffset: 2, text: "second pass"),
            msg("a1", kind: .agentText, secondsOffset: 3, text: "done")
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        let body = groups[0].bodyMessages
        #expect(body.map(\.id) == ["t1", "a1"])
        #expect(body.first?.text == "first pass\n\nsecond pass")
        #expect(body.first?.createdAt == originDate.addingTimeInterval(2))
    }

    @Test func mergeConsecutiveThinkingStopsAtNonThinkingMessage() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("t1", kind: .agentThinking, secondsOffset: 1, text: "thinking start"),
            msg("a1", kind: .agentText, secondsOffset: 2, text: "response"),
            msg("t2", kind: .agentThinking, secondsOffset: 3, text: "extra thought"),
            msg("t3", kind: .agentThinking, secondsOffset: 4, text: "final thought")
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        let body = groups[0].bodyMessages
        #expect(body.map(\.id) == ["t1", "a1", "t2"])
        #expect(body[2].text == "extra thought\n\nfinal thought")
    }

    @Test func mergeConsecutiveThinkingDoesNotCrossTurnBoundary() {
        let messages: [PickySessionMessage] = [
            msg("u1", kind: .userText, secondsOffset: 0),
            msg("t1", kind: .agentThinking, secondsOffset: 1, text: "first run"),
            msg("t2", kind: .agentThinking, secondsOffset: 2, text: "same run"),
            msg("u2", kind: .userText, secondsOffset: 10),
            msg("t3", kind: .agentThinking, secondsOffset: 11, text: "second run"),
            msg("t4", kind: .agentThinking, secondsOffset: 12, text: "also second run")
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 2)
        #expect(groups[0].bodyMessages.map(\.id) == ["t1"])
        #expect(groups[1].bodyMessages.map(\.id) == ["t3"])
        #expect(groups[0].bodyMessages.first?.text == "first run\n\nsame run")
        #expect(groups[1].bodyMessages.first?.text == "second run\n\nalso second run")
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
            msg("a-act-2", kind: .agentActivity, secondsOffset: 4, activitySnapshot: PickyActivitySummary(bash: 1, todo: 1)),
            msg("a-text-2", kind: .agentText, secondsOffset: 5, text: "step two"),
            msg("a-act-3", kind: .agentActivity, secondsOffset: 6, activitySnapshot: PickyActivitySummary(edit: 2, bash: 1, subagent: 2))
        ]

        let groups = PickyTurnGrouper.groups(from: messages, sessionStatus: .completed)

        #expect(groups.count == 1)
        let body = groups[0].bodyMessages
        #expect(body.map(\.id) == ["a-think-1", "a-text-1", "a-text-2", "a-act-3"])
        #expect(body.last?.activitySnapshot == PickyActivitySummary(
            edit: 2,
            bash: 2,
            read: 1,
            todo: 1,
            subagent: 2
        ))
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


    // MARK: - Messenger body

    @Test func thinkingIsHiddenFromTheTranscriptBody() {
        let body = [
            msg("t1", kind: .agentThinking, secondsOffset: 1, text: "reasoning"),
            msg("a1", kind: .agentText, secondsOffset: 2, text: "answer"),
            msg("act", kind: .agentActivity, secondsOffset: 3),
        ]
        #expect(PickyTurnBodyPolicy.visibleBodyMessages(body).map(\.id) == ["a1", "act"])
    }

    @Test func presenceShowsHumanDescriptionsAndNeverRawCommands() {
        let bash = PickyToolActivity(toolCallId: "b", name: "bash", status: "running",
                                     argsPreview: #"{"command":"pnpm vitest run","title":"테스트 실행"}"#)
        let untitled = PickyToolActivity(toolCallId: "c", name: "bash", status: "running",
                                         argsPreview: #"{"command":"rm -rf build"}"#)
        let grep = PickyToolActivity(toolCallId: "g", name: "grep", status: "succeeded",
                                     argsPreview: #"{"pattern":"secret"}"#)

        let working = PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: bash, startedAt: nil)
        #expect(working?.phase == .working)
        #expect(working?.detail == "테스트 실행")
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: untitled, startedAt: nil)?.detail == nil)
        // A finished tool drops back to thinking.
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: grep, startedAt: nil)?.phase == .thinking)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: nil, startedAt: nil)?.phase == .thinking)
        // Agent finished responding; the session runs only for bash_async/subagent work
        // and can take a new message, so no presence line.
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: nil, startedAt: nil,
            isAgentResponding: false) == nil)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: false, isWaitingForInput: true, activeTool: bash, startedAt: nil)?.phase == .waitingForInput)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: false, isWaitingForInput: false, activeTool: bash, startedAt: nil) == nil)
    }

    /// File tools name the file they touch: the last path component with its
    /// extension, never the directory prefix. The full path stays in the tooltip.
    @Test func presenceNamesTheFileForReadEditAndWrite() {
        func presence(_ name: String, _ args: String) -> PickyConversationPresencePresentation? {
            PickyConversationPresencePresentation.make(
                isRunning: true, isWaitingForInput: false,
                activeTool: PickyToolActivity(toolCallId: name, name: name, status: "running", argsPreview: args),
                startedAt: nil)
        }
        let read = presence("read", #"{"path":"/Users/me/picky/Picky/HUD/PickyHUDView.swift","offset":10}"#)
        #expect(read?.phase == .readingFile)
        #expect(read?.detail == "PickyHUDView.swift")
        #expect(read?.detailHelp == "/Users/me/picky/Picky/HUD/PickyHUDView.swift")
        #expect(read?.title != "hud.presence.readingFile")

        let edit = presence("edit", #"{"path":"Picky/Sessions/PickySessionStore.swift","edits":[]}"#)
        #expect(edit?.phase == .editingFile)
        #expect(edit?.detail == "PickySessionStore.swift")
        #expect(presence("multiedit", #"{"file_path":"a/b/c.ts"}"#)?.detail == "c.ts")

        let write = presence("write", #"{"path":"~/notes/design-notes.md","content":"notes"}"#)
        #expect(write?.phase == .writingFile)
        #expect(write?.detail == "design-notes.md")

        // No usable file name: the phase still reads as a file step, title only.
        let directory = presence("write", #"{"path":"build/out/"}"#)
        #expect(directory?.phase == .writingFile)
        #expect(directory?.detail == nil)
        #expect(presence("read", #"{}"#)?.detail == nil)

        // Loading a skill manifest stays a skill step, not a file read.
        let skill = presence("read", #"{"path":"/Users/me/.pi/agent/skills/picky-ux-writing/SKILL.md"}"#)
        #expect(skill?.phase == .working)
        #expect(skill?.detail?.contains("picky-ux-writing") == true)
    }

    /// A file step holds the line through a short gap like any other step, so
    /// back-to-back reads do not flash "thinking" between them.
    @Test func fileStepHoldsThroughShortGapsBeforeThinking() {
        let read = PickyConversationPresencePresentation(phase: .readingFile, detail: "A.swift", startedAt: nil)
        let thinking = PickyConversationPresencePresentation(phase: .thinking, detail: nil, startedAt: nil)
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        var stabilizer = PickyConversationPresenceStabilizer()
        _ = stabilizer.update(target: read, now: t0)
        let wait = stabilizer.update(target: thinking, now: t0.addingTimeInterval(2))
        #expect(stabilizer.displayed == read)
        #expect(wait == PickyConversationPresenceStabilizer.workingGrace)
    }

    /// Reply text is its own phase so a long answer no longer reads as
    /// "thinking". Tool activity still wins, and the friendly wording is fixed
    /// for the turn so the line never rotates while it is on screen.
    @Test func presenceReadsAsWritingWhileTheReplyStreams() {
        let bash = PickyToolActivity(toolCallId: "b", name: "bash", status: "running",
                                     argsPreview: #"{"command":"ls","title":"목록 확인"}"#)
        let turnStart = Date(timeIntervalSince1970: 1_000_002)

        let writing = PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: nil, isWritingReply: true, startedAt: turnStart)
        #expect(writing?.phase == .writing)
        // The reply itself is already on screen, so the line carries no detail.
        #expect(writing?.detail == nil)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: true, isWaitingForInput: false, activeTool: bash, isWritingReply: true, startedAt: turnStart)?.phase == .working)
        #expect(PickyConversationPresencePresentation.make(
            isRunning: false, isWaitingForInput: true, activeTool: nil, isWritingReply: true, startedAt: turnStart)?.phase == .waitingForInput)

        let key = PickyConversationPresencePresentation.writingTitleKey(forTurnStartedAt: turnStart)
        #expect(PickyConversationPresencePresentation.writingTitleKeys.contains(key))
        #expect(PickyConversationPresencePresentation.writingTitleKey(forTurnStartedAt: turnStart.addingTimeInterval(0.4)) == key)
        #expect(writing?.title == L10n.t(key))
        // A missing catalog entry falls back to the raw key; the wording must be real copy.
        #expect(writing?.title != key)
        // Consecutive turns do not all read the same.
        let variants = (0..<PickyConversationPresencePresentation.writingTitleKeys.count).map {
            PickyConversationPresencePresentation.writingTitleKey(forTurnStartedAt: Date(timeIntervalSince1970: Double(1_000_000 + $0)))
        }
        #expect(Set(variants) == Set(PickyConversationPresencePresentation.writingTitleKeys))
    }

    /// Tools are short and the model's pauses between them are long, so the
    /// line keeps the last step for 5 seconds after it ends and reads
    /// "thinking" only when a pause runs longer than that.
    @Test func presenceKeepsTheLastStepUntilAPauseRunsPastFiveSeconds() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let working = PickyConversationPresencePresentation(phase: .working, detail: "테스트 실행", startedAt: nil)
        let next = PickyConversationPresencePresentation(phase: .working, detail: "빌드", startedAt: nil)
        let thinking = PickyConversationPresencePresentation(phase: .thinking, detail: nil, startedAt: nil)
        let waiting = PickyConversationPresencePresentation(phase: .waitingForInput, detail: nil, startedAt: nil)
        var stabilizer = PickyConversationPresenceStabilizer()

        #expect(stabilizer.update(target: working, now: t0) == nil)
        #expect(stabilizer.displayed == working)

        // The tool ends; its step stays up for 5 seconds from that moment.
        let hold = stabilizer.update(target: thinking, now: t0.addingTimeInterval(0.5))
        #expect(stabilizer.displayed == working)
        #expect(abs((hold ?? 0) - 5) < 0.001)
        #expect(stabilizer.update(target: thinking, now: t0.addingTimeInterval(5.4)) != nil)
        #expect(stabilizer.displayed == working)

        // A tool starting inside the hold only swaps the detail.
        #expect(stabilizer.update(target: next, now: t0.addingTimeInterval(5.45)) == nil)
        #expect(stabilizer.displayed == next)

        // A pause longer than 5 seconds switches back to "thinking".
        _ = stabilizer.update(target: thinking, now: t0.addingTimeInterval(7.0))
        #expect(stabilizer.displayed == next)
        #expect(stabilizer.update(target: thinking, now: t0.addingTimeInterval(12.01)) == nil)
        #expect(stabilizer.displayed == thinking)

        // Streaming reply text and tool-call arguments are steps too and hold
        // the line the same way.
        let writing = PickyConversationPresencePresentation(phase: .writing, detail: nil, startedAt: nil)
        #expect(stabilizer.update(target: writing, now: t0.addingTimeInterval(14)) == nil)
        #expect(stabilizer.update(target: thinking, now: t0.addingTimeInterval(14.5)) != nil)
        #expect(stabilizer.displayed == writing)
        #expect(stabilizer.update(target: thinking, now: t0.addingTimeInterval(19.6)) == nil)
        #expect(stabilizer.displayed == thinking)

        let preparing = PickyConversationPresencePresentation(phase: .preparing, detail: nil, startedAt: nil)
        #expect(preparing.title != "hud.presence.preparing")
        #expect(stabilizer.update(target: preparing, now: t0.addingTimeInterval(21.2)) == nil)
        #expect(stabilizer.update(target: thinking, now: t0.addingTimeInterval(21.7)) != nil)
        #expect(stabilizer.displayed == preparing)

        // Waiting for input is never delayed, even right after a change.
        #expect(stabilizer.update(target: waiting, now: t0.addingTimeInterval(21.8)) == nil)
        #expect(stabilizer.displayed == waiting)
    }

    /// A finished bash used to keep reading "working" and then gave way to
    /// "preparing". It now reads "done" (or "failed") with its title for five
    /// seconds after it ends, unless another tool starts first.
    @Test func finishedWorkStepReadsDoneForFiveSecondsAfterItEnds() {
        let t0 = Date(timeIntervalSince1970: 5_000)
        let ended = t0.addingTimeInterval(4)
        func bash(_ id: String, _ status: String, title: String, endedAt: Date? = nil) -> PickyToolActivity {
            PickyToolActivity(toolCallId: id, name: "bash", status: status,
                              argsPreview: #"{"command":"x","title":"\#(title)"}"#, endedAt: endedAt)
        }
        func live(active: PickyToolActivity?, last: PickyToolActivity?, preparing: Bool = false) -> PickyConversationPresencePresentation {
            PickyConversationPresencePresentation.make(
                isRunning: true, isWaitingForInput: false, activeTool: active, lastTool: last,
                isPreparingToolCall: preparing, startedAt: nil)!
        }
        let running = bash("b1", "running", title: "빈도 측정 재실행")
        let finished = bash("b1", "succeeded", title: "빈도 측정 재실행", endedAt: ended)
        var stabilizer = PickyConversationPresenceStabilizer()

        _ = stabilizer.update(target: live(active: running, last: running), now: t0)
        #expect(stabilizer.displayed?.phase == .working)

        // Thinking, then preparing the next call, both read as the finished step.
        _ = stabilizer.update(target: live(active: nil, last: finished), now: ended)
        #expect(stabilizer.displayed?.phase == .workCompleted)
        #expect(stabilizer.displayed?.title == L10n.t("hud.presence.workCompleted"))
        #expect(stabilizer.displayed?.title != "hud.presence.workCompleted")
        #expect(stabilizer.displayed?.detail == "빈도 측정 재실행")
        let wait = stabilizer.update(target: live(active: nil, last: finished, preparing: true), now: ended.addingTimeInterval(2))
        #expect(stabilizer.displayed?.phase == .workCompleted)
        #expect(abs((wait ?? 0) - 3) < 0.001)

        // Five seconds after the end, the live phase shows again.
        _ = stabilizer.update(target: live(active: nil, last: finished, preparing: true), now: ended.addingTimeInterval(5))
        #expect(stabilizer.displayed?.phase == .preparing)

        // A failed step reads "failed"; a new tool replaces it before the hold ends.
        let failedAt = ended.addingTimeInterval(10)
        let failed = bash("b2", "failed", title: "테스트 목록 확인", endedAt: failedAt)
        _ = stabilizer.update(target: live(active: nil, last: failed), now: failedAt)
        #expect(stabilizer.displayed?.phase == .workFailed)
        #expect(stabilizer.displayed?.title != "hud.presence.workFailed")
        let next = bash("b3", "running", title: "빌드")
        _ = stabilizer.update(target: live(active: next, last: next), now: failedAt.addingTimeInterval(2))
        #expect(stabilizer.displayed?.phase == .working)
        #expect(stabilizer.displayed?.detail == "빌드")

        // A step that ended long ago (HUD reopened later) is not shown as done.
        var reopened = PickyConversationPresenceStabilizer()
        _ = reopened.update(target: live(active: nil, last: finished), now: ended.addingTimeInterval(60))
        #expect(reopened.displayed?.phase == .thinking)

        // bash_async returns once its job launches, so it never reads as done.
        let launched = PickyToolActivity(toolCallId: "a", name: "bash_async", status: "succeeded",
                                         argsPreview: #"{"title":"빌드"}"#, endedAt: ended)
        #expect(live(active: nil, last: launched).finishedWork == nil)
    }

    /// Back-to-back short tools used to swap the line several times a second,
    /// which read as flicker. Every change now stays up for a minimum interval
    /// and the latest pending value shows once it ends.
    @Test func presenceHoldsEachChangeForAMinimumInterval() {
        let t0 = Date(timeIntervalSince1970: 2_000)
        let thinking = PickyConversationPresencePresentation(phase: .thinking, detail: nil, startedAt: nil)
        let read = PickyConversationPresencePresentation(phase: .working, detail: "파일 읽기", startedAt: nil)
        let preparing = PickyConversationPresencePresentation(phase: .preparing, detail: nil, startedAt: nil)
        let build = PickyConversationPresencePresentation(phase: .working, detail: "빌드", startedAt: nil)
        let waiting = PickyConversationPresencePresentation(phase: .waitingForInput, detail: nil, startedAt: nil)
        let minimum = PickyConversationPresenceStabilizer.minimumDisplayDuration
        var stabilizer = PickyConversationPresenceStabilizer()

        #expect(stabilizer.update(target: thinking, now: t0) == nil)

        // "thinking" -> step right after the line appeared waits out the interval.
        let wait = stabilizer.update(target: read, now: t0.addingTimeInterval(0.2))
        #expect(stabilizer.displayed == thinking)
        #expect(abs((wait ?? 0) - (minimum - 0.2)) < 0.001)

        // Rapid changes coalesce; only the latest shows when the interval ends.
        #expect(stabilizer.update(target: preparing, now: t0.addingTimeInterval(0.6)) != nil)
        #expect(stabilizer.update(target: build, now: t0.addingTimeInterval(1.0)) != nil)
        #expect(stabilizer.displayed == thinking)
        #expect(stabilizer.update(target: build, now: t0.addingTimeInterval(minimum)) == nil)
        #expect(stabilizer.displayed == build)

        // Step -> step and detail swaps are held too.
        let shown = t0.addingTimeInterval(minimum)
        #expect(stabilizer.update(target: preparing, now: shown.addingTimeInterval(0.3)) != nil)
        #expect(stabilizer.displayed == build)
        #expect(stabilizer.update(target: preparing, now: shown.addingTimeInterval(minimum)) == nil)
        #expect(stabilizer.displayed == preparing)

        // Leaving "waiting for input" applies at once: the user just answered.
        #expect(stabilizer.update(target: waiting, now: shown.addingTimeInterval(minimum + 0.1)) == nil)
        #expect(stabilizer.update(target: read, now: shown.addingTimeInterval(minimum + 0.2)) == nil)
        #expect(stabilizer.displayed == read)
    }

    /// Between Pi runs of one running turn (queued follow-up, compaction then
    /// continue) the live line drops to nil for a moment. Removing and re-adding
    /// the row shifted the transcript, so the last line stays through the gap.
    @Test func presenceLineSurvivesAShortGapWhileTheTurnKeepsRunning() {
        let t0 = Date(timeIntervalSince1970: 3_000)
        let writing = PickyConversationPresencePresentation(phase: .writing, detail: nil, startedAt: nil)
        let thinking = PickyConversationPresencePresentation(phase: .thinking, detail: nil, startedAt: nil)
        var hold = PickyPresenceGapHold()

        // Gap: the previous line keeps rendering, and comes back seamlessly.
        #expect(hold.update(previous: writing, live: nil, now: t0) == PickyPresenceGapHold.grace)
        #expect(hold.presented(live: nil) == writing)
        #expect(hold.update(previous: nil, live: thinking, now: t0.addingTimeInterval(0.8)) == nil)
        #expect(hold.presented(live: thinking) == thinking)

        // A gap that outlasts the grace (agent done, only background work left) ends the line.
        #expect(hold.update(previous: thinking, live: nil, now: t0.addingTimeInterval(10)) != nil)
        #expect(hold.update(previous: nil, live: nil, now: t0.addingTimeInterval(10 + PickyPresenceGapHold.grace)) == nil)
        #expect(hold.presented(live: nil) == nil)
    }

    @Test func dateDividerTitlesUseTodayYesterdayAndDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 12))!
        let today = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9))!
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 23))!
        let lastYear = calendar.date(from: DateComponents(year: 2025, month: 12, day: 31, hour: 9))!

        #expect(PickyConversationDateDividerPolicy.title(for: today, now: now, calendar: calendar) == L10n.t("hud.conversation.dateDivider.today"))
        #expect(PickyConversationDateDividerPolicy.title(for: yesterday, now: now, calendar: calendar) == L10n.t("hud.conversation.dateDivider.yesterday"))
        #expect(PickyConversationDateDividerPolicy.title(for: lastYear, now: now, calendar: calendar).contains("2025"))
        #expect(PickyConversationDateDividerPolicy.messageIDsStartingDay(
            [("a", yesterday), ("b", yesterday.addingTimeInterval(60)), ("c", today)], calendar: calendar
        ) == ["a", "c"])
    }
}

// Trivial placeholder for view-builder closures in pure-logic tests.
private struct EmptyMessageContent: View {
    var body: some View { Color.clear }
}

private final class DelayedTurnBoundaryModel: ObservableObject {
    @Published var group: PickyTurnGroup

    init(group: PickyTurnGroup) {
        self.group = group
    }
}

private struct DelayedTurnBoundaryHarness: View {
    @ObservedObject var model: DelayedTurnBoundaryModel
    let staleTool: PickyToolActivity

    var body: some View {
        PickyTurnCardView(
            group: model.group,
            presence: model.group.isCurrent ? PickyConversationPresencePresentation.make(
                isRunning: true,
                isWaitingForInput: false,
                activeTool: staleTool,
                startedAt: nil
            ) : nil,
            onOpenActiveToolHistory: {}
        ) { message in
            Text(message.text ?? "message")
                .font(PickyHUDTypography.body)
        }
    }
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
