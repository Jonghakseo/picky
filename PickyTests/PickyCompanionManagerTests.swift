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
    private(set) var calls: [String] = []

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        calls.append("submit")
        submissions.append(submission)
        return PickyAgentSubmissionReceipt(sessionID: "created-session", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        calls.append("send:\(command.type.rawValue)")
        commands.append(command)
    }
    func disconnect() { continuation.yield(.disconnected) }
}

private final class FakeVoiceSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
}

@MainActor
private final class FakeSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "Fake Speech"
    private(set) var spokenUtterances: [String] = []
    private var onFinish: ((Bool) -> Void)?
    var shouldStartSpeaking = true
    var isSpeaking = false

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        spokenUtterances.append(utterance)
        guard shouldStartSpeaking else { return false }
        self.onFinish = onFinish
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        isSpeaking = false
        onFinish = nil
    }

    func finishSpeaking(didFinish: Bool = true) {
        guard let onFinish else { return }
        self.onFinish = nil
        isSpeaking = false
        onFinish(didFinish)
    }
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

    @Test func voiceTranscriptFollowsUpToPressedVoiceTargetSnapshot() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.selectedSessionID = "stale-selected-session"
        selection.hoveredVoiceFollowUpSessionID = "changed-after-press"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "snapshot follow-up", contextPacket: context, voiceFollowUpSessionID: "session-at-press")

        #expect(receipt.sessionID == "session-at-press")
        #expect(client.commands.first?.type == .steer)
        #expect(client.commands.first?.sessionId == "session-at-press")
        #expect(client.commands.first?.text == "snapshot follow-up")
        #expect(client.commands.first?.context?.source == "voice-follow-up")
        #expect(client.submissions.isEmpty)
    }

    // Regression: between `stopPushToTalkFromKeyboardShortcut` and the eventual
    // `submitDraftText` -> `submitTranscriptToPickyAgent` callback, the dictation
    // publishers (isKeyboardRecording / isFinalizingTranscript / isPreparingToRecord)
    // can briefly all be false while `pendingAgentResponseStartedAt` is still nil.
    // The reducer reports idle in that window, and the previous implementation
    // cleared `voiceFollowUpSessionIDForCurrentUtterance` from inside
    // `updateVoicePresentation`, racing the response task into routing the voice
    // utterance to the main agent instead of the hovered side session.
    @Test @MainActor func idleVoicePresentationDoesNotClearPressedHoverIDBeforeSubmit() async {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("session-hovered")
        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == "session-hovered")

        manager.updateVoicePresentation(
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizing: false,
            isPreparing: false
        )

        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == "session-hovered")
    }

    @Test func voiceTranscriptDoesNotFallbackToHoverAtRoutingTime() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.hoveredVoiceFollowUpSessionID = "late-hovered-session"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice")

        let receipt = try await manager.routeVoiceTranscript(transcript: "new task", contextPacket: context)

        #expect(receipt.sessionID == "created-session")
        #expect(client.submissions.first?.transcript == "new task")
        #expect(client.commands.isEmpty)
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
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

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
        #expect(speechProvider.spokenUtterances == ["열어볼게요."])
    }

    @Test func injectedSpeechProviderControlsResponseLifecycle() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "완료했어요."),
            source: "voice"
        )

        #expect(manager.voiceState == .responding)
        #expect(speechProvider.spokenUtterances == ["완료했어요."])

        speechProvider.finishSpeaking()
        await Task.yield()

        #expect(manager.voiceState == .idle)
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

    @Test func speechFallbackProviderUsesFallbackWhenPrimaryFailsAsynchronously() async throws {
        let primary = FakeSpeechPlaybackProvider()
        let fallback = FakeSpeechPlaybackProvider()
        let provider = PickyFallbackSpeechPlaybackProvider(primary: primary, fallback: fallback)
        var finishes: [Bool] = []

        let started = provider.speak("안녕하세요") { finishes.append($0) }
        #expect(started)
        #expect(primary.spokenUtterances == ["안녕하세요"])
        #expect(fallback.spokenUtterances.isEmpty)

        primary.finishSpeaking(didFinish: false)
        try await settle()

        #expect(fallback.spokenUtterances == ["안녕하세요"])
        #expect(finishes.isEmpty)

        fallback.finishSpeaking(didFinish: true)
        try await settle()

        #expect(finishes == [true])
    }

    @Test func speechFallbackProviderUsesFallbackWhenPrimaryRefusesToStart() async throws {
        let primary = FakeSpeechPlaybackProvider()
        primary.shouldStartSpeaking = false
        let fallback = FakeSpeechPlaybackProvider()
        let provider = PickyFallbackSpeechPlaybackProvider(primary: primary, fallback: fallback)
        var finishes: [Bool] = []

        let started = provider.speak("안녕하세요") { finishes.append($0) }

        #expect(started)
        #expect(primary.spokenUtterances == ["안녕하세요"])
        #expect(fallback.spokenUtterances == ["안녕하세요"])
        #expect(finishes.isEmpty)
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
        #expect(finalizing.promptBubbleState == .hidden)
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

    @Test func voiceInputInterruptSendsMainAgentAbortBeforeNextTranscriptRouting() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.hoveredVoiceFollowUpSessionID = "changed-after-press"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)

        manager.interruptSpokenResponseForVoiceInput()
        try await settle()
        _ = try await manager.routeVoiceTranscript(transcript: "새 음성 입력", contextPacket: context(source: "voice-follow-up"), voiceFollowUpSessionID: "session-hovered")

        #expect(client.calls == ["send:abortMainAgent", "send:steer"])
        #expect(client.commands.map(\.type) == [.abortMainAgent, .steer])
        #expect(client.commands.first?.sessionId == nil)
        #expect(client.commands.last?.sessionId == "session-hovered")
        #expect(client.commands.last?.text == "새 음성 입력")
    }

    @Test func voiceInputAbortPrecedesNewTaskSubmission() async throws {
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())

        manager.interruptSpokenResponseForVoiceInput()
        try await settle()
        _ = try await manager.routeVoiceTranscript(transcript: "새 작업", contextPacket: context(source: "voice"))

        #expect(client.calls == ["send:abortMainAgent", "submit"])
        #expect(client.commands.map(\.type) == [.abortMainAgent])
        #expect(client.submissions.first?.transcript == "새 작업")
    }

    @Test func voiceInputSuppressesQuickReplySpeechWithoutQueueing() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.interruptSpokenResponseForVoiceInput()
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(contextId: "context-voice", text: "입력 중 도착한 응답")))

        #expect(manager.latestAgentSessionSummary == "입력 중 도착한 응답")
        #expect(manager.voiceState != .responding)
    }

    @Test func voiceQuickReplyDuringFinalizingDefersSpeechUntilSuppressionClears() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.updateVoicePresentation(
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizing: true,
            isPreparing: false
        )
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-voice",
            text: "빠른 답변",
            originSource: .voice,
            replyKind: .main
        )))
        try await settle()

        #expect(manager.latestAgentSessionSummary == "빠른 답변")
        #expect(manager.voiceState == .responding)
        #expect(speechProvider.spokenUtterances.isEmpty)

        manager.updateVoicePresentation(
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizing: false,
            isPreparing: false
        )
        try await Task.sleep(nanoseconds: 150_000_000)

        #expect(speechProvider.spokenUtterances == ["빠른 답변"])
        manager.stop()
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

    @Test func stripParentheticalsRemovesAsciiAndFullWidthBracketsForSpeech() async throws {
        let asciiInput = "배포는 완료됐어요 (https://example.com/run/123)."
        #expect(stripParentheticalsForSpeech(asciiInput) == "배포는 완료됐어요.")

        let fullWidthInput = "세션 아이디는 잘 저장됐습니다（session-abc-123）."
        #expect(stripParentheticalsForSpeech(fullWidthInput) == "세션 아이디는 잘 저장됐습니다.")

        let multipleInput = "PR (#123) 을 머지했고 (development 브랜치) 로 돌아갔어요."
        #expect(stripParentheticalsForSpeech(multipleInput) == "PR 을 머지했고 로 돌아갔어요.")
    }

    @Test func stripParentheticalsKeepsTextWhenNoParenthesesPresent() async throws {
        let plain = "프로덕션으로 올린 명령을 몇 분 안에 모니터링해볼게요."
        #expect(stripParentheticalsForSpeech(plain) == plain)
    }

    @Test func stripParentheticalsFallsBackWhenWholeMessageIsParenthesised() async throws {
        let allParens = "(seed bootstrap rules)"
        #expect(stripParentheticalsForSpeech(allParens) == allParens)
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

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}
