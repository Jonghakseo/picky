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
    var screenContextTargetSessionID: String?
    var screenContextTargetSticky: Bool = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
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

    @Test func contextLineOnlyOccupiesCardSpaceWhenSessionHasContext() {
        var sessionWithoutContext = makeConversationSession(status: .completed)
        sessionWithoutContext.cwd = nil

        #expect(!PickyConversationContextLineView.hasContent(for: sessionWithoutContext))
        #expect(PickyConversationContextLineView.hasContent(for: makeConversationSession(status: .completed)))
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

    // Regression guard for the previously-intermittent missing-hover-icon bug
    // on collapsed pickle responses. The hover "open as report" icon is gated
    // by PickyAgentResponsePreview.isTruncated. The gate used to inspect only
    // raw newline / character counts of the source text, while
    // PickyConversationMarkdownText performs an independent per-block
    // truncation at codeBlockMaxLines. A message that fit within the outer
    // preview thresholds but contained a fenced code block longer than
    // codeBlockMaxLines therefore rendered "+N more lines" while the hover
    // icon never appeared. The gate now also inspects parsed code blocks.
    @Test func hoverIconGateRecognizesCodeBlockLevelTruncation() {
        let sample = """
        ```swift
        let a = 1
        let b = 2
        let c = 3
        let d = 4
        let e = 5
        ```
        """

        // Sample sits comfortably under the outer thresholds: 62 chars, 7
        // newline-separated lines. The bug only surfaced via code-block
        // truncation, which truncatedMarkdown does not touch because it only
        // caps the outer source text.
        #expect(sample.count <= PickyAgentResponsePreview.maxCharacters)
        #expect(sample.split(separator: "\n", omittingEmptySubsequences: false).count <= PickyAgentResponsePreview.maxLines)
        #expect(PickyAgentResponsePreview.truncatedMarkdown(sample) == sample)

        // The renderer parses a single 5-line code block, exceeding
        // PickyConversationMarkdownText.codeBlockMaxLines (default 4), so the
        // preview visibly shows a "+1 more line" footer.
        let codeBlockMaxLines = PickyConversationMarkdownText(markdown: "").codeBlockMaxLines
        let blocks = PickyReportMarkdownRenderer().blocks(from: sample)
        let codeBlockLineCounts: [Int] = blocks.compactMap { block in
            if case .codeBlock(let text) = block {
                return text.components(separatedBy: "\n").count
            }
            return nil
        }
        #expect(codeBlockLineCounts == [5])
        #expect(codeBlockLineCounts.contains(where: { $0 > codeBlockMaxLines }))

        // Gate now recognizes renderer-level truncation, so the bubble's
        // hoverIconAction returns a non-nil closure and the hover icon will
        // appear when the cursor enters the bubble.
        #expect(PickyAgentResponsePreview.isTruncated(sample))
    }

    @Test func hoverIconGateIgnoresCodeBlocksWithinTheRendererCap() {
        // 4-line code block is exactly at the cap, so no "+N more lines"
        // footer renders and the gate must not falsely advertise truncation.
        let sample = """
        ```swift
        let a = 1
        let b = 2
        let c = 3
        let d = 4
        ```
        """
        #expect(!PickyAgentResponsePreview.isTruncated(sample))
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

    @Test func artifactTrayPresentationDerivesSubtitlesActionsAndCount() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let reports = root.appendingPathComponent("reports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let existingFile = reports.appendingPathComponent("final-report.md")
        try "report".write(to: existingFile, atomically: true, encoding: .utf8)
        let artifactURL = try #require(URL(string: "https://github.com/creatrip/picky/pull/42"))
        let urlArtifact = PickyArtifact(
            id: "url",
            kind: "github",
            title: "Pull request",
            path: nil,
            url: artifactURL,
            updatedAt: baseDate
        )
        let existingArtifact = PickyArtifact(
            id: "file",
            kind: "report",
            title: "Final report",
            path: existingFile.path,
            url: nil,
            updatedAt: baseDate
        )
        let missingArtifact = PickyArtifact(
            id: "missing",
            kind: "report",
            title: "Missing report",
            path: reports.appendingPathComponent("missing.md").path,
            url: nil,
            updatedAt: baseDate
        )
        let unavailableArtifact = PickyArtifact(
            id: "unavailable",
            kind: "note",
            title: "Untitled note",
            path: nil,
            url: nil,
            updatedAt: baseDate
        )

        let urlPresentation = PickyArtifactTrayPresentation(artifact: urlArtifact, homeURL: root)
        let existingPresentation = PickyArtifactTrayPresentation(artifact: existingArtifact, homeURL: root)
        let missingPresentation = PickyArtifactTrayPresentation(artifact: missingArtifact, homeURL: root)
        let unavailablePresentation = PickyArtifactTrayPresentation(artifact: unavailableArtifact, homeURL: root)

        #expect(PickyArtifactTrayPresentation.trayCount(for: [urlArtifact, existingArtifact, missingArtifact, unavailableArtifact]) == 4)
        #expect(urlPresentation.subtitle == "github.com")
        #expect(urlPresentation.action == .openURL(artifactURL))
        #expect(existingPresentation.subtitle == "~/reports/final-report.md")
        #expect(existingPresentation.action == .revealPath(existingFile.standardizedFileURL))
        #expect(missingPresentation.action == .missingPath)
        #expect(unavailablePresentation.action == .unavailable)
    }

    @Test func artifactTrayMakesNonLinkArtifactsVisibleContext() {
        var session = makeConversationSession(status: .completed)
        session.cwd = nil
        session.artifacts = [
            PickyArtifact(id: "report", kind: "report", title: "Final report", path: "/tmp/final-report.md", url: nil, updatedAt: baseDate)
        ]

        #expect(PickyConversationContextLineView.hasContent(for: session))
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

    @Test func selectQuestionOptionsStayInlineAtCountAndLabelLengthBoundaries() {
        #expect(PickyQuestionOptionsLayoutPolicy.layout(for: ["One", "Two", "Three"]) == .inlineRow)
        #expect(PickyQuestionOptionsLayoutPolicy.layout(for: ["12345678", "abcdef", "abcd"]) == .inlineRow)
    }

    @Test func selectQuestionOptionsStackWhenCountOrIndividualLabelExceedsInlineLimits() {
        #expect(PickyQuestionOptionsLayoutPolicy.layout(for: ["One", "Two", "Three", "Four"]) == .stacked)
        #expect(PickyQuestionOptionsLayoutPolicy.layout(for: ["123456789"]) == .stacked)
    }

    @Test func selectQuestionOptionsStackWhenCombinedLabelsExceedInlineLimit() {
        #expect(PickyQuestionOptionsLayoutPolicy.layout(for: ["12345678", "abcdef", "abcde"]) == .stacked)
    }

    @Test func queuedFollowUpMatchingUserTextDoesNotRenderPendingBubble() {
        let followUpPrompt = """
        # Picky follow-up

        ## User follow-up
        - Source: text-follow-up

        아니다 10초

        ## Captured context
        - Captured at: 2026-05-26T08:38:00Z
        """
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "아니다 10초")],
            queuedFollowUps: [queueItem(followUpPrompt)]
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

    // Voice steer wraps the raw text inside the agentd steering envelope before
    // sending it to Pi, so Pi's queue snapshot carries the wrapped form while
    // the supervisor records the raw user instruction as `user_text`. The HUD
    // must unwrap the envelope and treat the two as the same message; otherwise
    // the card briefly (and for active turns, durably) shows the user input
    // twice — once as the user bubble, once as the pending bubble.
    @Test func queuedSteerEnvelopeMatchingUserTextDoesNotRenderPendingBubble() {
        let steerEnvelope = """
        # Picky steering message

        Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.

        ## User steering instruction
        - Source: text-follow-up

        잠깐만 멈춰봐

        ## Captured context
        - Captured at: 2026-05-26T08:38:00Z
        """
        let session = makeConversationSession(
            status: .running,
            messages: [message("m-user", kind: .userText, text: "잠깐만 멈춰봐")],
            queuedSteers: [queueItem(steerEnvelope)]
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

    // Mirrors the envelope built by agentd `prompt-builder.ts#buildSteerPrompt`.
    // The pending bubble must show only the user instruction, not the boilerplate
    // wrapper or the appended captured-context sections.
    @Test func queuedSteerEnvelopeDisplaysOnlyUserInstruction() {
        let steerEnvelope = """
        # Picky steering message

        Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.

        ## User steering instruction
        - Source: text-follow-up

        이게 힌트가 될까?

        ## Captured context
        - Captured at: 2026-05-26T08:38:00Z
        - CWD: /Users/creatrip/picky

        ## Screenshots
        - focused screen — shot-1.jpg
        """

        #expect(PickyQueuedInputText.displayText(from: steerEnvelope) == "이게 힌트가 될까?")
        #expect(PickyQueuedInputText.normalized(steerEnvelope) == "이게 힌트가 될까?")
    }

    // Mirrors `prompt-builder.ts#buildFollowUpPrompt` — kept alongside the steer
    // case so future heading renames are caught immediately.
    @Test func queuedFollowUpEnvelopeDisplaysOnlyUserInstruction() {
        let followUpEnvelope = """
        # Picky follow-up

        Use available Pi skills, extensions, MCPs, and local tools as appropriate. Treat all captured desktop data as neutral context; do not assume a workflow solely from a URL or app name.

        ## User follow-up
        - Source: text-follow-up

        아니다 10초

        ## Captured context
        - Captured at: 2026-05-26T08:38:00Z
        """

        #expect(PickyQueuedInputText.displayText(from: followUpEnvelope) == "아니다 10초")
    }

    @Test func queuedEnvelopePreservesUserInstructionStartingWithSourceBullet() {
        let steerEnvelope = """
        # Picky steering message

        Boilerplate.

        ## User steering instruction
        - Source: text-follow-up

        - Source: 이 문구는 사용자 지시의 일부야
        다음 줄도 유지해야 해

        ## Captured context
        - Captured at: 2026-05-26T08:38:00Z
        """
        let expected = "- Source: 이 문구는 사용자 지시의 일부야\n다음 줄도 유지해야 해"

        #expect(PickyQueuedInputText.displayText(from: steerEnvelope) == expected)
        #expect(PickyQueuedInputText.normalized(steerEnvelope) == expected)
    }

    // Plain queued items (no agentd envelope) must pass through unchanged so
    // legacy/voice paths that already store the raw user text still render.
    @Test func queuedPlainTextWithoutEnvelopePassesThrough() {
        let plain = "stop and use 10 seconds"
        #expect(PickyQueuedInputText.displayText(from: plain) == plain)
        #expect(PickyQueuedInputText.normalized("  stop and use 10 seconds  \r\n") == plain)
    }

    // Multi-line user instructions must survive extraction intact, and the
    // extractor must stop at the next `## ` heading rather than swallowing the
    // captured-context block.
    @Test func queuedSteerEnvelopePreservesMultilineInstruction() {
        let envelope = """
        # Picky steering message

        Boilerplate.

        ## User steering instruction
        line one
        line two

        line four

        ## Captured context
        - hidden
        """

        let expected = "line one\nline two\n\nline four"
        #expect(PickyQueuedInputText.displayText(from: envelope) == expected)
    }

    @Test func compactingPhaseShowsOverlayAndAllowsComposerEditingWhileBlockingSend() {
        let session = makeConversationSession(status: .running, lastSummary: "Compacting after context overflow…")
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let composer = PickyConversationComposerView(session: session, viewModel: viewModel)

        #expect(session.isCompacting)
        #expect(snapshot.compactingOverlayCount == 1)
        #expect(!composer.isComposerInputDisabled)
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

    @Test func commandReceiptRendersThroughUserBubbleSurface() {
        let receipt = PickyCommandReceipt(command: "/c", status: .submitted, detail: nil)
        let commandMessage = message("m-command", kind: .commandReceipt, text: "/c", commandReceipt: receipt)
        let session = makeConversationSession(status: .completed, messages: [commandMessage])
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let bubble = PickyUserBubbleView(message: commandMessage)

        #expect(snapshot.commandReceiptBubbleCount == 1)
        #expect(bubble.displayedMarkdownPreview == "/c")
        #expect(bubble.displayedOriginLabel == nil)
    }

    @Test func failedCommandReceiptStillUsesUserBubbleTextOnly() {
        let receipt = PickyCommandReceipt(command: "/c", status: .failed, detail: "unmerged paths")
        let commandMessage = message("m-command", kind: .commandReceipt, text: "/c", commandReceipt: receipt)
        let bubble = PickyUserBubbleView(message: commandMessage)

        #expect(bubble.displayedMarkdownPreview == "/c")
        #expect(bubble.displayedOriginLabel == nil)
    }

    @Test func extensionNotifySystemMessageRendersSeverityBubbleAndReportGate() {
        let longText = Array(repeating: "\u{001B}[38;5;214mPi extension produced a detailed warning.\u{001B}[39m", count: 30).joined(separator: "\n")
        let notifyMessage = message("m-notify", kind: .system, text: longText, notifyType: .warning)
        let session = makeConversationSession(status: .running, messages: [notifyMessage])
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot
        let bubble = PickyNotifyBubbleView(message: notifyMessage, onOpenAsReport: {})

        #expect(snapshot.notifyBubbleCount == 1)
        #expect(bubble.shouldOfferReport)
        #expect(bubble.previewMarkdown.hasSuffix("..."))
        #expect(!bubble.previewMarkdown.contains("[38;5;214m"))
        #expect(notifyMessage.openAsReportMarkdown?.contains("[38;5;214m") == false)
    }

    @Test func compactFailureSystemMessageRendersDedicatedBubble() {
        let text = "Auto-compaction failed\n\nSummarization failed: server overloaded\n\nContext was not reduced. Current usage remains 258,568/272,000 tokens."
        let session = makeConversationSession(
            status: .completed,
            messages: [message("m-compact-failed", kind: .system, text: text)]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(session.messages.first?.isCompactFailureMessage == true)
        #expect(session.messages.first?.compactFailureDetailText?.contains("Summarization failed") == true)
        #expect(snapshot.compactFailureBubbleCount == 1)
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
        #expect(header.statusTone == .warning)
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
        #expect(enabledComposer.notifyOnCompletionHelpText == "Notify Picky on completion (⌘N)")
        #expect(disabledComposer.notifyOnCompletionIconName == "bell.slash")
        #expect(disabledComposer.notifyOnCompletionHelpText == "Do not notify Picky on completion (⌘N)")
    }

    @Test func composerStopButtonOnlyShowsForActiveTurns() {
        let viewModel = makeViewModel()
        let userMessage = message("m1", kind: .userText, text: "hi")

        let runningComposer = PickyConversationComposerView(
            session: makeConversationSession(status: .running),
            viewModel: viewModel
        )
        #expect(runningComposer.isStopButtonVisible)

        // Fresh manual Pickle: waiting_for_input with no messages should hide stop.
        let emptyWaitingComposer = PickyConversationComposerView(
            session: makeConversationSession(status: .waiting_for_input),
            viewModel: viewModel
        )
        #expect(!emptyWaitingComposer.isStopButtonVisible)

        // Once the user has submitted at least one message, waiting_for_input keeps stop.
        let activeWaitingComposer = PickyConversationComposerView(
            session: makeConversationSession(status: .waiting_for_input, messages: [userMessage]),
            viewModel: viewModel
        )
        #expect(activeWaitingComposer.isStopButtonVisible)

        for status in [PickySessionStatus.queued, .blocked, .completed, .failed, .cancelled] {
            let composer = PickyConversationComposerView(session: makeConversationSession(status: status), viewModel: viewModel)
            #expect(!composer.isStopButtonVisible)
        }
    }

    @Test func headerTitleTooltipMentionsNameCommand() {
        let header = PickyConversationHeaderView(
            viewModel: makeViewModel(),
            session: makeConversationSession(status: .running)
        )

        #expect(header.titleHelpText.contains("/name"))
        #expect(header.titleHelpText.contains("rename"))
    }

    @Test func headerStatusPresentationMapsEveryStateToLocalizedLabelKeyAndTone() {
        let expectations: [(PickySessionStatus, String, PickyConversationStatusTone)] = [
            (.running, "hud.conversation.status.running", .info),
            (.completed, "hud.conversation.status.completed", .success),
            (.waiting_for_input, "hud.conversation.status.waiting", .warning),
            (.failed, "hud.conversation.status.failed", .destructiveText),
            (.blocked, "hud.conversation.status.blocked", .warningText),
            (.cancelled, "hud.conversation.status.cancelled", .textTertiary),
            (.queued, "hud.conversation.status.queued", .textTertiary)
        ]

        for (status, labelKey, tone) in expectations {
            let presentation = PickyConversationStatusPresentation(status: status)
            #expect(presentation.labelKey == labelKey)
            #expect(presentation.tone == tone)
        }
    }

    @Test func headerMetaPresentationKeepsFullInteractiveMetadataVisible() {
        let presentation = PickyConversationHeaderMetaPresentation(
            assistantRun: PickyAssistantRunMetadata(
                model: "anthropic/claude-opus-4-7",
                thinkingLevel: .xhigh
            ),
            contextUsage: PickyContextUsage(tokens: 420, contextWindow: 1_000, percent: 42)
        )

        #expect(presentation.hasContent)
        #expect(presentation.contextDisplay?.label == "42%")
        #expect(presentation.modelText == "anthropic/claude-opus-4-7")
        #expect(presentation.thinkingLevelText == "xhigh")
        #expect(presentation.helpText.contains("anthropic/claude-opus-4-7"))
        #expect(presentation.helpText.contains("xhigh"))
    }

    @Test func headerRenameCommandBuilderTrimsAndDedupsAndRejectsEmpty() {
        // Empty input or whitespace-only input must cancel (no command emitted).
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "", current: "Old") == nil)
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "   \n\t ", current: "Old") == nil)
        // Same trimmed value must cancel even with surrounding whitespace.
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "  Old  ", current: "Old") == nil)
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "Old", current: "  Old  ") == nil)
        // Different non-empty input produces the slash command with the trimmed value.
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "  새 이름  ", current: "Old") == "/name 새 이름")
        #expect(PickyConversationHeaderView.renameCommandText(forNewTitle: "New Title", current: "Old") == "/name New Title")
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
        #expect(header.statusTone == .destructiveText)
    }

    @Test func errorBubbleHidesRedundantRuntimeErrorTitle() {
        let runtimeError = PickyErrorBubbleView(message: message("m-runtime-error", kind: .agentError, text: "Runtime error"))
        let emptyError = PickyErrorBubbleView(message: message("m-empty-error", kind: .agentError))

        #expect(runtimeError.titleText == nil)
        #expect(emptyError.titleText == nil)
    }

    @Test func composerBorderStatePrioritizesDropBashRunningAndFocus() {
        #expect(
            PickyConversationComposerView.composerBorderState(
                isDropTargeted: true,
                bashMode: .visible,
                isRunning: true,
                isFocused: true
            ) == .fileDrop
        )
        #expect(
            PickyConversationComposerView.composerBorderState(
                isDropTargeted: false,
                bashMode: .private,
                isRunning: true,
                isFocused: true
            ) == .bash
        )
        #expect(
            PickyConversationComposerView.composerBorderState(
                isDropTargeted: false,
                bashMode: .none,
                isRunning: true,
                isFocused: true
            ) == .running
        )
        #expect(
            PickyConversationComposerView.composerBorderState(
                isDropTargeted: false,
                bashMode: .none,
                isRunning: false,
                isFocused: true
            ) == .focused
        )
        #expect(
            PickyConversationComposerView.composerBorderState(
                isDropTargeted: false,
                bashMode: .none,
                isRunning: false,
                isFocused: false
            ) == .rest
        )
    }

    @Test func composerReturnKeyMappingKeepsShiftReturnForNewlines() {
        #expect(PickyConversationComposerView.returnKeyAction(for: []) == .submitDefault)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.option]) == .submitOptionReturn)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.shift]) == .insertNewline)
        #expect(PickyConversationComposerView.returnKeyAction(for: [.shift, .option]) == .insertNewline)
    }

    @Test func composerUpArrowMappingRecallsPreviousMessageUnlessModified() {
        #expect(PickyConversationComposerView.upArrowKeyAction(for: []) == .recallPreviousMessage)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.shift]) == .navigateAutocomplete)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.option]) == .clearQueue)
        #expect(PickyConversationComposerView.upArrowKeyAction(for: [.option, .shift]) == .clearQueue)
    }

    @Test func composerPreviousUserMessageSkipsEmptyAndNonUserMessages() {
        let messages = [
            message("m-agent", kind: .agentText, text: "assistant"),
            message("m-empty", kind: .userText, text: "   \n"),
            message("m-user", kind: .userText, text: "last request")
        ]

        #expect(PickyConversationComposerView.previousUserMessageText(in: messages) == "last request")
        #expect(PickyConversationComposerView.previousUserMessageText(in: [message("m-agent", kind: .agentText, text: "assistant")]) == nil)
    }

    @Test func composerEditorHeightStartsRoomyAndCapsMeasuredGrowth() {
        #expect(PickyConversationComposerView.editorHeight(forMeasuredContentHeight: 0) == 50)
        #expect(PickyConversationComposerView.editorHeight(forMeasuredContentHeight: 49.2) == 50)
        #expect(PickyConversationComposerView.editorHeight(forMeasuredContentHeight: 61.2) == 62)
        #expect(PickyConversationComposerView.editorHeight(forMeasuredContentHeight: 120) == 72)
        #expect(PickyConversationComposerView.editorHeight(for: "one\ntwo\nthree\nfour") == 72)
    }

    @Test func composerDroppedFilePathsAppendAsPlainDraftText() {
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["/tmp/a.png"], to: "") == "/tmp/a.png")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["/tmp/a.png", "/tmp/b.txt"], to: "Please inspect") == "Please inspect\n/tmp/a.png\n/tmp/b.txt")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["  /tmp/c.log  "], to: "Existing\n") == "Existing\n/tmp/c.log")
        #expect(PickyConversationComposerView.draftText(afterAppendingDroppedFilePaths: ["", "  "], to: "Existing") == "Existing")
    }

    @Test func composerSubmissionTextMergesAttachmentsAtSendTime() {
        // No attachments → submission text is just the trimmed draft.
        #expect(PickyConversationComposerView.submissionText(draft: "  hello  ", attachmentPaths: []) == "hello")
        // Draft + attachments → newline-joined paths after the draft (existing helper behavior).
        #expect(
            PickyConversationComposerView.submissionText(
                draft: "Please inspect",
                attachmentPaths: ["/tmp/a.png", "/tmp/b.txt"]
            ) == "Please inspect\n/tmp/a.png\n/tmp/b.txt"
        )
        // Attachments-only submit is allowed.
        #expect(PickyConversationComposerView.submissionText(draft: "", attachmentPaths: ["/tmp/a.png"]) == "/tmp/a.png")
        #expect(PickyConversationComposerView.submissionText(draft: "   ", attachmentPaths: ["/tmp/a.png"]) == "/tmp/a.png")
        // Empty draft + empty attachments → empty payload (caller treats as no-op).
        #expect(PickyConversationComposerView.submissionText(draft: "   ", attachmentPaths: []).isEmpty)
    }

    @Test func composerBashModeMirrorsAgentdParser() {
        // Plain text → no bash mode.
        #expect(PickyConversationComposerView.bashMode(in: "") == .none)
        #expect(PickyConversationComposerView.bashMode(in: "hello") == .none)
        #expect(PickyConversationComposerView.bashMode(in: "   hello world") == .none)

        // Bare `!` / `!!` without an actual command → still no bash mode
        // (agentd's parser treats them as regular messages).
        #expect(PickyConversationComposerView.bashMode(in: "!") == .none)
        #expect(PickyConversationComposerView.bashMode(in: "!!") == .none)
        #expect(PickyConversationComposerView.bashMode(in: "!   ") == .none)
        #expect(PickyConversationComposerView.bashMode(in: "!!   ") == .none)

        // `!` + command → visible bash. `!!` + command → private bash.
        #expect(PickyConversationComposerView.bashMode(in: "!ls") == .visible)
        #expect(PickyConversationComposerView.bashMode(in: "! ls -la") == .visible)
        #expect(PickyConversationComposerView.bashMode(in: "  ! ls\n") == .visible)
        #expect(PickyConversationComposerView.bashMode(in: "!!ls") == .private)
        #expect(PickyConversationComposerView.bashMode(in: "!! ls -la") == .private)
        #expect(PickyConversationComposerView.bashMode(in: "  !! pwd  ") == .private)
    }

    @Test func composerSubmissionTextEscapesBashPrefixWhenAttachmentsArePresent() {
        // Without attachments, the `!` prefix is preserved so agentd handles
        // it as a bash execution (this path is unchanged).
        #expect(PickyConversationComposerView.submissionText(draft: "!ls", attachmentPaths: []) == "!ls")
        #expect(PickyConversationComposerView.submissionText(draft: "!! pwd", attachmentPaths: []) == "!! pwd")

        // With attachments present, the appended file paths must not be
        // glued into a bash command. We prepend a single space so agentd's
        // `parseUserBashInput` no longer sees `!` at the start.
        #expect(
            PickyConversationComposerView.submissionText(
                draft: "!ls",
                attachmentPaths: ["/tmp/a.png"]
            ) == " !ls\n/tmp/a.png"
        )
        #expect(
            PickyConversationComposerView.submissionText(
                draft: "!! rm -rf",
                attachmentPaths: ["/tmp/a.png", "/tmp/b.txt"]
            ) == " !! rm -rf\n/tmp/a.png\n/tmp/b.txt"
        )
        // Attachments-only (no `!` prefix) submit is unchanged.
        #expect(
            PickyConversationComposerView.submissionText(
                draft: "please look",
                attachmentPaths: ["/tmp/a.png"]
            ) == "please look\n/tmp/a.png"
        )
    }

    @Test func composerAttachmentImageDetectionMatchesCommonExtensions() {
        #expect(PickyComposerAttachment.isImagePath("/tmp/a.png"))
        #expect(PickyComposerAttachment.isImagePath("/tmp/a.JPG"))
        #expect(PickyComposerAttachment.isImagePath("/tmp/a.heic"))
        #expect(!PickyComposerAttachment.isImagePath("/tmp/a.txt"))
        #expect(!PickyComposerAttachment.isImagePath("/tmp/no-extension"))
        let attachment = PickyComposerAttachment(path: "/Users/x/Pictures/screenshot.png")
        #expect(attachment.displayName == "screenshot.png")
        #expect(attachment.isImage)
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
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "x", status: "running"))))
        try await waitForSession(viewModel, id: "x")

        await #expect(throws: SendFailure.self) {
            try await viewModel.steer(text: "test", sessionID: "x")
        }

        #expect(viewModel.lastError == "command failed")
        #expect(client.sentCommands.isEmpty)
    }

    @Test func composerSubmitSteerSendsSteerEnvelope() async throws {
        let client = ConversationCardFakeClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "x", status: "running"))))
        try await waitForSession(viewModel, id: "x")

        try await viewModel.steer(text: "test", sessionID: "x")

        // `apply(.connected)` async-sends `.listSessions`; that Task can race with
        // this test's `.steer` send and slot in after it, so filter by intent
        // instead of trusting `.last`.
        let command = try #require(client.sentCommands.last { $0.type == .steer })
        #expect(command.text == "test")
        #expect(command.sessionId == "x")
    }

    @Test func composerSubmitFollowUpSendsFollowUpEnvelope() async throws {
        let client = ConversationCardFakeClient()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter())
        viewModel.start()
        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "x", status: "completed"))))
        try await waitForSession(viewModel, id: "x")

        try await viewModel.followUp(text: "test", sessionID: "x")

        // `apply(.connected)` async-sends `.listSessions`; that Task can race with
        // this test's `.followUp` send and slot in after it, so filter by intent
        // instead of trusting `.last`.
        let command = try #require(client.sentCommands.last { $0.type == .followUp })
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

    @Test func composerRestoresQueuedMessagesIntoDraftInQueueOrder() {
        let earlyFollowUp = PickyQueueItem(text: "follow first", enqueuedAt: baseDate.addingTimeInterval(1))
        let laterSteer = PickyQueueItem(text: "steer second", enqueuedAt: baseDate.addingTimeInterval(2))

        let restored = PickyConversationComposerView.draftRestoringQueuedMessages(
            draft: "existing draft",
            queuedSteers: [laterSteer],
            queuedFollowUps: [earlyFollowUp]
        )

        #expect(restored == "existing draft\n\nfollow first\n\nsteer second")
    }

    @Test func composerQueuedMessageRestoreReturnsNilWhenQueueHasNoText() {
        let restored = PickyConversationComposerView.draftRestoringQueuedMessages(
            draft: "existing draft",
            queuedSteers: [PickyQueueItem(text: "", enqueuedAt: baseDate)],
            queuedFollowUps: []
        )

        #expect(restored == nil)
    }

    @Test func menuEnablementMatchesSessionStatus() {
        let viewModel = makeViewModel()
        let activeWithPiSession = makeConversationSession(status: .running, logs: ["pi session: /tmp/picky.pi-session"])
        let terminalWithoutPiSession = makeConversationSession(status: .completed)
        let activeMenu = PickyConversationMenu(session: activeWithPiSession, viewModel: viewModel)
        #expect(activeMenu.canOpenPiTerminal)
        #expect(activeMenu.canShowInlinePiTerminal)
        #expect(!activeMenu.isShowingInlinePiTerminal)
        #expect(activeMenu.canCopyResumeCommand)
        #expect(activeMenu.canStop)

        let noPiMenu = PickyConversationMenu(session: terminalWithoutPiSession, viewModel: viewModel)
        #expect(!noPiMenu.canOpenPiTerminal)
        #expect(!noPiMenu.canShowInlinePiTerminal)
        #expect(!noPiMenu.canCopyResumeCommand)
        #expect(!noPiMenu.canStop)
    }

    @Test func cardHoverSeedsVoiceFollowUpTargetForPushToTalk() async throws {
        let client = ConversationCardFakeClient()
        let selection = ConversationCardSelectionStore()
        let viewModel = PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter(), selectionStore: selection)
        viewModel.start()
        defer { viewModel.stop() }

        client.emit(.protocolEvent(.fixture(eventJSON: sessionUpdatedJSON(id: "pickle-voice", status: "running"))))
        try await waitForSession(viewModel, id: "pickle-voice")

        let session = try #require(viewModel.sessions.first(where: { $0.id == "pickle-voice" }))
        let card = PickyConversationCardView(viewModel: viewModel, session: session)

        card.updateVoiceFollowUpHover(true)
        #expect(viewModel.hoveredVoiceFollowUpSessionID == "pickle-voice")
        #expect(selection.hoveredVoiceFollowUpSessionID == "pickle-voice")

        card.updateVoiceFollowUpHover(false)
        #expect(viewModel.hoveredVoiceFollowUpSessionID == nil)
        #expect(selection.hoveredVoiceFollowUpSessionID == nil)
    }

    @Test func userBubbleShowsByMainAgentLabelWhenOriginated() {
        let bubble = PickyUserBubbleView(message: message("m-main", kind: .userText, text: "delegated", originatedBy: .mainAgent))

        #expect(bubble.displayedOriginLabel == "by Picky")
    }

    @Test func userBubbleShowsPiTerminalLabelWhenPiExtensionOriginated() {
        let bubble = PickyUserBubbleView(message: message("m-pi", kind: .userText, text: "from terminal", originatedBy: .piExtension))

        #expect(bubble.displayedOriginLabel == "from Pi terminal")
    }

    @Test func userBubbleUsesDesktopEmojiForAttachedScreenContext() {
        let bubble = PickyUserBubbleView(message: message("m-screen", kind: .userText, text: "use this", attachedImagesCount: 1))

        #expect(bubble.displayedAttachedImagesLabel == "🖥️ 1 attached")
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

    @Test func latestAgentBubbleShowsFullMarkdownAndStillOffersReport() {
        let eightLines = (1...8).map { "line \($0)" }.joined(separator: "\n")
        let nineLines = eightLines + "\nline 9"
        let agentMessage = message("m-agent", kind: .agentText, text: nineLines)

        let olderBubble = PickyAgentBubbleView(message: agentMessage, onOpenAsReport: {})
        let latestBubble = PickyAgentBubbleView(
            message: agentMessage,
            onOpenAsReport: {},
            isLatestAgentResponse: true
        )

        #expect(olderBubble.displayedMarkdown == eightLines + "...")
        #expect(olderBubble.displayedCodeBlockMaxLines == PickyAgentResponsePreview.codeBlockMaxLines)
        #expect(latestBubble.displayedMarkdown == nineLines)
        #expect(latestBubble.displayedCodeBlockMaxLines == 0)
        #expect(latestBubble.shouldOfferReport)
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

    // MARK: - Last turn-only visibility (View as TUI)

    @Test func bottomScrollTriggerChangesForNewUserVisibleContent() {
        let viewModel = makeViewModel()
        let baseSession = makeConversationSession(
            status: .running,
            messages: [message("u1", kind: .userText, text: "first")]
        )
        let baseTrigger = PickyConversationListView(session: baseSession, viewModel: viewModel).bottomScrollTrigger

        let newMessageSession = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("u2", kind: .userText, text: "second")
            ]
        )
        #expect(PickyConversationListView(session: newMessageSession, viewModel: viewModel).bottomScrollTrigger != baseTrigger)

        let queuedFollowUpSession = makeConversationSession(
            status: .running,
            messages: baseSession.messages,
            queuedFollowUps: [queueItem("queued follow-up")]
        )
        #expect(PickyConversationListView(session: queuedFollowUpSession, viewModel: viewModel).bottomScrollTrigger != baseTrigger)

        let queuedSteerSession = makeConversationSession(
            status: .running,
            messages: baseSession.messages,
            queuedSteers: [queueItem("queued steer")]
        )
        #expect(PickyConversationListView(session: queuedSteerSession, viewModel: viewModel).bottomScrollTrigger != baseTrigger)

        var localRequestSession = baseSession
        localRequestSession.lastRequestAt = baseDate.addingTimeInterval(1)
        #expect(PickyConversationListView(session: localRequestSession, viewModel: viewModel).bottomScrollTrigger != baseTrigger)

        let request = extensionUiRequest()
        let pendingQuestionSession = makeConversationSession(
            status: .waiting_for_input,
            messages: [message("u1", kind: .userText, text: "first"), message("q1", kind: .agentQuestion, question: request)],
            pendingExtensionUiRequest: request
        )
        let answeredQuestionSession = makeConversationSession(
            status: .running,
            messages: pendingQuestionSession.messages
        )
        #expect(PickyConversationListView(session: pendingQuestionSession, viewModel: viewModel).bottomScrollTrigger != PickyConversationListView(session: answeredQuestionSession, viewModel: viewModel).bottomScrollTrigger)
    }

    @Test func todoProgressRepinsOnlyWhenOverlayVisibilityChanges() {
        let viewModel = makeViewModel()
        var first = makeConversationSession(status: .running, messages: [message("u1", kind: .userText, text: "first")])
        first.todoState = PickyTodoState(
            tasks: [PickyTodoTask(id: "todo-1", content: "Implement HUD", status: .inProgress)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        var updated = first
        updated.todoState = PickyTodoState(
            tasks: [PickyTodoTask(id: "todo-1", content: "Implement HUD", status: .completed)],
            updatedAt: Date(timeIntervalSince1970: 1_800_000_010)
        )

        let firstTrigger = PickyConversationListView(
            session: first,
            viewModel: viewModel,
            bottomOverlayInset: PickyTodoProgressOverlayView.bottomContentInset
        ).bottomScrollTrigger
        let updatedTrigger = PickyConversationListView(
            session: updated,
            viewModel: viewModel,
            bottomOverlayInset: PickyTodoProgressOverlayView.bottomContentInset
        ).bottomScrollTrigger
        let clearedTrigger = PickyConversationListView(
            session: updated,
            viewModel: viewModel,
            bottomOverlayInset: 0
        ).bottomScrollTrigger

        #expect(firstTrigger == updatedTrigger)
        #expect(firstTrigger != clearedTrigger)
    }

    @Test func questionCollapseScrollPolicyRepinsOnlyWhenActiveQuestionCloses() {
        let open = PickyConversationBottomScrollTrigger(
            latestMessageID: "q1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: "request-1"
        )
        let closed = PickyConversationBottomScrollTrigger(
            latestMessageID: "q1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )
        let opened = PickyConversationBottomScrollTrigger(
            latestMessageID: "q1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: "request-2"
        )

        #expect(PickyConversationScrollPolicy.shouldRepinAfterQuestionCollapse(from: open, to: closed))
        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: open, to: closed, isPinnedToBottom: false))
        #expect(!PickyConversationScrollPolicy.shouldRepinAfterQuestionCollapse(from: closed, to: opened))
        #expect(!PickyConversationScrollPolicy.shouldRepinAfterQuestionCollapse(from: open, to: opened))
    }

    @Test func conversationScrollPolicyKeepsUnpinnedRemoteMessagesInPlace() {
        let current = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )
        let remoteMessage = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-2",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )

        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: current, to: remoteMessage, isPinnedToBottom: true))
        #expect(!PickyConversationScrollPolicy.shouldAutoScroll(from: current, to: remoteMessage, isPinnedToBottom: false))
    }

    @Test func conversationScrollPolicyReturnsUnpinnedUsersToTheirOwnSubmission() {
        let current = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )
        let localSubmission = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: baseDate,
            pendingExtensionUiRequestID: nil
        )

        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: current, to: localSubmission, isPinnedToBottom: true))
        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: current, to: localSubmission, isPinnedToBottom: false))
    }

    @Test func conversationScrollPolicyPinsSessionSwitches() {
        let initialTrigger = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )

        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: nil, to: initialTrigger, isPinnedToBottom: true))
        #expect(PickyConversationScrollPolicy.shouldAutoScroll(from: nil, to: initialTrigger, isPinnedToBottom: false))
    }

    @Test func conversationScrollPolicyTreatsOnlyNearViewportBottomAsPinned() {
        let viewportHeight: CGFloat = 320
        let threshold = PickyConversationScrollPolicy.bottomPinThreshold

        #expect(PickyConversationScrollPolicy.isBottomAnchorPinned(
            maxY: viewportHeight + threshold,
            viewportHeight: viewportHeight
        ))
        #expect(!PickyConversationScrollPolicy.isBottomAnchorPinned(
            maxY: viewportHeight + threshold + 0.1,
            viewportHeight: viewportHeight
        ))
    }

    @Test func conversationScrollPolicyShowsAndHidesJumpToLatestForUnreadRemoteContent() {
        let current = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-1",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )
        let remoteMessage = PickyConversationBottomScrollTrigger(
            latestMessageID: "message-2",
            queuedSteers: [],
            queuedFollowUps: [],
            steeringMode: .oneAtATime,
            followUpMode: .oneAtATime,
            lastRequestAt: nil,
            pendingExtensionUiRequestID: nil
        )

        #expect(PickyConversationScrollPolicy.shouldMarkContentUnread(from: current, to: remoteMessage, isPinnedToBottom: false))
        #expect(!PickyConversationScrollPolicy.shouldMarkContentUnread(from: current, to: remoteMessage, isPinnedToBottom: true))
        #expect(PickyConversationScrollPolicy.shouldShowJumpToLatest(isPinnedToBottom: false, hasUnreadContent: true))
        #expect(!PickyConversationScrollPolicy.shouldShowJumpToLatest(isPinnedToBottom: true, hasUnreadContent: true))
        #expect(!PickyConversationScrollPolicy.shouldShowJumpToLatest(isPinnedToBottom: false, hasUnreadContent: false))
    }

    @Test func visibleMessagesContainsLastTwoUserTurnsOnward() {
        // With exactly two user turns, both turns (and everything after) stay
        // visible — nothing gets pushed into "View as TUI".
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

    @Test func visibleMessagesShowsLastFiveUserTurnsWhenMoreExist() {
        // With six or more user turns, only the last five turns (from the fifth-to-last
        // user_text to the end of the message list) stay visible. Earlier turns collapse
        // behind the "View as TUI" pill.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "reply 1"),
                message("u2", kind: .userText, text: "second"),
                message("a2", kind: .agentText, text: "reply 2"),
                message("u3", kind: .userText, text: "third"),
                message("a3", kind: .agentText, text: "reply 3"),
                message("u4", kind: .userText, text: "fourth"),
                message("a4", kind: .agentText, text: "reply 4"),
                message("u5", kind: .userText, text: "fifth"),
                message("a5", kind: .agentText, text: "reply 5"),
                message("u6", kind: .userText, text: "sixth"),
                message("a6-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(edit: 1, bash: 0, thinking: 0, other: 0)),
                message("a6", kind: .agentText, text: "reply 6")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.visibleMessages.map(\.id) == ["u2", "a2", "u3", "a3", "u4", "a4", "u5", "a5", "u6", "a6-act", "a6"])
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

    @Test func currentTurnFallsBackToMostRecentToolWhenNothingIsRunning() {
        // During a thinking/streaming gap between tool calls, `activeTool`
        // is nil because no tool is in the running state. The live indicator
        // must still show the *last* tool of the turn so it does not blink
        // on and off — a checkmark on the row signals "that call settled".
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "do stuff")
            ],
            tools: [
                toolActivity("finished", name: "read", secondsOffset: 1, status: "succeeded")
            ]
        )

        #expect(session.activeTool == nil)
        let representative = session.mostRecentTool(after: baseDate)
        #expect(representative?.toolCallId == "finished")
    }

    @Test func mostRecentToolPrefersRunningOverFinished() {
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "do stuff")
            ],
            tools: [
                toolActivity("done", name: "read", secondsOffset: 1, status: "succeeded"),
                toolActivity("live", name: "bash", secondsOffset: 2, status: "running")
            ]
        )

        #expect(session.mostRecentTool(after: baseDate)?.toolCallId == "live")
    }

    @Test func mostRecentToolIgnoresToolsStartedBeforeTurn() {
        let earlier = baseDate.addingTimeInterval(-30)
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "new turn")
            ],
            tools: [
                PickyToolActivity(
                    toolCallId: "previous-turn",
                    name: "read",
                    status: "succeeded",
                    startedAt: earlier
                )
            ]
        )

        #expect(session.activeTool == nil)
        #expect(session.mostRecentTool(after: baseDate) == nil)
    }

    @Test func runningSessionExposesActiveToolOnCurrentTurnCard() {
        // The active turn must surface the currently running tool so the user
        // gets a live "what's the agent doing right now" signal. Past turns
        // collapse to the aggregate chip, so this assertion focuses on the
        // current-turn slot only.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u", kind: .userText, text: "hello"),
                message("a", kind: .agentText, text: "hi")
            ],
            tools: [
                toolActivity("t1", name: "bash", secondsOffset: 1, status: "running")
            ],
            activitySummary: PickyActivitySummary(bash: 1)
        )
        let view = PickyConversationListView(session: session, viewModel: makeViewModel())

        #expect(view.turnGroups.last?.isCurrent == true)
        #expect(session.activeTool?.toolCallId == "t1")
        // No agentActivity message yet means no aggregate chip rendered.
        #expect(view.renderSnapshot.activitySummaryCount == 0)
        #expect(!view.renderSnapshot.showsActivitySummary)
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

    @Test func previousTurnSnapshotKeepsItsInlineRowWhileNewTurnStarts() {
        // Previously this case asserted that a *second* aggregate chip was
        // appended at the bottom of the list to represent live activity in the
        // new turn. The bottom chip was removed; the previous turn's
        // agentActivity message still renders as an inline row, and live
        // activity in the new turn now surfaces through the turn header.
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

        #expect(snapshot.activitySummaryCount == 1)
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

    // MARK: - Turn card grouping

    @Test func turnGroupsExposeOneCardPerVisibleUserText() {
        // visibleMessages 정책 (마지막 다섯 user_text 부터) 과 turn 그룹화가 함께
        // 동작해 세 개의 turn card 가 생기는지 검증.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "reply 1"),
                message("u2", kind: .userText, text: "second"),
                message("a2-act", kind: .agentActivity, activitySnapshot: PickyActivitySummary(bash: 1)),
                message("a2", kind: .agentText, text: "reply 2"),
                message("u3", kind: .userText, text: "third"),
                message("a3", kind: .agentText, text: "reply 3")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)
        let snapshot = list.renderSnapshot

        #expect(list.turnGroups.map(\.id) == ["u1", "u2", "u3"])
        #expect(list.turnGroups.map(\.isCurrent) == [false, false, true])
        #expect(snapshot.turnCardCount == 3)
    }

    @Test func turnCardCountIsZeroWhenNoUserTextExists() {
        // user_text 가 없는 슬라이스는 pre-turn 그룹으로 나오고 turn card 가 생기지 않는다.
        let session = makeConversationSession(
            status: .running,
            messages: [
                message("a1", kind: .agentText, text: "hello"),
                message("a2", kind: .agentThinking, text: "thinking")
            ]
        )
        let viewModel = makeViewModel()
        let snapshot = PickyConversationListView(session: session, viewModel: viewModel).renderSnapshot

        #expect(snapshot.turnCardCount == 0)
    }

    @Test func completedSessionMarksAllTurnsAsNonCurrent() {
        // 완료된 세션은 마지막 turn 까지 collapsed 정책의 대상 (isCurrent == false).
        let session = makeConversationSession(
            status: .completed,
            messages: [
                message("u1", kind: .userText, text: "first"),
                message("a1", kind: .agentText, text: "reply 1"),
                message("u2", kind: .userText, text: "second"),
                message("a2", kind: .agentText, text: "reply 2")
            ]
        )
        let viewModel = makeViewModel()
        let list = PickyConversationListView(session: session, viewModel: viewModel)

        #expect(list.turnGroups.map(\.isCurrent) == [false, false])
    }

}

private let baseDate = Date(timeIntervalSince1970: 1_777_777_777)

private func toolActivity(
    _ id: String,
    name: String,
    secondsOffset: TimeInterval,
    status: String = "succeeded"
) -> PickyToolActivity {
    PickyToolActivity(
        toolCallId: id,
        name: name,
        status: status,
        startedAt: baseDate.addingTimeInterval(secondsOffset)
    )
}

private func settle() async throws {
    try await Task.sleep(nanoseconds: 20_000_000)
}

@MainActor
private func waitForSession(
    _ viewModel: PickySessionListViewModel,
    id: String,
    timeout: Duration = .seconds(1),
    interval: Duration = .milliseconds(5)
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !viewModel.sessions.contains(where: { $0.id == id }) {
        if clock.now >= deadline {
            Issue.record("Timed out waiting for session \(id)")
            throw CancellationError()
        }
        try await Task.sleep(for: interval)
    }
}

private func sessionUpdatedJSON(id: String = "session-1", status: String = "running") -> String {
    """
    {"id":"evt-\(id)","protocolVersion":"2026-05-09","timestamp":"2026-05-01T00:00:00.000Z","type":"sessionUpdated","session":{"id":"\(id)","title":"Test session","status":"\(status)","cwd":"/tmp/picky","createdAt":"2026-05-01T00:00:00.000Z","updatedAt":"2026-05-01T00:00:00.000Z","lastSummary":"summary","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}}
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
    tools: [PickyToolActivity] = [],
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
            tools: tools,
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
    errorMessage: String? = nil,
    notifyType: PickyExtensionNotifyType? = nil,
    commandReceipt: PickyCommandReceipt? = nil,
    attachedImagesCount: Int? = nil
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
        errorMessage: errorMessage,
        notifyType: notifyType,
        commandReceipt: commandReceipt,
        attachedImagesCount: attachedImagesCount
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
