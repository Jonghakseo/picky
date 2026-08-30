//
//  PickyFocusStackComposerPresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyFocusStackComposerPresentationTests {
    @Test func submitPresentationKeepsRoutingIntentVisibleWithTheMatchingSymbol() {
        let steer = PickyComposerSubmitPresentation(kind: .steer, bashMode: .none)
        let followUp = PickyComposerSubmitPresentation(kind: .followUp, bashMode: .none)
        let bashSteer = PickyComposerSubmitPresentation(kind: .steer, bashMode: .visible)

        #expect(steer.label == L10n.t("hud.composer.submit.steer"))
        #expect(steer.iconName == "arrow.up")
        #expect(followUp.label == L10n.t("hud.composer.submit.followUp"))
        #expect(followUp.iconName == "arrow.turn.down.right")
        #expect(followUp.accessibilityLabel == L10n.t("hud.composer.submit.followUp"))
        #expect(bashSteer.label == L10n.t("hud.composer.submit.steer"))
        #expect(bashSteer.iconName == "play.fill")
    }

    @Test func runtimePresentationUsesFullModelAndThinkingValues() {
        let presentation = PickyComposerRuntimePresentation(
            assistantRun: PickyAssistantRunMetadata(
                model: "anthropic/claude-opus-4-7",
                thinkingLevel: .xhigh
            )
        )

        #expect(presentation.hasControls)
        #expect(presentation.modelLabel == L10n.t("hud.conversation.meta.model", "anthropic/claude-opus-4-7"))
        #expect(presentation.thinkingLabel == L10n.t("hud.conversation.meta.thinking", "xhigh"))
        #expect(!PickyComposerRuntimePresentation(assistantRun: nil).hasControls)
    }

    @Test func editorHeightReservesTwoLinesThenGrowsThroughFourLinesAndCaps() {
        #expect(PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: 0) == 48)
        #expect(PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: 23.5) == 48)
        #expect(PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: 42.2) == 48)
        #expect(PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: 76) == 76)
        #expect(PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: 120) == 78)
        #expect(PickyComposerEditorHeightPolicy.height(for: "one") == 48)
        #expect(PickyComposerEditorHeightPolicy.height(for: "one\ntwo") == 48)
        #expect(PickyComposerEditorHeightPolicy.height(for: "one\ntwo\nthree\nfour") == 76)
        #expect(PickyComposerEditorHeightPolicy.height(for: "one\ntwo\nthree\nfour\nfive") == 78)
    }

    @Test func editorGrowthExpandsTheCardTransientlyWithinTheScreenCap() {
        #expect(PickyComposerEditorHeightPolicy.transientGrowth(forEditorHeight: 48) == 0)
        #expect(PickyComposerEditorHeightPolicy.transientGrowth(forEditorHeight: 78) == 30)
        #expect(PickyConversationCardHeightPolicy.resolvedHeight(
            fixedHeight: 320,
            maxHeight: 900,
            transientGrowth: 30
        ) == 350)
        #expect(PickyConversationCardHeightPolicy.resolvedHeight(
            fixedHeight: 320,
            maxHeight: 350,
            transientGrowth: 30
        ) == 350)
        #expect(PickyConversationCardHeightPolicy.resolvedHeight(
            fixedHeight: 480,
            maxHeight: 900,
            transientGrowth: -20
        ) == 480)
    }

    @Test func queueDockShowsBothKindsWithTheirIndependentModes() {
        let presentation = PickyQueueDockPresentation(
            visibleQueue: PickyVisibleQueue(
                queuedSteers: [queueItem("steer once")],
                queuedFollowUps: [queueItem("follow one"), queueItem("follow two")],
                committedUserMessages: []
            ),
            steeringMode: .oneAtATime,
            followUpMode: .all
        )

        #expect(presentation.isVisible)
        #expect(presentation.kinds.map(\.kind) == [.steer, .followUp])
        #expect(presentation.kinds.map(\.count) == [1, 2])
        #expect(presentation.kinds.map(\.mode) == [.oneAtATime, .all])
        #expect(presentation.accessibilityValue.contains(L10n.t("hud.queue.mode.individual")))
        #expect(presentation.accessibilityValue.contains(L10n.t("hud.queue.mode.all")))
        #expect(!PickyQueueDockPresentation(
            visibleQueue: PickyVisibleQueue(
                queuedSteers: [],
                queuedFollowUps: [],
                committedUserMessages: []
            ),
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime
        ).isVisible)
    }

    @Test func queueDockRoutesRestoreAndClearAsDistinctCommands() {
        #expect(PickyQueueDockAction.restore.command == .restoreThenClear(.all))
        #expect(PickyQueueDockAction.clear.command == .clearOnly(.all))
        #expect(PickyQueueDockAction.restore.inFlightLabel == L10n.t("hud.queue.restoring"))
        #expect(PickyQueueDockAction.clear.inFlightLabel == L10n.t("hud.queue.clearing"))
    }

    @Test func visibleQueueExcludesCommittedItemsFromBothDockAndDraftRestore() {
        let queuedAt = Date(timeIntervalSince1970: 1_000)
        let staleSteer = PickyQueueItem(text: "committed steer", enqueuedAt: queuedAt)
        let freshFollowUp = PickyQueueItem(text: "fresh follow-up", enqueuedAt: queuedAt.addingTimeInterval(1))
        let visibleQueue = PickyVisibleQueue(
            queuedSteers: [staleSteer],
            queuedFollowUps: [freshFollowUp],
            committedUserMessages: [PickySubmittedUserMessage(text: "committed steer", createdAt: queuedAt)]
        )

        let dock = PickyQueueDockPresentation(
            visibleQueue: visibleQueue,
            steeringMode: .all,
            followUpMode: .oneAtATime
        )

        #expect(dock.kinds.map(\.kind) == [.followUp])
        #expect(PickyQueuedInputDraftPolicy.draftRestoringQueuedInputs(
            draft: "existing",
            visibleQueue: visibleQueue
        ) == "existing\n\nfresh follow-up")
        #expect(PickyVisibleQueue(
            queuedSteers: [staleSteer],
            queuedFollowUps: [],
            committedUserMessages: [PickySubmittedUserMessage(
                text: "committed steer",
                createdAt: queuedAt.addingTimeInterval(301)
            )]
        ).steers == [staleSteer])
    }

    @Test func visibleQueueNormalizesEnvelopesAndKeepsBothKindsChronological() {
        let followUpEnvelope = """
        # Picky follow-up

        ## User follow-up
        - Source: text-follow-up

        follow-up first

        ## Captured context
        - hidden
        """
        let steerEnvelope = """
        # Picky steering message

        ## User steering instruction
        - Source: text-follow-up

        steer second

        ## Captured context
        - hidden
        """
        let origin = Date(timeIntervalSince1970: 1_000)
        let visibleQueue = PickyVisibleQueue(
            queuedSteers: [PickyQueueItem(text: steerEnvelope, enqueuedAt: origin.addingTimeInterval(2))],
            queuedFollowUps: [PickyQueueItem(text: followUpEnvelope, enqueuedAt: origin.addingTimeInterval(1))],
            committedUserMessages: []
        )

        #expect(PickyQueuedInputDraftPolicy.queuedInputText(visibleQueue: visibleQueue) == "follow-up first\n\nsteer second")
        #expect(PickyQueuedInputDraftPolicy.queuedInputText(visibleQueue: visibleQueue, kind: .steering) == "steer second")
        #expect(PickyQueuedInputDraftPolicy.queuedInputText(visibleQueue: visibleQueue, kind: .followUp) == "follow-up first")
    }

    @Test func queueEvidenceUsesNeutralToneAndDockStacksAtCompactWidth() {
        #expect(PickyPendingQueueKind.steer.evidenceTone == .neutral)
        #expect(PickyPendingQueueKind.followUp.evidenceTone == .neutral)
        #expect(PickyQueueDockLayout(cardWidth: 399) == .stacked)
        #expect(PickyQueueDockLayout(cardWidth: 400) == .inline)
        #expect(PickyQueueDockLayout(cardWidth: 560, heightTier: .constrained) == .constrained)
    }

    @Test func inlineTUIContinuitySummarizesCurrentStatusToolTodoAndElapsed() {
        let now = Date(timeIntervalSince1970: 1_000)
        let session = PickySessionCard(session: PickyAgentSession(
            id: "session-1",
            title: "Build Focus Stack",
            status: .running,
            createdAt: now.addingTimeInterval(-120),
            updatedAt: now,
            logs: [],
            tools: [PickyToolActivity(
                toolCallId: "tool-1",
                name: "bash",
                status: "running",
                startedAt: now.addingTimeInterval(-65)
            )],
            todoState: PickyTodoState(
                tasks: [
                    PickyTodoTask(id: "done", content: "Inspect", status: .completed),
                    PickyTodoTask(id: "active", content: "Implement", status: .inProgress),
                ],
                updatedAt: now.addingTimeInterval(-65)
            ),
            artifacts: [],
            changedFiles: []
        ))

        let presentation = PickyInlineTerminalContinuityPresentation(session: session, now: now)

        #expect(presentation.statusText == PickyConversationStatusPresentation(status: .running).label)
        #expect(presentation.toolText == "bash")
        #expect(presentation.todoText == "2/2")
        #expect(presentation.elapsedText == L10n.t("hud.conversation.duration.minutes", Int64(1)))
        #expect(presentation.accessibilityValue.contains("bash"))
    }

    private func queueItem(_ text: String) -> PickyQueueItem {
        PickyQueueItem(text: text, enqueuedAt: Date(timeIntervalSince1970: 0))
    }
}
