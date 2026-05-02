//
//  PickyCompanionManagerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeVoiceClient: PickyAgentClient {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    private(set) var submissions: [PickyAgentSubmission] = []
    private(set) var commands: [PickyCommandEnvelope] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        submissions.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "created-session", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws { commands.append(command) }
    func disconnect() { continuation.yield(.disconnected) }
}

private final class FakeVoiceSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
}

@MainActor
struct PickyCompanionManagerTests {
    @Test func voiceTranscriptCreatesTaskWhenNoSessionIsSelected() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice")

        let receipt = try await manager.routeVoiceTranscript(transcript: "new task", contextPacket: context)

        #expect(receipt.sessionID == "created-session")
        #expect(client.submissions.first?.context.source == "voice")
        #expect(client.commands.isEmpty)
    }

    @Test func voiceTranscriptFollowsUpToHoveredVoiceTarget() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.selectedSessionID = "stale-selected-session"
        selection.hoveredVoiceFollowUpSessionID = "session-hovered"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "hover follow-up", contextPacket: context)

        #expect(receipt.sessionID == "session-hovered")
        #expect(client.commands.first?.type == .steer)
        #expect(client.commands.first?.sessionId == "session-hovered")
        #expect(client.commands.first?.text == "hover follow-up")
        #expect(client.commands.first?.context?.source == "voice-follow-up")
        #expect(client.submissions.isEmpty)
    }

    @Test func staleSelectedSessionDoesNotCaptureVoiceTranscript() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.selectedSessionID = "stale-selected-session"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice")

        let receipt = try await manager.routeVoiceTranscript(transcript: "new task", contextPacket: context)

        #expect(receipt.sessionID == "created-session")
        #expect(client.submissions.first?.transcript == "new task")
        #expect(client.commands.isEmpty)
    }

    @Test func emptyVoiceFollowUpReceiptClearsProcessingState() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "session-selected", message: ""),
            source: "voice-follow-up"
        )

        #expect(manager.voiceState == .idle)
        #expect(manager.latestAgentSessionSummary == "선택한 세션에 스티어링 메시지를 전달했어요.")
    }

    @Test func emptyNewVoiceTaskReceiptKeepsWaitingForAgentEvents() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: ""),
            source: "voice"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.latestAgentSessionSummary == "응답 준비 중…")
    }

    @Test func recognizedVoicePromptStaysVisibleUntilSpokenResponseStarts() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.beginAwaitingAgentResponse(recognizedTranscript: "  설정 열어줘  ")

        #expect(manager.voiceState == .processing)
        #expect(manager.currentVoicePromptPreview == "설정 열어줘")
        #expect(manager.voicePromptBubbleState == .recognized("설정 열어줘"))

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "열어볼게요."),
            source: "voice"
        )

        #expect(manager.currentVoicePromptPreview == nil)
        #expect(manager.voicePromptBubbleState == .hidden)
        #expect(manager.latestAgentSessionSummary == "열어볼게요.")
        #expect(manager.voiceState == .responding)
    }

    @Test func recognizedVoicePromptDisplayTextIsCappedForOverlayOnly() async throws {
        let longPrompt = String(repeating: "긴", count: 350)
        let bubbleState = CompanionVoicePromptBubbleState.recognized(longPrompt)

        #expect(bubbleState.displayText.count == 281)
        #expect(bubbleState.displayText.hasSuffix("…"))
    }

    @Test func speechPlaybackPreparationAddsShortSilentPreroll() {
        let prepared = PickySpeechPlaybackPreparation.prepareForPlayback("안녕하세요")

        #expect(prepared == "[[slnc 500]]안녕하세요")
    }

    @Test func voicePresentationKeepsAwaitingAgentStateAfterDictationResetsToIdle() async throws {
        let presentation = CompanionVoicePresentationReducer.reduce(
            currentVoiceState: .processing,
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizingTranscript: false,
            isPreparingToRecord: false,
            isShortcutHeld: false,
            isAwaitingAgentResponse: true,
            recognizedPrompt: "  설정 열어줘  "
        )

        #expect(presentation.voiceState == .processing)
        #expect(presentation.promptBubbleState == .recognized("설정 열어줘"))
    }

    @Test func voicePresentationShowsPromptBubbleOnlyAfterReleaseOrRecognizedPrompt() async throws {
        let preparing = CompanionVoicePresentationReducer.reduce(
            currentVoiceState: .idle,
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizingTranscript: false,
            isPreparingToRecord: true,
            isShortcutHeld: false,
            isAwaitingAgentResponse: false,
            recognizedPrompt: nil
        )
        let finalizing = CompanionVoicePresentationReducer.reduce(
            currentVoiceState: .listening,
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizingTranscript: true,
            isPreparingToRecord: false,
            isShortcutHeld: false,
            isAwaitingAgentResponse: false,
            recognizedPrompt: nil
        )

        #expect(preparing.voiceState == .processing)
        #expect(preparing.promptBubbleState == .hidden)
        #expect(finalizing.voiceState == .processing)
        #expect(finalizing.promptBubbleState == .recognizing)
    }

    @Test func voicePresentationUsesPhysicalShortcutHoldImmediately() async throws {
        let presentation = CompanionVoicePresentationReducer.reduce(
            currentVoiceState: .idle,
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizingTranscript: false,
            isPreparingToRecord: false,
            isShortcutHeld: true,
            isAwaitingAgentResponse: false,
            recognizedPrompt: nil
        )

        #expect(presentation.voiceState == .listening)
        #expect(presentation.promptBubbleState == .hidden)
    }

    @Test func quickReplyDoesNotEndVoiceProcessingBeforeMinimumDisplayDuration() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.beginAwaitingAgentResponse(recognizedTranscript: "짧은 요청")
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "context-voice", text: "바로 온 응답")))

        #expect(manager.voiceState == .processing)
        #expect(manager.latestAgentSessionSummary == "응답 준비 중…")
        #expect(manager.voicePromptBubbleState == .recognized("짧은 요청"))

        manager.stop()
    }

    @Test func progressEventsDoNotOverwriteVisibleCursorResponse() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "기존 응답"),
            source: "voice"
        )
        #expect(manager.voiceState == .responding)

        manager.applyAgentEvent(.sessionLogAppended(sessionId: "side-1", line: "running"))
        manager.applyAgentEvent(.toolActivityUpdated(sessionId: "side-1", tool: PickyToolActivity(
            toolCallId: "tool-1",
            name: "bash",
            status: "running",
            preview: nil,
            startedAt: nil,
            endedAt: nil
        )))
        manager.applyAgentEvent(.sessionUpdated(PickyAgentSession(
            id: "side-1",
            title: "Side",
            status: .running,
            cwd: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            lastSummary: "Follow-up queued",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )))

        #expect(manager.latestAgentSessionSummary == "기존 응답")
    }

    @Test func voiceInputInterruptsSpokenResponseImmediately() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "말하는 중"),
            source: "voice"
        )
        #expect(manager.voiceState == .responding)

        manager.interruptSpokenResponseForVoiceInput()

        #expect(manager.voiceState == .idle)
        #expect(manager.latestAgentSessionSummary == "말하는 중")
    }

    @Test func voiceInputSuppressesQuickReplySpeechWithoutQueueing() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.interruptSpokenResponseForVoiceInput()
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "context-voice", text: "입력 중 도착한 응답")))

        #expect(manager.latestAgentSessionSummary == "입력 중 도착한 응답")
        #expect(manager.voiceState != .responding)
    }

    @Test func completedVoiceInputAllowsCurrentResponseSpeech() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.interruptSpokenResponseForVoiceInput()
        manager.beginAwaitingAgentResponse(recognizedTranscript: "새 질문")
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "새 답변"),
            source: "voice"
        )

        #expect(manager.latestAgentSessionSummary == "새 답변")
        #expect(manager.voiceState == .responding)
    }

    private func context(source: String) -> PickyContextPacket {
        PickyContextPacket(
            id: "context-voice",
            source: source,
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            transcript: "continue",
            selectedText: nil,
            cwd: "/tmp/project",
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }
}
