//
//  PickyCompanionManagerTests.swift
//  PickyTests
//

import AppKit
import AVFoundation
import Foundation
import Testing
@testable import Picky

private final class FakeVoiceClient: PickyAgentClient, @unchecked Sendable {
    private let continuation: AsyncStream<PickyClientEvent>.Continuation
    let events: AsyncStream<PickyClientEvent>
    // CompanionManager dispatches several commands through detached
    // `Task { agentClient.send(...) }` blocks, so writes happen off the main
    // actor while assertions read from MainActor. Guard the fake's state with
    // a lock so cross-thread observations are always consistent.
    private let lock = NSLock()
    private var _submissions: [PickyAgentSubmission] = []
    private var _commands: [PickyCommandEnvelope] = []
    private var _calls: [String] = []
    private var _disconnectCalls = 0
    var submissions: [PickyAgentSubmission] { lock.withLock { _submissions } }
    var commands: [PickyCommandEnvelope] { lock.withLock { _commands } }
    var calls: [String] { lock.withLock { _calls } }
    var disconnectCalls: Int { lock.withLock { _disconnectCalls } }

    init() {
        var continuation: AsyncStream<PickyClientEvent>.Continuation!
        self.events = AsyncStream { continuation = $0 }
        self.continuation = continuation
    }

    func connect() async { continuation.yield(.connected) }
    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        lock.withLock {
            _calls.append("submit")
            _submissions.append(submission)
        }
        return PickyAgentSubmissionReceipt(sessionID: "created-session", message: "")
    }
    func send(_ command: PickyCommandEnvelope) async throws {
        lock.withLock {
            _calls.append("send:\(command.type.rawValue)")
            _commands.append(command)
        }
    }
    func disconnect() {
        lock.withLock { _disconnectCalls += 1 }
        continuation.yield(.disconnected)
    }
}

private final class FakeVoiceSelectionStore: PickySessionSelectionStoring {
    var selectedSessionID: String?
    var hoveredVoiceFollowUpSessionID: String?
    var screenContextTargetSessionID: String?
}

@MainActor
private final class FakeSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "Fake Speech"
    private(set) var spokenUtterances: [String] = []
    private var onFinish: ((Bool) -> Void)?
    var shouldStartSpeaking = true
    var isSpeaking = false
    private(set) var stopCount = 0

    @discardableResult
    func speak(_ utterance: String, onFinish: @escaping (Bool) -> Void) -> Bool {
        spokenUtterances.append(utterance)
        guard shouldStartSpeaking else { return false }
        self.onFinish = onFinish
        isSpeaking = true
        return true
    }

    func stopSpeaking() {
        stopCount += 1
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
private final class FakeNSSpeechSynthesizer: PickyNSSpeechSynthesizing {
    var delegate: NSSpeechSynthesizerDelegate?
    var isSpeaking = false
    var startSpeakingResult = true
    private(set) var spokenStrings: [String] = []
    private(set) var stopCount = 0

    func startSpeaking(_ string: String) -> Bool {
        spokenStrings.append(string)
        if startSpeakingResult {
            isSpeaking = true
        }
        return startSpeakingResult
    }

    func stopSpeaking() {
        stopCount += 1
        isSpeaking = false
    }
}

@MainActor
private final class FakeRealtimeAudioPlaybackEngine: PickyRealtimeAudioPlaybacking {
    var isPlaying = false
    var playedAudioMs: Double = 0
    var onPlaybackDrained: (() -> Void)?
    private(set) var enqueuedAudio: [String] = []
    private(set) var stopCount = 0

    func enqueuePCM16Base64(_ audioBase64: String) {
        enqueuedAudio.append(audioBase64)
        isPlaying = true
    }

    func stopAndReturnPlayedAudioMs() -> Double {
        stop()
        return playedAudioMs
    }

    func stop() {
        stopCount += 1
        isPlaying = false
    }

    func finishPlayback() {
        isPlaying = false
        onPlaybackDrained?()
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
        #expect(client.commands.first?.type == .followUp)
        #expect(client.commands.first?.sessionId == "session-at-press")
        #expect(client.commands.first?.text == "snapshot follow-up")
        #expect(client.commands.first?.context?.source == "voice-follow-up")
        #expect(client.submissions.isEmpty)
    }

    @Test func voiceTranscriptWithScreenContextTargetSendsSteerAndClearsTarget() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-session"
        let manager = CompanionManager(agentClient: client, selectionStore: selection)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "pickle delta", contextPacket: context, voiceFollowUpSessionID: "pickle-session")

        #expect(receipt.sessionID == "pickle-session")
        #expect(client.commands.first?.type == .steer)
        #expect(client.commands.first?.sessionId == "pickle-session")
        #expect(client.commands.first?.text == "pickle delta")
        #expect(client.commands.first?.context?.id == "context-voice")
        #expect(client.submissions.isEmpty)
        #expect(selection.screenContextTargetSessionID == nil)
    }

    @Test func pickleHoverVoiceFollowUpNeverUsesRealtimeCommands() async throws {
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())
        let context = context(source: "voice-follow-up")

        _ = try await manager.routeVoiceTranscript(transcript: "pickle delta", contextPacket: context, voiceFollowUpSessionID: "pickle-session")

        #expect(client.commands.map(\.type) == [.followUp])
        let sentRealtimeCommand = client.commands.contains { command in
            switch command.type {
            case .beginMainRealtimeVoiceTurn, .appendMainRealtimeInputAudio, .commitMainRealtimeVoiceTurn, .cancelMainRealtimeVoiceTurn:
                return true
            default:
                return false
            }
        }
        #expect(sentRealtimeCommand == false)
        #expect(client.submissions.isEmpty)
    }

    // Regression: between `stopPushToTalkFromKeyboardShortcut` and the eventual
    // `submitDraftText` -> `submitTranscriptToPickyAgent` callback, the dictation
    // publishers (isKeyboardRecording / isFinalizingTranscript / isPreparingToRecord)
    // can briefly all be false while `pendingAgentResponseStartedAt` is still nil.
    // The reducer reports idle in that window, and the previous implementation
    // cleared `voiceFollowUpSessionIDForCurrentUtterance` from inside
    // `updateVoicePresentation`, racing the response task into routing the voice
    // utterance to Picky instead of the hovered Pickle.
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
        #expect(manager.latestAgentSessionSummary == L10n.t("directMessage.steerDelivered"))
    }

    @Test func emptyNewVoiceTaskReceiptKeepsWaitingForAgentEvents() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse()

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: ""),
            source: "voice"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.latestAgentSessionSummary == L10n.t("agent.summary.preparingResponse"))
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

    @Test func narrateProgressShowsCursorBubbleTextAndSpeaks() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.narrateProgressRequested(PickyNarrateProgressRequest(
            text: "로그를 확인하고 있어요.",
            sessionId: nil
        )))

        #expect(manager.latestAgentSessionSummary == "로그를 확인하고 있어요.")
        #expect(manager.voiceState == .responding)
        #expect(speechProvider.spokenUtterances == ["로그를 확인하고 있어요."])
    }

    @Test func repeatedNarrateProgressCutInsKeepLatestSpeechLifecycleSafe() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.narrateProgressRequested(PickyNarrateProgressRequest(
            text: "첫 작업을 준비하고 있어요.",
            sessionId: nil
        )))
        manager.applyAgentEvent(.narrateProgressRequested(PickyNarrateProgressRequest(
            text: "다음 작업을 준비하고 있어요.",
            sessionId: nil
        )))

        #expect(manager.latestAgentSessionSummary == "다음 작업을 준비하고 있어요.")
        #expect(manager.voiceState == .responding)
        #expect(speechProvider.spokenUtterances == ["첫 작업을 준비하고 있어요.", "다음 작업을 준비하고 있어요."])
        #expect(speechProvider.stopCount == 2)
        #expect(speechProvider.isSpeaking)

        speechProvider.finishSpeaking()
        try await waitUntil { manager.voiceState == .idle }
        #expect(!speechProvider.isSpeaking)
    }

    @Test @MainActor func realtimePlaybackStopBeforeFirstAudioIsSafe() {
        let engine = OpenAIRealtimeAudioPlaybackEngine()

        #expect(engine.stopAndReturnPlayedAudioMs() == 0)
        #expect(engine.playedAudioMs == 0)
    }

    @Test @MainActor func realtimePlaybackEnqueuePCM16DataIsSafe() {
        let engine = OpenAIRealtimeAudioPlaybackEngine()

        engine.enqueuePCM16Data(Data(repeating: 0, count: PickyRealtimePCM16Audio.bytesPerSample * 24))
        engine.stop()
    }

    @Test func realtimePCM16AudioUsesFloatPlaybackBufferForAVAudioEngineCompatibility() {
        let samples: [Int16] = [-32768, 0, 32767]
        let data = Data(samples.flatMap { sample -> [UInt8] in
            let value = UInt16(bitPattern: sample).littleEndian
            return [UInt8(value & 0x00ff), UInt8((value & 0xff00) >> 8)]
        })

        let buffer = PickyRealtimePCM16Audio.makePlaybackBuffer(from: data)

        #expect(buffer?.format.commonFormat == .pcmFormatFloat32)
        #expect(buffer?.format.sampleRate == 24_000)
        #expect(buffer?.format.channelCount == 1)
        #expect(buffer?.frameLength == 3)
        #expect(buffer?.floatChannelData?[0][0] == -1)
        #expect(buffer?.floatChannelData?[0][1] == 0)
        #expect(abs((buffer?.floatChannelData?[0][2] ?? 0) - 0.9999695) < 0.00001)
    }

    @Test func realtimeResponseStartHidesRecognizedPromptBeforeShowingReply() async throws {
        let playback = FakeRealtimeAudioPlaybackEngine()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            realtimeAudioPlaybackEngine: playback
        )
        manager.beginAwaitingAgentResponse(recognizedTranscript: "마이크 테스트")

        manager.applyAgentEvent(.mainRealtimeOutputAudioDelta(inputId: nil, audioBase64: "AAAA"))

        #expect(manager.currentVoicePromptPreview == nil)
        #expect(manager.voicePromptBubbleState == .hidden)
        #expect(manager.voiceState == .responding)
        #expect(playback.enqueuedAudio == ["AAAA"])
    }

    @Test func realtimeTranscriptCompletionResetsAccumulatorForFollowUpResponses() async throws {
        let inputID = UUID()
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.applyAgentEvent(.mainRealtimeOutputTranscriptDelta(inputId: inputID, delta: "조회 중"))
        manager.applyAgentEvent(.mainRealtimeOutputTranscriptCompleted(inputId: inputID, transcript: "조회 중"))
        manager.applyAgentEvent(.mainRealtimeOutputTranscriptDelta(inputId: inputID, delta: "완료"))

        #expect(manager.latestAgentSessionSummary == "완료")
    }

    @Test func realtimePlaybackDrainClearsRespondingAfterTurnDone() async throws {
        let playback = FakeRealtimeAudioPlaybackEngine()
        let inputID = UUID()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            realtimeAudioPlaybackEngine: playback
        )

        manager.applyAgentEvent(.mainRealtimeOutputAudioDelta(inputId: inputID, audioBase64: "AAAA"))
        #expect(manager.voiceState == .responding)

        manager.applyAgentEvent(.mainRealtimeTurnDone(PickyMainRealtimeTurnDoneEvent(inputId: inputID, status: .completed, finalTranscript: "완료")))
        #expect(manager.voiceState == .responding)

        playback.finishPlayback()

        #expect(manager.voiceState == .idle)
    }

    @Test func realtimeTranscriptEventsDoNotTriggerExistingSpeechProvider() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.mainRealtimeOutputTranscriptCompleted(inputId: nil, transcript: "Realtime 응답"))
        manager.applyAgentEvent(.mainRealtimeTurnDone(PickyMainRealtimeTurnDoneEvent(inputId: nil, status: .completed, finalTranscript: "Realtime 응답")))

        #expect(manager.latestAgentSessionSummary == "Realtime 응답")
        #expect(speechProvider.spokenUtterances.isEmpty)
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

    @Test func speechPlaybackPreparationDoesNotInjectEmbeddedSpeechMarkers() {
        let prepared = PickySpeechPlaybackPreparation.prepareForPlayback("안녕하세요")

        #expect(prepared == "안녕하세요")
    }

    @Test func systemSpeechProviderDelaysPrerollWithoutEmbeddedMarkers() async throws {
        let synthesizer = FakeNSSpeechSynthesizer()
        let provider = PickySystemSpeechPlaybackProvider(speechSynthesizer: synthesizer, prerollDelay: 0.01)

        #expect(provider.speak("안녕하세요") { _ in })
        #expect(provider.isSpeaking)
        #expect(synthesizer.spokenStrings.isEmpty)

        try await waitUntil { synthesizer.spokenStrings == ["안녕하세요"] }
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

    @Test func speechFallbackProviderIsSpeakingReflectsUnderlyingProvidersOnly() async throws {
        let primary = FakeSpeechPlaybackProvider()
        let fallback = FakeSpeechPlaybackProvider()
        let provider = PickyFallbackSpeechPlaybackProvider(primary: primary, fallback: fallback)

        let started = provider.speak("안녕하세요") { _ in }
        #expect(started)
        #expect(provider.isSpeaking)

        // Simulate the underlying provider stopping without delivering its
        // finish callback. The manager's polling safety net must be able to see
        // that real playback has ended so the cursor response bubble can clear.
        primary.isSpeaking = false

        #expect(!provider.isSpeaking)
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
        #expect(manager.latestAgentSessionSummary == L10n.t("agent.summary.preparingResponse"))
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

        manager.applyAgentEvent(.sessionLogAppended(sessionId: "pickle-1", line: "running"))
        manager.applyAgentEvent(.toolActivityUpdated(sessionId: "pickle-1", tool: PickyToolActivity(
            toolCallId: "tool-1",
            name: "bash",
            status: "running",
            preview: nil,
            startedAt: nil,
            endedAt: nil
        )))
        manager.applyAgentEvent(.sessionUpdated(PickyAgentSession(
            id: "pickle-1",
            title: "Pickle",
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

        #expect(client.calls == ["send:abortMainAgent", "send:followUp"])
        #expect(client.commands.map(\.type) == [.abortMainAgent, .followUp])
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

    @Test func voiceInputAbortAlsoAbortsInFlightPickleFollowUpTarget() async throws {
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())
        // Simulate a previous voice utterance routed to a Pickle while the
        // response is still loading so the session-scoped abort must be
        // dispatched alongside `abortMainAgent`.
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-in-flight")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "이전 질문")

        manager.interruptSpokenResponseForVoiceInput()
        // `abortMainAgentForVoiceInput` dispatches two detached
        // `Task { agentClient.send(...) }` blocks; a fixed `settle()` sleep
        // races them under load. Poll until both commands have been recorded.
        try await waitUntil { Set(client.calls) == Set(["send:abortMainAgent", "send:abort"]) }

        let abortCommand = client.commands.first { $0.type == .abort }
        #expect(abortCommand?.sessionId == "pickle-in-flight")
    }

    @Test func voiceInputAbortDoesNotTouchPickleWhenNoResponseIsInFlight() async throws {
        // Regression guard: when the previous Pickle follow-up has already
        // completed (no pending response, voiceState != .responding) the PTT
        // interrupt must not send `.abort` for that stale session id, which
        // would otherwise overwrite a `done` Pickle to `cancelled` on agentd.
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-already-done")

        manager.interruptSpokenResponseForVoiceInput()
        // Wait for the fire-and-forget `abortMainAgent` Task to flush so the
        // no-abort assertion below doesn't race the dispatch.
        try await waitUntil { client.calls == ["send:abortMainAgent"] }

        #expect(client.commands.contains { $0.type == .abort } == false)
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
        try await waitUntil { manager.latestAgentSessionSummary == "빠른 답변" && manager.voiceState == .responding }

        #expect(speechProvider.spokenUtterances.isEmpty)

        manager.updateVoicePresentation(
            isKeyboardRecording: false,
            isMicrophoneRecording: false,
            isFinalizing: false,
            isPreparing: false
        )
        try await waitUntil { speechProvider.spokenUtterances == ["빠른 답변"] }

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

    // MARK: - voiceState lifecycle (safety-net regressions)
    //
    // These pin down the rule that the cursor response bubble ("voiceState ==
    // .responding" + non-empty `latestAgentSessionSummary`) must always clear
    // when the underlying interaction projection is no longer speaking — even
    // if the projection moves through a non-`.idle` intermediate state.

    @Test func pickleCompletionReplyDrivesSpeakingProjectionAndClearsViaSpeechFinish() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "session-pickle",
            text: "피클 작업이 완료됐어요.",
            originSource: .system,
            replyKind: .pickleCompletion,
            sessionId: "session-pickle"
        )))
        try await waitUntil { manager.voiceState == .responding }

        #expect(manager.latestAgentSessionSummary == "피클 작업이 완료됐어요.")
        #expect(speechProvider.spokenUtterances == ["피클 작업이 완료됐어요."])

        // Wait past the minimum-display window so .speechFinished routes
        // straight to .idle, and let the FakeSpeechProvider close cleanly.
        try await Task.sleep(nanoseconds: 400_000_000)
        speechProvider.finishSpeaking()
        try await waitUntil { manager.voiceState == .idle }
    }

    @Test func pickleCompletionPreemptedByMainTextReplyClearsVoiceStateViaSafetyNet() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        // Pickle completion → speaking, voiceState = .responding.
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "session-pickle",
            text: "피클 답변",
            originSource: .system,
            replyKind: .pickleCompletion,
            sessionId: "session-pickle"
        )))
        try await waitUntil { manager.voiceState == .responding }

        // Before TTS finishes, a system-originated `.main` reply arrives that
        // routes to `.showingTextReply`. Without the safety net + reducer
        // preemption fix, the cursor bubble would stay stuck on the Pickle reply
        // until the user manually triggers another voice interaction.
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-typed",
            text: "추가 안내",
            originSource: .system,
            replyKind: .main
        )))
        try await waitUntil { manager.voiceState == .idle }
    }

    @Test func quickInputWithScreenContextTargetSendsSteerWithContextAndClearsTarget() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/shot-1.jpg")])
        )

        let didSend = await manager.sendDirectMessage("표시한 부분 봐줘", source: .quickInput)
        try await settle()

        #expect(didSend)
        #expect(client.submissions.isEmpty)
        let command = try #require(client.commands.first)
        #expect(command.type == .steer)
        #expect(command.sessionId == "pickle-target")
        #expect(command.text == "표시한 부분 봐줘")
        #expect(command.context?.source == "text-follow-up")
        #expect(command.context?.transcript == "표시한 부분 봐줘")
        #expect(command.context?.screenshots.map(\.path) == ["/tmp/picky/shot-1.jpg"])
        #expect(command.context?.warnings == [])
        #expect(selection.screenContextTargetSessionID == nil)
    }

    @Test func voiceReplyPreemptedByQuickInputSubmissionClearsVoiceStateViaSafetyNet() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator()
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "session-pickle",
            text: "답변 중",
            originSource: .system,
            replyKind: .pickleCompletion,
            sessionId: "session-pickle"
        )))
        try await waitUntil { manager.voiceState == .responding }

        // Quick-input message preempts the speaking output → waitingForAgent.
        async let success = manager.sendDirectMessage("추가 요청", source: .quickInput)
        try await waitUntil { manager.voiceState != .responding }

        // .waitingForAgent + isWaitingForCursorResponse routes voiceState to
        // .processing, but more importantly it must NOT remain .responding.
        let didSend = await success
        #expect(didSend)
        #expect(manager.voiceState != .responding)
    }

    @Test func pickleCompletionStaysRespondingWhileTtsIsActive() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "session-pickle",
            text: "긴 답변 진행 중",
            originSource: .system,
            replyKind: .pickleCompletion,
            sessionId: "session-pickle"
        )))
        try await waitUntil { manager.voiceState == .responding }

        // The minimum-display timer fires, producing another projection update
        // with state.output still .speaking (timerID cleared, no finishPending).
        // The safety net must NOT mistake this for a stuck-state and clear
        // voiceState — projection.isSpeaking is still true.
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(manager.voiceState == .responding)
        #expect(speechProvider.isSpeaking)
    }

    @Test func interactionSpeechWatchdogClearsRespondingWhenProviderNeverFinishes() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider,
            speechWatchdogTimeout: 0.05
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-cli",
            text: "답변은 도착했지만 TTS 완료 콜백이 유실된 상황",
            originSource: .cli,
            replyKind: .main
        )))
        try await waitUntil { manager.voiceState == .responding }
        #expect(speechProvider.isSpeaking)

        try await waitUntil { manager.voiceState == .idle }
        #expect(!speechProvider.isSpeaking)
    }

    @Test func interactionSpeechStartFailureClearsRespondingState() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.shouldStartSpeaking = false
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-cli",
            text: "TTS 시작 실패 상황",
            originSource: .cli,
            replyKind: .main
        )))

        try await waitUntil { manager.voiceState == .idle }
        #expect(!speechProvider.isSpeaking)
    }

    @Test func systemSpeechProviderRefusesBlankTextWithoutStickingSpeakingState() async throws {
        let synthesizer = FakeNSSpeechSynthesizer()
        let provider = PickySystemSpeechPlaybackProvider(speechSynthesizer: synthesizer)
        var finishCalls = 0

        let started = provider.speak(" \n\t ") { _ in finishCalls += 1 }

        #expect(!started)
        #expect(!provider.isSpeaking)
        #expect(synthesizer.spokenStrings.isEmpty)
        #expect(finishCalls == 0)
    }

    @Test func systemSpeechProviderReturnsFalseWhenImmediateStartSpeakingFails() async throws {
        let synthesizer = FakeNSSpeechSynthesizer()
        synthesizer.startSpeakingResult = false
        let provider = PickySystemSpeechPlaybackProvider(speechSynthesizer: synthesizer, prerollDelay: 0)
        var finishCalls = 0

        let started = provider.speak("엔진이 시작을 거부한 상황") { _ in finishCalls += 1 }

        #expect(!started)
        #expect(!provider.isSpeaking)
        #expect(synthesizer.spokenStrings.count == 1)
        #expect(finishCalls == 1)
    }

    @Test func systemSpeechProviderIgnoresStaleDelegateCallbacksAfterStop() async throws {
        let synthesizer = FakeNSSpeechSynthesizer()
        let provider = PickySystemSpeechPlaybackProvider(speechSynthesizer: synthesizer, prerollDelay: 0)
        var finishes: [Bool] = []

        #expect(provider.speak("첫 번째 발화") { finishes.append($0) })
        provider.stopSpeaking()

        provider.handleDelegateFinish(speechID: UUID(), didFinish: true)
        #expect(!provider.isSpeaking)
        #expect(finishes.isEmpty)
    }

    @Test func systemSpeechPathIsNotClippedBySafetyNetWhenInteractionSpeechIDIsNil() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        // `handleAgentSubmissionAccepted` for the legacy receipt path drives the
        // non-interaction `speakSystemMessage` flow. interactionSpeechID stays
        // nil so the safety net must skip the cleanup, otherwise the spoken
        // status message gets clipped the moment any unrelated projection fires.
        manager.beginAwaitingAgentResponse()
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "created-session", message: "안내 메시지"),
            source: "voice"
        )
        #expect(manager.voiceState == .responding)

        // Drive an unrelated reducer event so the interaction projection ticks.
        manager.applyAgentEvent(.sessionUpdated(PickyAgentSession(
            id: "unrelated",
            title: "Unrelated",
            status: .running,
            cwd: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            lastSummary: "chugging along",
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )))
        try await settle()

        // Still responding because the speak came from the system path, not
        // through the interaction coordinator's .speaking output.
        #expect(manager.voiceState == .responding)
        #expect(speechProvider.spokenUtterances == ["안내 메시지"])

        // When the system speech finishes, voiceState must clear normally.
        speechProvider.finishSpeaking()
        try await waitUntil { manager.voiceState == .idle }
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

    @Test func speechSanitizerNeutralizesInlinePathsAndUrls() async throws {
        let pathHeavy = "pi-extension 분석은 ~/Documents/pi-extension, agent 분석은 ~/.pi/agent, product 분석은 ~/product 에서 돌렸어요."
        #expect(stripParentheticalsForSpeech(pathHeavy) == "pi-extension 분석은 해당 경로, agent 분석은 해당 경로, product 분석은 해당 경로에서 돌렸어요.")

        let withURL = "결과는 https://example.com/report/123 에 있어요."
        #expect(stripParentheticalsForSpeech(withURL) == "결과는 링크에 있어요.")
    }

    @Test func stripParentheticalsFallsBackWhenWholeMessageIsParenthesised() async throws {
        let allParens = "(seed bootstrap rules)"
        #expect(stripParentheticalsForSpeech(allParens) == allParens)
    }

    private func fakeContextCaptureCoordinator(screenshots: [PickyScreenshotContext] = []) -> PickyVoiceContextCaptureCoordinator {
        PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _ in [] },
            contextAssembler: { _, source, transcript, _ in
                PickyContextPacket(
                    id: "typed-context",
                    source: source,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    transcript: transcript,
                    selectedText: nil,
                    cwd: "/tmp/project",
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    screenshots: screenshots,
                    warnings: []
                )
            }
        )
    }

    private func screenshot(path: String) -> PickyScreenshotContext {
        PickyScreenshotContext(
            id: "shot-1",
            label: "Display 1",
            path: path,
            screenId: "screen1",
            bounds: nil
        )
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

    /// Polls `predicate` up to one second so timing-sensitive expectations stay
    /// stable when the test runner is under heavy parallel load. Records a
    /// regular `#expect` failure if the predicate never holds within the
    /// budget so debugging output points at the actual mismatch.
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<50 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(predicate())
    }

    // MARK: - Lifecycle ownership

    @Test func stopDisconnectsAgentClientByDefault() async {
        // Default `ownsAgentClientLifecycle == true`: the manager treats the
        // agentClient as its own and is responsible for shutting it down.
        // This is the existing behavior for tests and headless harnesses
        // that pass in their own fake client.
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())
        manager.stop()
        #expect(client.disconnectCalls == 1)
    }

    @Test func stopDoesNotDisconnectSharedAgentClient() async {
        // When `ownsAgentClientLifecycle == false` the agentClient is
        // shared with another owner (in production the HUD owns the
        // router). Calling `disconnect` from here would tear down the
        // primary daemon socket AND every cached child connection out
        // from under the HUD viewModel, so the manager must leave
        // lifecycle to the actual owner.
        let client = FakeVoiceClient()
        let manager = CompanionManager(
            agentClient: client,
            ownsAgentClientLifecycle: false,
            selectionStore: FakeVoiceSelectionStore()
        )
        manager.stop()
        #expect(client.disconnectCalls == 0)
    }
}
