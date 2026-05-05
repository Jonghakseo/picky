//
//  PickyConversationCardViewTests.swift
//  PickyTests
//

import Foundation
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

    func send(_ command: PickyCommandEnvelope) async throws {
        sentCommands.append(command)
    }

    func disconnect() { continuation.yield(.disconnected) }
}

@Suite(.serialized)
@MainActor
struct PickyConversationCardViewTests {
    @Test func runningPhaseRendersTypingBubbleQueueAndActivityStrip() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("m-user", kind: .userText, text: "please build"),
                message("m-activity", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 3, bash: 5, thinking: 8, other: 1)),
                message("m-agent", kind: .agentText, text: "working"),
                message("m-thinking", kind: .agentThinking, text: "Thinking…")
            ],
            queuedSteers: [queueItem("steer once")],
            queuedFollowUps: [queueItem("follow up one"), queueItem("follow up two")],
            steeringMode: .oneAtATime,
            followUpMode: .all,
            activitySummary: PickyActivitySummary(edit: 3, bash: 5, thinking: 8, other: 1)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.typingBubbleCount == 1)
        #expect(snapshot.batchGroupCount == 1)
        #expect(snapshot.pendingBubbleCount == 1)
        #expect(snapshot.activitySummaryCount == 1)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func donePhaseRendersFinalReportBubble() {
        let report = PickyFinalReport(summary: "Done", body: "All tasks complete", status: .success)
        let session = makeConversationSession(
            status: .completed,
            messages: [
                message("m-user", kind: .userText, text: "finish it"),
                message("m-report", kind: .agentReport, text: "done", report: report)
            ],
            activitySummary: .zero,
            finalReport: report
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let header = PickyConversationHeaderView(viewModel: viewModel, session: session)

        #expect(snapshot.finalReportBubbleCount == 1)
        #expect(header.statusColorName == "green")
        #expect(!snapshot.showsActivitySummary)
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
        let terminalWithFinalReport = makeConversationSession(
            status: .failed,
            finalReport: PickyFinalReport(summary: "Partial", body: "Report body", status: .partial)
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

        let finalReportMenu = PickyConversationMenu(session: terminalWithFinalReport, viewModel: viewModel)
        #expect(finalReportMenu.canOpenReport)
        #expect(!finalReportMenu.canStop)
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

        #expect(snapshot.activitySummaryCount == 1, "agent_activity message itself is counted")
        #expect(!snapshot.showsActivitySummary, "zero-count snapshot should not surface in UI")
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
}

private let baseDate = Date(timeIntervalSince1970: 1_777_777_777)

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
    finalReport: PickyFinalReport? = nil,
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
            finalReport: finalReport,
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
    report: PickyFinalReport? = nil,
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
        report: report,
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
