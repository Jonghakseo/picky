//
//  PickyConversationCardViewTests.swift
//  PickyTests
//

import Foundation
import SwiftUI
import Testing
import UniformTypeIdentifiers
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

    @Test func activityStripShowsEtcWhenOnlyOtherToolsRan() {
        let summary = PickyActivitySummary(other: 2)
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("m-user", kind: .userText, text: "open shell"),
                message("m-activity", kind: .agentActivity, activitySnapshot: summary)
            ],
            activitySummary: summary
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let visibleItems = summary.visibleToolCallItems

        #expect(visibleItems.map(\.id) == ["other"])
        #expect(visibleItems.first?.label == "etc")
        #expect(snapshot.activitySummaryCount == 1)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func assistantRunMetadataUsesCompactDimFooterText() {
        #expect(PickyAssistantRunMetadata(model: "openai-codex/gpt-5.5", thinkingLevel: .high).displayText == "gpt-5.5 high")
        #expect(PickyAssistantRunMetadata(model: "anthropic/claude-opus-4-7", thinkingLevel: .xhigh).displayText == "opus-4-7 xhigh")
    }

    @Test func contextUsageNoLongerRendersInsideAssistantBubble() {
        let session = makeConversationSession(
            status: .completed,
            messages: [
                message("m-user", kind: .userText, text: "answer without tools"),
                message(
                    "m-agent",
                    kind: .agentText,
                    text: "done",
                    assistantRun: PickyAssistantRunMetadata(model: "anthropic/claude-opus-4-7", thinkingLevel: .xhigh)
                )
            ],
            activitySummary: .zero,
            contextUsage: PickyContextUsage(tokens: 9_000, contextWindow: 10_000, percent: 90)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0)
        #expect(snapshot.contextUsageFooterCount == 0)
    }

    @Test func agentResponsePreviewTruncatesAfterEightLinesOrFiveHundredCharacters() {
        let exactCharacters = String(repeating: "가", count: 500)
        let longCharacters = exactCharacters + "나다라"
        let characterTruncated = PickyAgentResponsePreview.truncatedMarkdown(longCharacters)
        let eightLines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let nineLines = eightLines + "\nline 9"

        #expect(PickyAgentResponsePreview.truncatedMarkdown(exactCharacters) == exactCharacters)
        #expect(characterTruncated == exactCharacters + "...")
        #expect(characterTruncated.count == 503)
        #expect(PickyAgentResponsePreview.truncatedMarkdown(eightLines) == eightLines)
        #expect(PickyAgentResponsePreview.truncatedMarkdown(nineLines) == eightLines + "...")
    }

    @Test func agentResponsePreviewIsTruncatedMatchesTruncatedMarkdown() {
        // The hover icon's gate uses isTruncated to decide whether to expose an
        // expand affordance. Verify it stays in lockstep with the truncation
        // performed by truncatedMarkdown so the icon never appears for messages
        // that are already shown in full.
        let shortText = "hi"
        let exactCharacters = String(repeating: "가", count: 500)
        let longCharacters = exactCharacters + "나다라"
        let eightLines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let nineLines = eightLines + "\nline 9"

        #expect(!PickyAgentResponsePreview.isTruncated(""))
        #expect(!PickyAgentResponsePreview.isTruncated(shortText))
        #expect(!PickyAgentResponsePreview.isTruncated(exactCharacters))
        #expect(PickyAgentResponsePreview.isTruncated(longCharacters))
        #expect(!PickyAgentResponsePreview.isTruncated(eightLines))
        #expect(PickyAgentResponsePreview.isTruncated(nineLines))
    }

    @Test func finderOpenRequestOnlyResolvesExistingCwdDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let fileURL = root.appendingPathComponent("not-a-directory.txt")
        try "file".write(to: fileURL, atomically: true, encoding: .utf8)

        #expect(PickyFinderOpenRequest.existingDirectoryURL(cwd: "  \(root.path)  ")?.standardizedFileURL == root.standardizedFileURL)
        #expect(PickyFinderOpenRequest.existingDirectoryURL(cwd: fileURL.path) == nil)
        #expect(PickyFinderOpenRequest.existingDirectoryURL(cwd: root.appendingPathComponent("missing").path) == nil)
        #expect(PickyFinderOpenRequest.existingDirectoryURL(cwd: " ") == nil)
    }

    @Test func questionBubbleBodyTextDoesNotDuplicateTitle() {
        let titledOnly = extensionUiRequest(title: "짧은 테스트", prompt: nil)
        let samePrompt = extensionUiRequest(title: "짧은 테스트", prompt: " 짧은 테스트 ")
        let distinctPrompt = extensionUiRequest(title: "짧은 테스트", prompt: "잘 뜨나요?")
        let untitled = extensionUiRequest(title: nil, prompt: nil)

        #expect(PickyQuestionBubbleCopy.bodyText(for: titledOnly) == nil)
        #expect(PickyQuestionBubbleCopy.bodyText(for: samePrompt) == nil)
        #expect(PickyQuestionBubbleCopy.bodyText(for: distinctPrompt) == "잘 뜨나요?")
        #expect(PickyQuestionBubbleCopy.bodyText(for: untitled) == "askUserQuestion")
    }

    @Test func queuedFollowUpMatchingUserTextStillRendersPendingBubble() {
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

        #expect(snapshot.pendingBubbleCount == 1)
        #expect(snapshot.batchGroupCount == 0)
    }

    @Test func queuedSteerMatchingUserTextStillRendersPendingBubble() {
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "stop and use 10 seconds")],
            queuedSteers: [queueItem("stop and use 10 seconds")]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.pendingBubbleCount == 1)
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

    @Test func compactingPhaseShowsOverlayAndBlocksComposer() {
        let session = makeConversationSession(status: .running, lastSummary: "Compacting after context overflow…")
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let composer = PickyConversationComposerView(session: session, viewModel: viewModel)

        #expect(session.isCompacting)
        #expect(snapshot.compactingOverlayCount == 1)
        #expect(composer.isComposerInputDisabled)
        #expect(composer.placeholderText == "Compacting…")
        #expect(composer.sendHelpText == "Session is compacting")
    }

    @Test func compactCompletionSystemMessageRendersDedicatedBubble() {
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-compact", kind: .system, text: "Session compacted after context overflow")]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(session.messages.first?.isCompactCompletionMessage == true)
        #expect(snapshot.compactCompletionBubbleCount == 1)
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

    @Test func composerShowsNotifyOnCompletionState() {
        let viewModel = makeViewModel()
        let enabledComposer = PickyConversationComposerView(
            session: makeConversationSession(status: .running, notifyMainOnCompletion: true),
            viewModel: viewModel
        )
        let disabledComposer = PickyConversationComposerView(
            session: makeConversationSession(status: .running, notifyMainOnCompletion: false),
            viewModel: viewModel
        )

        #expect(enabledComposer.notifyOnCompletionIconName == "bell.fill")
        #expect(enabledComposer.notifyOnCompletionHelpText == "Notify main agent on completion")
        #expect(disabledComposer.notifyOnCompletionIconName == "bell.slash")
        #expect(disabledComposer.notifyOnCompletionHelpText == "Do not notify main agent on completion")
    }

    @Test func headerTitleTooltipMentionsNameCommand() {
        let header = PickyConversationHeaderView(
            viewModel: makeViewModel(),
            session: makeConversationSession(status: .running)
        )

        #expect(header.titleHelpText.contains("/name"))
        #expect(header.titleHelpText.contains("rename"))
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
        #expect(errorBubble.recoveryChipLabels == ["⌨ Open Terminal"])
        #expect(errorBubble.titleText == "Command failed")
        #expect(header.statusColorName == "red")
    }

    @Test func errorBubbleHidesRedundantRuntimeErrorTitle() {
        let runtimeError = PickyErrorBubbleView(message: message("m-runtime-error", kind: .agentError, text: "Runtime error"))
        let emptyError = PickyErrorBubbleView(message: message("m-empty-error", kind: .agentError))

        #expect(runtimeError.titleText == nil)
        #expect(emptyError.titleText == nil)
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

    @Test func composerEditorHeightStartsRoomyAndCapsGrowth() {
        #expect(PickyConversationComposerView.editorHeight(for: "") == 32)
        #expect(PickyConversationComposerView.editorHeight(for: "one line") == 32)
        #expect(PickyConversationComposerView.editorHeight(for: "one\ntwo") == 48)
        #expect(PickyConversationComposerView.editorHeight(for: "one\ntwo\nthree\nfour") == 72)
    }

    @Test func composerDroppedFilePathsAppendAsPlainDraftText() {
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["/tmp/a.png"], to: "") == "/tmp/a.png")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["/tmp/a.png", "/tmp/b.txt"], to: "Please inspect") == "Please inspect\n/tmp/a.png\n/tmp/b.txt")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["  /tmp/c.log  "], to: "Existing\n") == "Existing\n/tmp/c.log")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["", "  "], to: "Existing") == "Existing")
    }

    @Test func composerDropTargetPlaceholderMentionsWholeCardDrop() {
        let composer = PickyConversationComposerView(
            session: makeConversationSession(status: .running),
            viewModel: makeViewModel(),
            isFileDropTargeted: true
        )

        #expect(composer.placeholderText.contains("screenshots"))
        #expect(composer.placeholderText.contains("anywhere"))
        #expect(composer.placeholderText.contains("insert paths"))
    }

    @Test func fileDropAcceptsImageProviders() {
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(Data("image".utf8), nil)
            return nil
        }

        #expect(PickyConversationFileDrop.acceptsDrop(provider))
        #expect(!PickyConversationFileDrop.acceptsFileURL(provider))
    }

    @Test func imageDropsAreCopiedToLocalTemporaryFilesBeforeInsertingPath() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let imageData = Data("picky screenshot bytes".utf8)
        let provider = NSItemProvider()
        provider.suggestedName = "Screenshot 2026-05-06 at 11.53.32 AM.png"
        provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
            completion(imageData, nil)
            return nil
        }

        let paths = await PickyConversationFileDrop.filePaths(from: [provider], destinationDirectory: directory)

        #expect(paths.count == 1)
        let path = try #require(paths.first)
        #expect(path.hasPrefix(directory.path))
        #expect(path.contains("Screenshot 2026-05-06"))
        #expect(URL(fileURLWithPath: path).pathExtension == "png")
        #expect(FileManager.default.contents(atPath: path) == imageData)
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
        #expect(failedComposer.defaultSubmitKind == .steer)
        #expect(failedComposer.optionReturnSubmitKind == nil)
        #expect(failedComposer.placeholderText.contains("recovery steer"))
        #expect(failedComposer.placeholderText.contains("open terminal"))
        #expect(!failedComposer.placeholderText.contains("logs"))
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
        let activeMenu = PickyConversationMenu(session: activeWithPiSession, viewModel: viewModel)
        #expect(activeMenu.canOpenPiTerminal)
        #expect(activeMenu.canCopyResumeCommand)
        #expect(activeMenu.canStop)

        let noPiMenu = PickyConversationMenu(session: terminalWithoutPiSession, viewModel: viewModel)
        #expect(!noPiMenu.canOpenPiTerminal)
        #expect(!noPiMenu.canCopyResumeCommand)
        #expect(!noPiMenu.canStop)
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

    @Test func userBubbleShowsPiExtensionLabelWhenPiExtensionOriginated() {
        let bubble = PickyUserBubbleView(message: message("m-pi", kind: .userText, text: "from extension", originatedBy: .piExtension))

        #expect(bubble.displayedOriginLabel == "from Pi extension")
    }

    @Test func userBubblePreviewUsesSameLineAndCharacterLimitsAsAgentResponses() {
        let eightLines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let nineLines = eightLines + "\nline 9"
        let exactCharacters = String(repeating: "가", count: 500)
        let longCharacters = exactCharacters + "나다라"

        let multilineBubble = PickyUserBubbleView(message: message("m-user-lines", kind: .userText, text: nineLines))
        let longBubble = PickyUserBubbleView(message: message("m-user-chars", kind: .userText, text: longCharacters, originatedBy: .mainAgent))

        #expect(multilineBubble.displayedMarkdownPreview == eightLines + "...")
        #expect(longBubble.displayedMarkdownPreview == exactCharacters + "...")
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

    @Test func activitySummaryShowsCalledReadEditAndEtcTools() {
        let items = PickyActivitySummary(edit: 3, bash: 0, thinking: 4, other: 5, read: 2, write: 0).visibleToolCallItems

        #expect(items.map(\.id) == ["read", "edit", "other"])
        #expect(items.map(\.count) == [2, 3, 5])
        #expect(items.map(\.label) == ["read", "edit", "etc"])
    }

    @Test func activitySnapshotWithOnlyThinkingIsHidden() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "hello"),
                message("a-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(thinking: 2)),
                message("a", kind: .agentText, text: "hi")
            ]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0)
        #expect(!snapshot.showsActivitySummary)
    }

    // MARK: - Last turn-only visibility (Earlier history)

    @Test func visibleMessagesContainsLastTwoUserTurnsOnward() {
        // With exactly two user turns, both turns (and everything after) stay
        // visible — nothing gets pushed into "Earlier history".
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

        #expect(list.visibleMessages.map(\.id) == ["u1", "a1", "u2", "a2-act", "a2"])
        #expect(list.hiddenHistoryCount == 0)
    }

    @Test func visibleMessagesShowsLastTwoUserTurnsWhenMoreExist() {
        // With three or more user turns, only the last two turns (from the second-to-last
        // user_text to the end of the message list) stay visible. Earlier turns collapse
        // behind the "Earlier history" pill.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "reply 1"),
                message("u2", kind: .userText, text: "second"),
                message("a2", kind: .agentText, text: "reply 2"),
                message("u3", kind: .userText, text: "third"),
                message("a3-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 1, bash: 0, thinking: 0, other: 0)),
                message("a3", kind: .agentText, text: "reply 3")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.visibleMessages.map(\.id) == ["u2", "a2", "u3", "a3-act", "a3"])
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

    @Test func runningSessionShowsLiveActivitySummaryWithoutAgentActivityMessage() {
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

        #expect(snapshot.activitySummaryCount == 1)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func newUserTurnDoesNotShowPreviousLiveActivityBeforeAgentStarts() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "is this backend-only?")
            ],
            activitySummary: PickyActivitySummary(edit: 3, bash: 31, thinking: 0, other: 7, read: 15, write: 1)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 0)
        #expect(!snapshot.showsActivitySummary)
    }

    @Test func runningSessionShowsLiveActivityWhenOnlyPreviousTurnHasActivitySnapshot() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 1, bash: 1, thinking: 1, other: 0)),
                message("a1", kind: .agentText, text: "done"),
                message("u2", kind: .userText, text: "continue"),
                message("a2-thinking", kind: .agentThinking, text: "Working…")
            ],
            activitySummary: PickyActivitySummary(edit: 0, bash: 3, thinking: 2, other: 0)
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.activitySummaryCount == 2)
        #expect(snapshot.showsActivitySummary)
    }

    @Test func completedSessionDoesNotAutoInsertLifetimeActivitySummary() {
        let session = makeConversationSession(
            status: .completed,
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
    contextUsage: PickyContextUsage? = nil,
    pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
    artifacts: [PickyArtifact] = [],
    logs: [String] = [],
    notifyMainOnCompletion: Bool? = nil,
    lastSummary: String = "summary"
) -> PickySessionListViewModel.SessionCard {
    PickySessionListViewModel.SessionCard.fromAgentSession(
        PickyAgentSession(
            id: id,
            title: "Test session",
            status: status,
            cwd: "/tmp/picky",
            createdAt: baseDate,
            updatedAt: baseDate,
            lastSummary: lastSummary,
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
            contextUsage: contextUsage,
            pendingExtensionUiRequest: pendingExtensionUiRequest,
            notifyMainOnCompletion: notifyMainOnCompletion
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
    assistantRun: PickyAssistantRunMetadata? = nil,
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
        assistantRun: assistantRun,
        errorContext: errorContext,
        errorMessage: errorMessage
    )
}

private func queueItem(_ text: String) -> PickyQueueItem {
    PickyQueueItem(text: text, enqueuedAt: baseDate)
}

private func extensionUiRequest(title: String? = "Need a decision", prompt: String? = "Pick one") -> PickyExtensionUiRequest {
    PickyExtensionUiRequest(
        id: "request-1",
        sessionId: "session-1",
        method: "askUserQuestion",
        title: title,
        prompt: prompt,
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
