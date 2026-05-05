//
//  PickyConversationCardViewTests.swift
//  PickyTests
//

import Foundation
import SwiftUI
import Testing
@testable import Picky

private final class ConversationCardFakeClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submitted: [PickyAgentSubmission] = []
    private(set) var sentCommands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        submitted.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "session-1", message: "sent")
    }

    var sendError: Error?

    func send(_ command: PickyCommandEnvelope) async throws {
        if let sendError { throw sendError }
        sentCommands.append(command)
    }

    func emit(_ event: PickyClientEvent) { continuation.yield(event) }

    func disconnect() { continuation.yield(.disconnected) }
}

private final class ConversationCardSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
}

@Suite(.serialized)
@MainActor
struct PickyConversationCardViewTests {
    @Test func runningPhaseRendersTypingBubbleQueueAndActivityStrip() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("m-user", kind: .userText, text: "please build"),
                message("m-activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 3, bash: 5, thinking: 8, other: 1, read: 2, write: 1)),
                message("m-agent", kind: .agentText, text: "working"),
                message("m-thinking", kind: .agentThinking, text: "Thinking…")
            ],
            queuedSteers: [queueItem("steer once")],
            queuedFollowUps: [queueItem("follow up one"), queueItem("follow up two")],
            steeringMode: .oneAtATime,
            followUpMode: .all,
            activitySummary: PickyActivitySummary(edit: 3, bash: 5, thinking: 8, other: 1, read: 2, write: 1)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.typingBubbleCount == 1)
        #expect(snapshot.batchGroupCount == 1)
        #expect(snapshot.pendingBubbleCount == 1)
        #expect(snapshot.activitySummaryCount == 1)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func queuedFollowUpMatchingUserTextDoesNotRenderPendingBubble() {
        let legacyFollowUpPrompt = """
        # Picky follow-up

        ## User follow-up
        아니다 10초

        ## Context
        Keep this internal context hidden.
        """
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "아니다 10초")],
            queuedFollowUps: [queueItem(legacyFollowUpPrompt)]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.pendingBubbleCount == 0)
        #expect(snapshot.batchGroupCount == 0)
    }

    @Test func queuedSteerMatchingUserTextDoesNotRenderPendingBubble() {
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "stop and use 10 seconds")],
            queuedSteers: [queueItem("stop and use 10 seconds")]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.pendingBubbleCount == 0)
        #expect(snapshot.batchGroupCount == 0)
    }

    @Test func queuedItemWithoutMatchingUserTextStillRendersPendingBubble() {
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "first request")],
            queuedSteers: [queueItem("different queued steer")]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.pendingBubbleCount == 1)
        #expect(snapshot.batchGroupCount == 0)
    }

    @Test func waitingPhaseRendersQuestionBubble() {
        let request = extensionUiRequest()
        let session = makeConversationSession(
            status: .waiting_for_input,
            messages: [
                message("m-user", kind: .userText, text: "decide"),
                message("m-question", kind: .agentQuestion, text: "Need input", question: request)
            ],
            pendingExtensionUiRequest: request
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let header = PickyConversationHeaderView(viewModel: viewModel, session: session)
        let composer = PickyConversationComposerView(session: session, viewModel: viewModel)

        #expect(snapshot.questionBubbleCount == 1)
        #expect(header.statusColorName == "amber")
        #expect(composer.placeholderText.contains("Steer this agent"))
        #expect(composer.placeholderText.contains("esc Stop"))
    }

    @Test func failedPhaseRendersErrorBubbleWithoutRetryChip() {
        let errorMessage = message(
            "m-error",
            kind: .agentError,
            text: "Command failed",
            errorContext: "while running build",
            errorMessage: "exit code 65"
        )
        let session = makeConversationSession(status: .failed, messages: [message("m-user", kind: .userText, text: "test"), errorMessage])
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let header = PickyConversationHeaderView(viewModel: viewModel, session: session)
        let errorBubble = PickyErrorBubbleView(message: errorMessage)

        #expect(snapshot.errorBubbleCount == 1)
        #expect(!errorBubble.recoveryChipLabels.contains("↻ 다시 시도"))
        #expect(errorBubble.recoveryChipLabels == ["⌨ Terminal 열기", "📄 전체 로그"])
        #expect(header.statusColorName == "red")
    }

    @Test func composerReturnKeyMappingKeepsShiftReturnForNewlines() {
        #expect(PickyConversationComposerView.returnKeyAction(for: []) == .submitDefault)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.option]) == .submitOptionReturn)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.shift]) == .insertNewline)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.shift, .option]) == .insertNewline)
    }

    @Test func composerUpArrowMappingClearsQueueWithOptionModifier() {
        #expect(PickyConversationComposerView.upArrowKeyAction(for: []) == .navigateAutocomplete)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.shift]) == .navigateAutocomplete)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.option]) == .clearQueue)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.option, .shift]) == .clearQueue)
    }

    @Test func composerEditorHeightStartsCompactAndCapsGrowth() {
        #expect(PickyConversationComposerView.editorHeight(for: "") == 20)
        #expect(PickyConversationComposerView.editorHeight(for: "one line") == 20)
        #expect(PickyConversationComposerView.editorHeight(for: "one\ntwo") == 36)
        #expect(PickyConversationComposerView.editorHeight(for: "one\ntwo\nthree\nfour") == 48)
    }

    @Test func composerDefaultSubmitKindAndPlaceholderMatchSessionStatus() {
        let viewModel = makeViewModel()

        for status in [PickySessionStatus.running, .queued, .waiting_for_input] {
            let composer = PickyConversationComposerView(session: makeConversationSession(status: status), viewModel: viewModel)
            #expect(composer.defaultSubmitKind == .steer)
            #expect(composer.optionReturnSubmitKind == .followUp)
            #expect(composer.placeholderText.contains("Steer this agent"))
            #expect(composer.placeholderText.contains("⌥↵ Follow-up"))
        }

        for status in [PickySessionStatus.completed, .blocked] {
            let composer = PickyConversationComposerView(session: makeConversationSession(status: status), viewModel: viewModel)
            #expect(composer.defaultSubmitKind == .followUp)
            #expect(composer.optionReturnSubmitKind == .followUp)
            #expect(composer.placeholderText.contains("Send a follow-up"))
        }

        let cancelledComposer = PickyConversationComposerView(session: makeConversationSession(status: .cancelled), viewModel: viewModel)
        #expect(cancelledComposer.defaultSubmitKind == .steer)
        #expect(cancelledComposer.optionReturnSubmitKind == nil)
        #expect(cancelledComposer.placeholderText.contains("Resume this agent with a steer"))
        #expect(!cancelledComposer.placeholderText.contains("follow-up"))

        let failedComposer = PickyConversationComposerView(session: makeConversationSession(status: .failed), viewModel: viewModel)
        #expect(failedComposer.defaultSubmitKind == nil)
        #expect(failedComposer.optionReturnSubmitKind == nil)
        #expect(failedComposer.placeholderText.contains("Open terminal/logs"))
        #expect(!failedComposer.placeholderText.contains("Follow-up"))
    }

    @Test func composerSubmitFailureUpdatesLastError() async throws {
        struct SendFailure: LocalizedError {
            var errorDescription: String? { "command failed" }
        }
        let client = ConversationCardFakeClient()
        client.sendError = SendFailure()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        await #expect(throws: SendFailure.self) {
            try await viewModel.steer(text: "test", sessionID: "x")
        }

        #expect(viewModel.lastError == "command failed")
        #expect(client.sentCommands.isEmpty)
    }

    @Test func composerSubmitSteerSendsSteerEnvelope() async throws {
        let client = ConversationCardFakeClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.steer(text: "test", sessionID: "x")

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .steer)
        #expect(command.text == "test")
        #expect(command.sessionId == "x")
    }

    @Test func composerSubmitFollowUpSendsFollowUpEnvelope() async throws {
        let client = ConversationCardFakeClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.followUp(text: "test", sessionID: "x")

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .followUp)
        #expect(command.text == "test")
        #expect(command.sessionId == "x")
    }

    @Test func composerEscOnEmptyAbortsAbortableSession() async throws {
        let client = ConversationCardFakeClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())

        try await viewModel.abort(sessionID: "running-session")

        let command = try #require(client.sentCommands.last)
        #expect(command.type == .abort)
        #expect(command.sessionId == "running-session")
    }

    @Test func menuEnablementMatchesSessionStatus() {
        let viewModel = makeViewModel()
        let activeWithPiSession = makeConversationSession(status: .running, logs: ["pi session: /tmp/picky.pi-session"])
        let terminalWithoutPiSession = makeConversationSession(status: .completed)
        let terminalWithReportArtifact = makeConversationSession(
            status: .completed,
            artifacts: [PickyArtifact(id: "a-report", kind: "report", title: "Report", path: "/tmp/report.md", url: nil, updatedAt: baseDate)]
        )
        let activeMenu = PickyConversationMenu(session: activeWithPiSession, viewModel: viewModel)
        #expect(activeMenu.canOpenPiTerminal)
        #expect(activeMenu.canCopyResumeCommand)
        #expect(!activeMenu.canOpenReport)
        #expect(activeMenu.canStop)

        let noPiMenu = PickyConversationMenu(session: terminalWithoutPiSession, viewModel: viewModel)
        #expect(!noPiMenu.canOpenPiTerminal)
        #expect(!noPiMenu.canCopyResumeCommand)
        #expect(!noPiMenu.canOpenReport)
        #expect(!noPiMenu.canStop)

        let reportArtifactMenu = PickyConversationMenu(session: terminalWithReportArtifact, viewModel: viewModel)
        #expect(reportArtifactMenu.canOpenReport)

    }

    @Test func cardHoverSeedsVoiceFollowUpTargetForPushToTalk() async throws {
        let client = ConversationCardFakeClient()
        let selection = ConversationCardSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()
        defer { viewModel.stop() }

        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "side-voice", status: "running"))))
        try await settle()

        let session = try #require(viewModel.sessions.first(where: { $0.id == "side-voice" }))
        let card = PickyConversationCardView(viewModel: viewModel, session: session)

        card.updateVoiceFollowUpHover(true)
        #expect(viewModel.hoveredVoiceFollowUpSessionID == "side-voice")
        #expect(selection.hoveredVoiceFollowUpSessionID == "side-voice")

        card.updateVoiceFollowUpHover(false)
        #expect(viewModel.hoveredVoiceFollowUpSessionID == nil)
        #expect(selection.hoveredVoiceFollowUpSessionID == nil)
    }

    @Test func userBubbleShowsByMainAgentLabelWhenOriginated() {
        let bubble = PickyUserBubbleView(message: message("m-main", kind: .userText, text: "delegated", originatedBy: .mainAgent))

        #expect(bubble.displayedOriginLabel == "by main agent")
    }

    @Test func userBubbleShowsByPiTerminalLabelWhenPiExtensionOriginated() {
        let bubble = PickyUserBubbleView(message: message("m-pi", kind: .userText, text: "from extension", originatedBy: .piExtension))

        #expect(bubble.displayedOriginLabel == "by Pi terminal")
    }

    // MARK: - PR11 regression: per-turn agent_activity snapshot

    @Test func multipleTurnsRenderSeparateActivitySnapshots() {
        let snap1 = PickyActivitySummary(edit: 1, bash: 0, thinking: 2, other: 0)
        let snap2 = PickyActivitySummary(edit: 0, bash: 3, thinking: 1, other: 0)
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first task"),
                message("a1-act", kind: .agentActivity, activitySnapshot: snap1),
                message("a1", kind: .agentText, text: "first reply"),
                message("u2", kind: .userText, text: "second task"),
                message("a2-act", kind: .agentActivity, activitySnapshot: snap2),
                message("a2", kind: .agentText, text: "second reply")
            ],
            activitySummary: PickyActivitySummary(edit: 1, bash: 3, thinking: 3, other: 0)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 2)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func zeroCountActivitySnapshotIsHidden() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "hello"),
                message("a-act", kind: .agentActivity, activitySnapshot: .zero),
                message("a", kind: .agentText, text: "hi")
            ]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0, "zero-count snapshot should not render a visible activity strip")
        #expect(!snapshot.showsActivitySummary, "zero-count snapshot should not surface in UI")
    }

    @Test func activitySummaryShowsOnlyCalledReadBashEditWriteTools() {
        let items = PickyActivitySummary(edit: 3, bash: 0, thinking: 4, other: 5, read: 2, write: 0).visibleToolCallItems

        #expect(items.map(\.id) == ["read", "edit"])
        #expect(items.map(\.count) == [2, 3])
    }

    @Test func activitySnapshotWithOnlyThinkingAndOtherIsHidden() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "hello"),
                message("a-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(thinking: 2, other: 1)),
                message("a", kind: .agentText, text: "hi")
            ]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0)
        #expect(!snapshot.showsActivitySummary)
    }

    // MARK: - Last turn-only visibility (Earlier history)

    @Test func visibleMessagesContainsOnlyLastUserTextOnward() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "reply 1"),
                message("u2", kind: .userText, text: "second"),
                message("a2-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 0, bash: 1, thinking: 0, other: 0)),
                message("a2", kind: .agentText, text: "reply 2")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.visibleMessages.map(\.id) == ["u2", "a2-act", "a2"])
        #expect(list.hiddenHistoryCount == 2)
    }

    @Test func visibleMessagesShowsAllWhenNoUserTextExists() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("a1", kind: .agentText, text: "hello"),
                message("a2", kind: .agentThinking, text: "thinking")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.visibleMessages.count == 2)
        #expect(list.hiddenHistoryCount == 0)
    }

    @Test func hiddenHistoryCountIsZeroWhenOnlyOneTurnExists() {
        let session = makeConversationSession(
            status: .completed,
            messages: [
                message("u", kind: .userText, text: "one"),
                message("a", kind: .agentText, text: "done")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.hiddenHistoryCount == 0)
        #expect(list.visibleMessages.count == 2)
    }

    @Test func activityStripIsNotAutoInsertedWhenNoAgentActivityMessage() {
        // Regression: the legacy auto-insert (after first user_text) was removed in PR11.
        // Without an explicit agent_activity message, no strip should be shown — even if
        // the lifetime activitySummary on the session is non-zero.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "hello"),
                message("a", kind: .agentText, text: "hi")
            ],
            activitySummary: PickyActivitySummary(edit: 5, bash: 5, thinking: 5, other: 5)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0)
        #expect(!snapshot.showsActivitySummary)
    }

    @Test func latestAgentResponseShowsOpenAsReportAction() {
        let session = makeConversationSession(
            status: .completed,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "older response"),
                message("u2", kind: .userText, text: "latest"),
                message("a2", kind: .agentText, text: "latest response")
            ]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(session.canOpenMarkdownReport)
        #expect(session.latestOpenAsReportMessage?.id == "a2")
        #expect(snapshot.openAsReportActionCount == 1)
    }
}

private let baseDate = Date(timeIntervalSince1970: 1_777_777_777)

private func settle() async throws {
    try await Task.sleep(nanoseconds: 20_000_000)
}

private func sessionUpdatedJSON(id: String = "session-1", status: String = "running") -> String {
    """
    {"id":"evt-\(id)","protocolVersion":"2026-05-05","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"\(id)","title":"Test session","status":"\(status)","cwd":"/tmp/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"summary","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
    """
}

private extension PickyEventEnvelope {
    static func fixture(eventJSON: String) -> PickyEventEnvelope {
        try! JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: Data(eventJSON.utf8))
    }
}

@MainActor
private func makeViewModel() -> PickySessionListViewModel {
    PickySessionListViewModel(client: ConversationCardFakeClient(), notificationCenter: PickyNoopNotificationCenter())
}

private func makeConversationSession(
    id: String = "session-1",
    status: PickySessionStatus,
    messages: [PickySessionMessage] = [],
    queuedSteers: [PickyQueueItem] = [],
    queuedFollowUps: [PickyQueueItem] = [],
    steeringMode: PickyQueueMode = .oneAtATime,
    followUpMode: PickyQueueMode = .oneAtATime,
    activitySummary: PickyActivitySummary = .zero,
    pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
    artifacts: [PickyArtifact] = [],
    logs: [String] = []
) -> PickySessionListViewModel.SessionCard {
    PickySessionListViewModel.SessionCard.fromAgentSession(
        PickyAgentSession(
            id: id,
            title: "Test session",
            status: status,
            cwd: "/tmp/picky",
            createdAt: baseDate,
            updatedAt: baseDate,
            lastSummary: "summary",
            logs: logs,
            tools: [],
            artifacts: artifacts,
            changedFiles: [],
            messages: messages,
            queuedSteers: queuedSteers,
            queuedFollowUps: queuedFollowUps,
            steeringMode: steeringMode,
            followUpMode: followUpMode,
            activitySummary: activitySummary,
            pendingExtensionUiRequest: pendingExtensionUiRequest
        )
    )
}

private func message(
    _ id: String,
    kind: PickySessionMessageKind,
    text: String? = nil,
    originatedBy: PickyMessageOrigin? = nil,
    question: PickyExtensionUiRequest? = nil,
    activitySnapshot: PickyActivitySummary? = nil,
    errorContext: String? = nil,
    errorMessage: String? = nil
) -> PickySessionMessage {
    PickySessionMessage(
        id: id,
        kind: kind,
        createdAt: baseDate,
        originatedBy: originatedBy,
        text: text,
        question: question,
        cancelledAt: nil,
        activitySnapshot: activitySnapshot,
        errorContext: errorContext,
        errorMessage: errorMessage
    )
}

private func queueItem(_ text: String) -> PickyQueueItem {
    PickyQueueItem(text: text, enqueuedAt: baseDate)
}

private func extensionUiRequest() -> PickyExtensionUiRequest {
    PickyExtensionUiRequest(
        id: "request-1",
        sessionId: "session-1",
        method: "askUserQuestion",
        title: "Need a decision",
        prompt: "Pick one",
        description: nil,
        options: nil,
        questions: [
            PickyExtensionUiQuestion(
                id: "choice",
                type: .radio,
                prompt: "Choose",
                label: "Choice",
                options: [PickyExtensionUiQuestionOption(value: "a", label: "A")],
                allowOther: false,
                required: true,
                placeholder: nil,
                defaultValue: nil
            )
        ],
        createdAt: baseDate
    )
}
