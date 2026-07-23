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
    private var _sendAwaitingErrorResult: PickyErrorEvent?
    var submissions: [PickyAgentSubmission] { lock.withLock { _submissions } }
    var commands: [PickyCommandEnvelope] { lock.withLock { _commands } }
    var calls: [String] { lock.withLock { _calls } }
    var disconnectCalls: Int { lock.withLock { _disconnectCalls } }
    var sendAwaitingErrorResult: PickyErrorEvent? {
        get { lock.withLock { _sendAwaitingErrorResult } }
        set { lock.withLock { _sendAwaitingErrorResult = newValue } }
    }

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
    func sendAwaitingError(_ command: PickyCommandEnvelope, timeout: TimeInterval) async throws -> PickyErrorEvent? {
        try await send(command)
        return lock.withLock { _sendAwaitingErrorResult }
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
    var screenContextTargetSticky: Bool = false

    func setScreenContextTarget(sessionID: String?, sticky: Bool) {
        screenContextTargetSessionID = sessionID
        screenContextTargetSticky = sessionID == nil ? false : sticky
    }
}

@MainActor
private final class FakeSpeechPlaybackProvider: PickySpeechPlaybackProvider {
    let displayName = "Fake Speech"
    var supportsIncrementalPlayback = false
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

private enum FakeTranscriptionProviderError: Error {
    case unsupported
}

private final class FakeTranscriptionProvider: BuddyTranscriptionProvider {
    let displayName = "Fake Transcription"
    let requiresSpeechRecognitionPermission = false
    let isConfigured = true
    let unavailableExplanation: String? = nil

    func startStreamingSession(
        keyterms: [String],
        onTranscriptUpdate: @escaping (String) -> Void,
        onFinalTranscriptReady: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void
    ) async throws -> any BuddyStreamingTranscriptionSession {
        throw FakeTranscriptionProviderError.unsupported
    }
}

@MainActor
private final class FakeVoiceProviderFactory {
    private(set) var transcriptionSettings: [PickySettings] = []
    private(set) var speechSettings: [PickySettings] = []
    private(set) var speechProviders: [FakeSpeechPlaybackProvider] = []

    func makeTranscriptionProvider(settings: PickySettings) -> any BuddyTranscriptionProvider {
        transcriptionSettings.append(settings)
        return FakeTranscriptionProvider()
    }

    func makeSpeechPlaybackProvider(settings: PickySettings) -> any PickySpeechPlaybackProvider {
        speechSettings.append(settings)
        let provider = FakeSpeechPlaybackProvider()
        speechProviders.append(provider)
        return provider
    }
}

@MainActor
private final class FakeInteractionTimerScheduler: PickyInteractionTimerScheduling {
    private struct ScheduledOperation {
        let delay: TimeInterval
        let operation: @MainActor () -> Void
    }

    private var scheduledOperations: [ScheduledOperation] = []
    var scheduledDelays: [TimeInterval] { scheduledOperations.map(\.delay) }
    var pendingOperationCount: Int { scheduledOperations.count }

    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        scheduledOperations.append(ScheduledOperation(delay: delay, operation: operation))
    }

    func fireNext() {
        scheduledOperations.removeFirst().operation()
    }

    func fireAll() {
        while !scheduledOperations.isEmpty {
            fireNext()
        }
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

    @Test func voiceTranscriptWithScreenContextTargetSendsFollowUpAndClearsTargetByDefault() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-session"
        let manager = CompanionManager(agentClient: client, selectionStore: selection, armedPickleDispatchMode: .followUp)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "pickle delta", contextPacket: context, voiceFollowUpSessionID: "pickle-session")

        #expect(receipt.sessionID == "pickle-session")
        #expect(client.commands.first?.type == .followUp)
        #expect(client.commands.first?.sessionId == "pickle-session")
        #expect(client.commands.first?.text == "pickle delta")
        #expect(client.commands.first?.context?.id == "context-voice")
        #expect(client.commands.first?.visualDslEnabled == false)
        #expect(client.submissions.isEmpty)
        #expect(selection.screenContextTargetSessionID == nil)
    }

    @Test func voiceTranscriptWithScreenContextTargetSendsSteerWhenConfigured() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-session"
        let manager = CompanionManager(agentClient: client, selectionStore: selection, armedPickleDispatchMode: .steer)
        let context = context(source: "voice-follow-up")

        let receipt = try await manager.routeVoiceTranscript(transcript: "pickle delta", contextPacket: context, voiceFollowUpSessionID: "pickle-session")

        #expect(receipt.sessionID == "pickle-session")
        #expect(client.commands.first?.type == .steer)
        #expect(client.commands.first?.sessionId == "pickle-session")
        #expect(client.commands.first?.text == "pickle delta")
        #expect(client.commands.first?.context?.id == "context-voice")
        #expect(client.commands.first?.visualDslEnabled == false)
        #expect(client.submissions.isEmpty)
        #expect(selection.screenContextTargetSessionID == nil)
    }

    @Test func productionPTTWithScreenContextTargetSendsFollowUpWhenConfigured() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/ptt-follow-up.jpg")]),
            armedPickleDispatchMode: .followUp
        )

        manager.handleShortcutTransition(.pressed)
        manager.submitTranscriptToPickyAgent(transcript: "계속 진행해줘")

        try await waitUntil { client.commands.contains { $0.sessionId == "pickle-target" } }
        let command = try #require(client.commands.first { $0.sessionId == "pickle-target" })
        #expect(command.type == .followUp)
        #expect(command.text == "계속 진행해줘")
        #expect(command.visualDslEnabled == true)
        manager.stop()
    }

    @Test func productionPTTWithScreenContextTargetSendsSteerWhenConfigured() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/ptt-steer.jpg")]),
            armedPickleDispatchMode: .steer
        )

        manager.handleShortcutTransition(.pressed)
        manager.submitTranscriptToPickyAgent(transcript: "방향을 바꿔줘")

        try await waitUntil { client.commands.contains { $0.sessionId == "pickle-target" } }
        let command = try #require(client.commands.first { $0.sessionId == "pickle-target" })
        #expect(command.type == .steer)
        #expect(command.text == "방향을 바꿔줘")
        #expect(command.visualDslEnabled == true)
        manager.stop()
    }

    @Test func productionPTTWithoutScreenContextTargetKeepsFollowUpDispatch() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.hoveredVoiceFollowUpSessionID = "pickle-hovered"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(),
            armedPickleDispatchMode: .steer
        )

        manager.handleShortcutTransition(.pressed)
        manager.submitTranscriptToPickyAgent(transcript: "일반 후속 질문")

        try await waitUntil { client.commands.contains { $0.sessionId == "pickle-hovered" } }
        let command = try #require(client.commands.first { $0.sessionId == "pickle-hovered" })
        #expect(command.type == .followUp)
        #expect(command.text == "일반 후속 질문")
        manager.stop()
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

    @Test func recognizedVoiceFollowUpReceiptKeepsPromptVisibleUntilMinimumDisplayDuration() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse(recognizedTranscript: "중복되는 느낌이야")

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "session-selected", message: ""),
            source: "voice-follow-up"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.voicePromptBubbleState == .recognized("중복되는 느낌이야"))
        #expect(manager.latestAgentSessionSummary == L10n.t("agent.summary.preparingResponse"))

        try await waitUntil {
            manager.voiceState == .idle
                && manager.voicePromptBubbleState == .hidden
                && manager.latestAgentSessionSummary == L10n.t("directMessage.steerDelivered")
        }

        #expect(manager.voiceState == .idle)
        #expect(manager.voicePromptBubbleState == .hidden)
        #expect(manager.latestAgentSessionSummary == L10n.t("directMessage.steerDelivered"))
    }

    @Test func recognizedVoiceSteerReceiptKeepsPromptVisibleUntilMinimumDisplayDuration() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.beginAwaitingAgentResponse(recognizedTranscript: "방향 바꿔줘")

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "session-selected", message: ""),
            source: "voice-steer"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.voicePromptBubbleState == .recognized("방향 바꿔줘"))
        #expect(manager.latestAgentSessionSummary == L10n.t("agent.summary.preparingResponse"))

        try await waitUntil {
            manager.voiceState == .idle
                && manager.voicePromptBubbleState == .hidden
                && manager.latestAgentSessionSummary == L10n.t("directMessage.steerDelivered")
        }

        #expect(manager.voiceState == .idle)
        #expect(manager.voicePromptBubbleState == .hidden)
        #expect(manager.latestAgentSessionSummary == L10n.t("directMessage.steerDelivered"))
    }

    @Test func terminalUpdateCancelsDeferredVoiceFollowUpReceiptAfterTargetWasCleared() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-race")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "중복되는 느낌이야")

        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "pickle-race", message: ""),
            source: "voice-follow-up"
        )
        // Mirrors `finishVoiceSubmissionIfIdle`: the send task releases the
        // utterance-scoped target before the Pickle terminal event can arrive.
        manager.setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "test-target-cleared-after-send")

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-race", status: .cancelled)))
        #expect(manager.latestAgentSessionSummary == "Pickle · cancelled")

        // Wait past the deferred-receipt window to prove the cancelled
        // deferral never fires and overwrites the terminal summary.
        try await sleepPast(CompanionManager.minimumVoiceProcessingDisplayDuration)

        #expect(manager.voiceState == .idle)
        #expect(manager.voicePromptBubbleState == .hidden)
        #expect(manager.latestAgentSessionSummary == "Pickle · cancelled")
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

    @Test func systemSpeechProviderSuppressesRealAudioDuringUnitTests() async throws {
        let provider = PickySystemSpeechPlaybackProvider(prerollDelay: 0, suppressedPlaybackDuration: 0.01)
        var finishes: [Bool] = []

        #expect(provider.speak("기존 응답") { finishes.append($0) })
        #expect(provider.isSpeaking)

        try await waitUntil { finishes == [true] }
        #expect(!provider.isSpeaking)
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

    @Test func successfulMainTurnCancelSettlesWaitingCursorProjection() async throws {
        let client = FakeVoiceClient()
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())

        manager.noteExternalSubmission(kind: .submitMain, text: "cancel this", context: context(source: "cli"))
        try await waitUntil { manager.isWaitingForCursorResponse }

        let didCancel = await manager.cancelMainTurn()
        #expect(didCancel)
        try await waitUntil { !manager.isWaitingForCursorResponse }
        #expect(client.commands.map(\.type) == [.abortMainAgent])
    }

    @Test func rejectedMainTurnCancelKeepsWaitingProjectionForRetry() async throws {
        let client = FakeVoiceClient()
        client.sendAwaitingErrorResult = PickyErrorEvent(
            code: "disconnected",
            message: "picky-agentd disconnected",
            commandId: nil
        )
        let manager = CompanionManager(agentClient: client, selectionStore: FakeVoiceSelectionStore())

        manager.noteExternalSubmission(kind: .submitMain, text: "cancel this", context: context(source: "cli"))
        try await waitUntil { manager.isWaitingForCursorResponse }

        let didCancel = await manager.cancelMainTurn()
        #expect(!didCancel)
        #expect(manager.isWaitingForCursorResponse)
        #expect(client.commands.map(\.type) == [.abortMainAgent])
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

    @Test func incrementalNarrationQueuesSentencesAndDoesNotRepeatFinalReply() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
            contextId: "stream-context",
            text: "첫 문장.",
            originSource: .voice,
            replyKind: .main,
            sessionId: nil
        )))
        manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
            contextId: "stream-context",
            text: "둘째 문장.",
            originSource: .voice,
            replyKind: .main,
            sessionId: nil
        )))
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "stream-context",
            text: "첫 문장. 둘째 문장.",
            originSource: .voice,
            replyKind: .main,
            didStreamNarration: true
        )))
        try await waitUntil { speechProvider.spokenUtterances == ["첫 문장."] }
        let stopCountBeforeQueuedSentenceStarts = speechProvider.stopCount

        speechProvider.finishSpeaking()
        try await waitUntil { speechProvider.spokenUtterances == ["첫 문장.", "둘째 문장."] }
        // A normal queued transition must not issue an explicit stop: remote
        // providers use that stop boundary to clear their prefetched audio.
        #expect(speechProvider.stopCount == stopCountBeforeQueuedSentenceStarts)
        manager.interruptSpokenResponseForVoiceInput()
        #expect(speechProvider.stopCount > 0)
        speechProvider.finishSpeaking()
        try await settle()
        #expect(speechProvider.spokenUtterances == ["첫 문장.", "둘째 문장."])
    }

    @Test func incrementalNarrationSkipsStandaloneParentheticalURLChunk() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        let parentheticalURL = "(https://aws.amazon.com/ec2/pricing/on-demand/)"

        manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
            contextId: "parenthetical-url-context",
            text: parentheticalURL,
            originSource: .voice,
            replyKind: .main,
            sessionId: nil
        )))
        try await waitUntil { manager.latestAgentSessionSummary == parentheticalURL }

        #expect(speechProvider.spokenUtterances.isEmpty)
        manager.stop()
    }

    @Test func unsupportedIncrementalProviderFallsBackToFinalQuickReply() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )

        manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
            contextId: "fallback-context",
            text: "먼저 도착한 문장.",
            originSource: .voice,
            replyKind: .main,
            sessionId: nil
        )))
        try await waitUntil {
            manager.latestAgentSessionSummary == "먼저 도착한 문장."
                && manager.isProgressiveResponseVisible
        }

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "fallback-context",
            text: "최종 응답입니다.",
            originSource: .voice,
            replyKind: .main,
            didStreamNarration: true
        )))

        try await waitUntil { speechProvider.spokenUtterances == ["최종 응답입니다."] }
    }

    @Test func nonIncrementalVisualNarrationShowsSentencesProgressivelyAndSpeaksFinalReplyOnce() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        let identity = visualNarrationIdentity(segmentID: "segment-final", ordinal: 0)

        manager.applyAgentEvent(.mainVisualNarrationSegmentPrepared(
            PickyVisualNarrationSegmentPreparedEvent(
                identity: identity,
                visual: .point(visualNarrationPointRequest(id: "point-final"))
            )
        ))
        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: identity,
                index: 0,
                text: "첫 문장.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        try await waitUntil {
            manager.latestAgentSessionSummary == "첫 문장."
                && manager.hasActiveVisualNarration
                && manager.isProgressiveResponseVisible
        }

        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: identity,
                index: 1,
                text: "둘째 문장.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        try await waitUntil { manager.latestAgentSessionSummary == "첫 문장. 둘째 문장." }
        #expect(speechProvider.spokenUtterances.isEmpty)

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: identity.contextId,
            text: "첫 문장. 둘째 문장.",
            originSource: .voice,
            replyKind: .main,
            didStreamNarration: true
        )))
        try await waitUntil {
            speechProvider.spokenUtterances == ["첫 문장. 둘째 문장."]
                && !manager.hasActiveVisualNarration
                && !manager.isProgressiveResponseVisible
        }
    }

    @Test func daemonErrorClearsResidentVisualNarrationAndProgressiveBubble() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        let identity = visualNarrationIdentity(segmentID: "segment-error", ordinal: 0)

        manager.applyAgentEvent(.mainVisualNarrationSegmentPrepared(
            PickyVisualNarrationSegmentPreparedEvent(
                identity: identity,
                visual: .point(visualNarrationPointRequest(id: "point-error"))
            )
        ))
        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: identity,
                index: 0,
                text: "진행 중 문장.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        try await waitUntil {
            manager.hasActiveVisualNarration && manager.isProgressiveResponseVisible
        }

        // A terminal protocol error mid-response must clear the resident visual turn
        // and progressive bubble instead of leaving them stuck until the next reply.
        manager.applyAgentEvent(.error(PickyErrorEvent(code: "stream_failed", message: "agent stream failed", commandId: nil)))

        try await waitUntil {
            !manager.hasActiveVisualNarration
                && !manager.isProgressiveResponseVisible
                && manager.agentAnnotations.isEmpty
        }
    }

    @Test func incrementalVisualNarrationKeepsFutureSegmentBufferedUntilItsSpeechStarts() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        let first = visualNarrationIdentity(segmentID: "segment-a", ordinal: 0)
        let second = visualNarrationIdentity(segmentID: "segment-b", ordinal: 1)

        for (identity, pointID) in [(first, "point-a"), (second, "point-b")] {
            manager.applyAgentEvent(.mainVisualNarrationSegmentPrepared(
                PickyVisualNarrationSegmentPreparedEvent(
                    identity: identity,
                    visual: .point(visualNarrationPointRequest(id: pointID))
                )
            ))
        }
        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: first,
                index: 0,
                text: "A 설명.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        try await waitUntil {
            speechProvider.spokenUtterances == ["A 설명."]
                && manager.latestAgentSessionSummary == "A 설명."
        }

        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: second,
                index: 0,
                text: "B 설명.",
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )
        ))
        try await settle()
        #expect(manager.latestAgentSessionSummary == "A 설명.")

        speechProvider.finishSpeaking()
        try await waitUntil {
            speechProvider.spokenUtterances == ["A 설명.", "B 설명."]
                && manager.latestAgentSessionSummary == "B 설명."
        }
    }

    @Test func incrementalPickleVisualNarrationSpeaksAndRevealsItsAnnotationTogether() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider
        )
        let identity = visualNarrationIdentity(segmentID: "pickle-segment", ordinal: 0)

        manager.applyAgentEvent(.mainVisualNarrationSegmentPrepared(
            PickyVisualNarrationSegmentPreparedEvent(
                identity: identity,
                visual: .annotations(annotationRequest(
                    id: "pickle-rect",
                    mode: .append,
                    contextID: identity.contextId,
                    x: 20
                ))
            )
        ))
        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: identity,
                index: 0,
                text: "Pickle 설명입니다.",
                originSource: .voiceFollowUp,
                replyKind: .main,
                sessionId: "pickle-session"
            )
        ))

        try await waitUntil {
            speechProvider.spokenUtterances == ["Pickle 설명입니다."]
                && manager.latestAgentSessionSummary == "Pickle 설명입니다."
                && manager.agentAnnotations.map(\.id) == ["pickle-rect"]
        }
    }

    @Test func unsupportedIncrementalProviderKeepsAnnotationOffsetsForFinalReplyTTS() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        let timerScheduler = FakeInteractionTimerScheduler()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider,
            interactionTimerScheduler: timerScheduler
        )
        let contextID = "annotation-fallback-context"
        let narration = [
            "지금은 이벤트 상세의 하단입니다. 위쪽 요청 정보를 확인합니다.",
            "태그에서는 운영 환경과 실제 URL을 대조해 재현 범위를 좁힙니다.",
            "아래 Contexts는 실행 환경의 추가 단서를 확인하는 영역입니다.",
        ]

        for (index, text) in narration.enumerated() {
            manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
                contextId: contextID,
                text: text,
                originSource: .voice,
                replyKind: .main,
                sessionId: nil
            )))
            manager.applyAgentEvent(.annotationOverlayRequested(PickyAnnotationOverlayRequest(
                id: "annotations-\(index)",
                mode: .append,
                annotations: [PickyAnnotationOverlayAnnotation(
                    id: "rect-\(index)",
                    shape: .rect,
                    x: 10,
                    y: Double(10 + index * 30),
                    w: 100,
                    h: 20,
                    x1: nil,
                    y1: nil,
                    x2: nil,
                    y2: nil,
                    spotlight: nil,
                    label: "rect-\(index)",
                    clamped: nil
                )],
                contextId: contextID,
                contextGeneration: 1,
                screenId: "screen",
                screenBounds: PickyCGRect(x: 0, y: 0, width: 800, height: 600),
                screenshotSize: PickyPointerScreenshotSize(width: 800, height: 600)
            )))
        }

        let finalReply = narration.joined(separator: " ")
        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: contextID,
            text: finalReply,
            originSource: .voice,
            replyKind: .main,
            didStreamNarration: true
        )))

        try await waitUntil {
            speechProvider.spokenUtterances == [finalReply] && timerScheduler.scheduledDelays.count == 4
        }
        let revealDelays = Array(timerScheduler.scheduledDelays.suffix(3))
        guard revealDelays.count == 3 else {
            Issue.record("Expected three annotation reveal timers, got \(timerScheduler.scheduledDelays)")
            return
        }
        let expectedDelays = narration.indices.map { index in
            PickyNarrationPaceModel.speechPrerollSeconds
                + narration[0...index].reduce(0) {
                    $0 + PickyNarrationPaceModel.weightedUnits(forNarration: $1)
                } * PickyNarrationPaceModel.secondsPerWeightUnit
        }

        #expect(revealDelays.elementsEqual(expectedDelays, by: { abs($0 - $1) < 0.05 }))
        #expect(revealDelays[0] < revealDelays[1] && revealDelays[1] < revealDelays[2])
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
        try await sleepPast(PickyInteractionReducer.minimumDisplayDuration)
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

    @Test func quickInputWithScreenContextTargetSendsFollowUpWithContextAndClearsTargetByDefault() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            speechPlaybackProvider: speechProvider,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/shot-1.jpg")]),
            armedPickleDispatchMode: .followUp
        )

        let didSend = await manager.sendDirectMessage("표시한 부분 봐줘", source: .quickInput)
        try await settle()

        #expect(didSend)
        #expect(client.submissions.isEmpty)
        let command = try #require(client.commands.first)
        #expect(command.type == .followUp)
        #expect(command.sessionId == "pickle-target")
        #expect(command.text == "표시한 부분 봐줘")
        #expect(command.context?.source == "text-follow-up")
        #expect(command.context?.transcript == "표시한 부분 봐줘")
        #expect(command.context?.screenshots.map(\.path) == ["/tmp/picky/shot-1.jpg"])
        #expect(command.visualDslEnabled == true)
        #expect(command.context?.warnings == [])
        #expect(selection.screenContextTargetSessionID == nil)

        let context = try #require(command.context)
        let identity = PickyVisualNarrationSegmentIdentity(
            contextId: context.id,
            contextGeneration: 0,
            turnToken: "pickle-turn",
            segmentId: "pickle-text-segment",
            ordinal: 0
        )
        manager.applyAgentEvent(.mainVisualNarrationSegmentPrepared(
            PickyVisualNarrationSegmentPreparedEvent(
                identity: identity,
                visual: .annotations(annotationRequest(
                    id: "pickle-text-rect",
                    mode: .append,
                    contextID: context.id,
                    x: 20
                ))
            )
        ))
        manager.applyAgentEvent(.mainVisualNarrationSegmentSentence(
            PickyVisualNarrationSegmentSentenceEvent(
                identity: identity,
                index: 0,
                text: "Quick Input 설명입니다.",
                originSource: .textFollowUp,
                replyKind: .main,
                sessionId: "pickle-target"
            )
        ))

        try await waitUntil {
            speechProvider.spokenUtterances == ["Quick Input 설명입니다."]
                && manager.latestAgentSessionSummary == "Quick Input 설명입니다."
        }
    }

    @Test func quickInputWithScreenContextTargetSendsSteerWhenConfigured() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/shot-1.jpg")]),
            armedPickleDispatchMode: .steer
        )

        let didSend = await manager.sendDirectMessage("표시한 부분 봐줘", source: .quickInput)
        try await settle()

        #expect(didSend)
        let command = try #require(client.commands.first)
        #expect(command.type == .steer)
        #expect(command.sessionId == "pickle-target")
        #expect(command.context?.screenshots.map(\.path) == ["/tmp/picky/shot-1.jpg"])
        #expect(command.visualDslEnabled == true)
        #expect(selection.screenContextTargetSessionID == nil)
    }

    @Test func quickInputWithScreenContextTargetDoesNotEnableVisualDslWithoutScreenshots() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.screenContextTargetSessionID = "pickle-target"
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: []),
            armedPickleDispatchMode: .followUp
        )

        let didSend = await manager.sendDirectMessage("텍스트만 전달", source: .quickInput)
        try await settle()

        #expect(didSend)
        let command = try #require(client.commands.first)
        #expect(command.context?.screenshots.isEmpty == true)
        #expect(command.visualDslEnabled == false)
    }

    @Test func quickInputWithStickyScreenContextTargetKeepsTargetArmedAfterFollowUp() async throws {
        let client = FakeVoiceClient()
        let selection = FakeVoiceSelectionStore()
        selection.setScreenContextTarget(sessionID: "pickle-locked", sticky: true)
        let manager = CompanionManager(
            agentClient: client,
            selectionStore: selection,
            voiceContextCaptureCoordinator: fakeContextCaptureCoordinator(screenshots: [screenshot(path: "/tmp/picky/shot-locked.jpg")]),
            armedPickleDispatchMode: .followUp
        )

        let didSend = await manager.sendDirectMessage("잠긴 피클에 고정 입력", source: .quickInput)
        try await settle()

        #expect(didSend)
        let command = try #require(client.commands.first)
        #expect(command.type == .followUp)
        #expect(command.sessionId == "pickle-locked")
        // Sticky armed Pickles persist across dispatches so the user can
        // keep speaking/typing without re-arming after every input.
        #expect(selection.screenContextTargetSessionID == "pickle-locked")
        #expect(selection.screenContextTargetSticky == true)
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

    @Test func mainModelSettingsChangeDoesNotInterruptActiveReply() async throws {
        let settings = deterministicVoiceSettings()
        let providerFactory = FakeVoiceProviderFactory()
        let timerScheduler = FakeInteractionTimerScheduler()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            initialSettings: settings,
            transcriptionProviderFactory: { providerFactory.makeTranscriptionProvider(settings: $0) },
            speechPlaybackProviderFactory: { providerFactory.makeSpeechPlaybackProvider(settings: $0) },
            interactionTimerScheduler: timerScheduler
        )
        let speechProvider = try #require(providerFactory.speechProviders.first)

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-model-change",
            text: "모델 설정과 무관하게 계속 표시할 답변",
            originSource: .cli,
            replyKind: .main
        )))
        try await waitUntil { manager.voiceState == .responding && speechProvider.isSpeaking }
        let stopCountBeforeSettingsChange = speechProvider.stopCount

        var updatedSettings = settings
        updatedSettings.mainAgentModelPattern = "openai/gpt-model-change"
        manager.reloadVoiceProvidersFromSettings(updatedSettings)

        #expect(providerFactory.transcriptionSettings.count == 1)
        #expect(providerFactory.speechSettings.count == 1)
        #expect(providerFactory.speechProviders.count == 1)
        #expect(providerFactory.speechProviders.first === speechProvider)
        #expect(speechProvider.stopCount == stopCountBeforeSettingsChange)
        #expect(speechProvider.isSpeaking)
        #expect(manager.voiceState == .responding)
    }

    @Test func voiceSettingsChangeSettlesInterruptedReplyBeforeLaterProjection() async throws {
        let settings = deterministicVoiceSettings()
        let providerFactory = FakeVoiceProviderFactory()
        let timerScheduler = FakeInteractionTimerScheduler()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            initialSettings: settings,
            transcriptionProviderFactory: { providerFactory.makeTranscriptionProvider(settings: $0) },
            speechPlaybackProviderFactory: { providerFactory.makeSpeechPlaybackProvider(settings: $0) },
            interactionTimerScheduler: timerScheduler
        )
        let speechProvider = try #require(providerFactory.speechProviders.first)

        manager.applyAgentEvent(.quickReply(PickyQuickReplyEvent(
            contextId: "context-voice-change",
            text: "음성 설정 변경으로 중단될 답변",
            originSource: .cli,
            replyKind: .main
        )))
        try await waitUntil { manager.voiceState == .responding && speechProvider.isSpeaking }
        #expect(timerScheduler.scheduledDelays == [PickyInteractionReducer.minimumDisplayDuration])

        let sequenceBeforeTimer = manager.interactionProjectionSequence
        timerScheduler.fireNext()
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeTimer }
        #expect(timerScheduler.scheduledDelays.isEmpty)

        var updatedSettings = settings
        updatedSettings.ttsEnabled = false
        let sequenceBeforeReload = manager.interactionProjectionSequence
        manager.reloadVoiceProvidersFromSettings(updatedSettings)
        try await waitUntil {
            manager.interactionProjectionSequence > sequenceBeforeReload && manager.voiceState == .idle
        }

        #expect(providerFactory.transcriptionSettings == [settings, updatedSettings])
        #expect(providerFactory.speechSettings == [settings, updatedSettings])
        #expect(providerFactory.speechProviders.count == 2)
        #expect(!speechProvider.isSpeaking)

        let sequenceBeforePointer = manager.interactionProjectionSequence
        manager.applyAgentEvent(.pointerOverlayRequested(PickyPointerOverlayRequest(
            id: "pointer-after-voice-settings",
            contextId: "context-pointer",
            contextGeneration: nil,
            screenId: "screen-1",
            x: 20,
            y: 20,
            label: "Settings",
            clamped: nil,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 100, height: 100)
        )))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforePointer }

        #expect(manager.voiceState == .idle)
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
        try await sleepPast(PickyInteractionReducer.minimumDisplayDuration, margin: 0.15)
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

    // MARK: - sessionUpdated terminal status -> cursor cleanup (HUD abort regression)

    @Test func sessionUpdatedToCancelledReleasesCursorProcessingForAwaitedSession() async throws {
        // Repro for the HUD-abort bug: user hits abort on a Pickle that the cursor is
        // waiting on. agentd patches the session to .cancelled and emits sessionUpdated
        // (no quickReply ever lands). CompanionManager must detect the terminal transition
        // and release the cursor; otherwise voiceState stays at .processing (yellow).
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-aborted")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hello")
        #expect(manager.voiceState == .processing)

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-aborted", status: .cancelled)))

        #expect(manager.voiceState == .idle)
        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == nil)
        manager.stop()
    }

    @Test func sessionUpdatedToFailedReleasesCursorProcessingForAwaitedSession() async throws {
        // Same flow as cancelled, but exercises the .failed terminal status that
        // arrives when a runtime crash / unrecoverable error ends the session without
        // a quickReply.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-failed")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi")
        #expect(manager.voiceState == .processing)

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-failed", status: .failed)))

        #expect(manager.voiceState == .idle)
        manager.stop()
    }

    @Test func sessionUpdatedToCancelledForUnrelatedSessionDoesNotReleaseCursor() async throws {
        // The cursor is waiting on pickle-A; an unrelated pickle-B getting cancelled
        // must not yank the cursor out of .processing. Without sessionID matching this
        // would otherwise produce spurious clears whenever ANY background session
        // terminates.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-A")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi")
        #expect(manager.voiceState == .processing)

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-B", status: .cancelled)))

        #expect(manager.voiceState == .processing, "the cursor was waiting on pickle-A; pickle-B's terminal status must not touch it")
        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == "pickle-A")
        manager.stop()
    }

    @Test func sessionUpdatedToRunningDoesNotReleaseCursor() async throws {
        // Defensive regression: non-terminal status transitions must keep the cursor's
        // .processing state intact.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-running")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi")
        #expect(manager.voiceState == .processing)

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-running", status: .running)))
        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-running", status: .waiting_for_input)))
        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-running", status: .blocked)))

        #expect(manager.voiceState == .processing)
        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == "pickle-running")
        manager.stop()
    }

    @Test func sessionUpdatedToCancelledAfterPTTInterruptIsIdempotent() async throws {
        // PTT interrupt already cleared the cursor + voiceFollowUp before the
        // session-level abort reached agentd and bounced back as sessionUpdated.
        // The terminal transition must be a safe no-op (no exceptions, no second
        // mutation of voiceState that would clobber a fresh user input in progress).
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-race")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi")
        manager.interruptSpokenResponseForVoiceInput()
        try await waitUntil { manager.voiceState == .idle }

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-race", status: .cancelled)))

        #expect(manager.voiceState == .idle)
        manager.stop()
    }

    @Test func sessionUpdatedToCompletedDoesNotInterruptOngoingSpokenResponse() async throws {
        // Normal completion delivers a quickReply that already moves voiceState into
        // .responding (and clears the pending timing). A subsequent sessionUpdated
        // with .completed must NOT collapse that response back to .idle — the spoken
        // reply is mid-playback.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "pickle-1", message: "응답이 온 세션"),
            source: "voice"
        )
        #expect(manager.voiceState == .responding)

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-1", status: .completed)))

        #expect(manager.voiceState == .responding, "a late .completed sessionUpdated must not abort the in-flight spoken reply")
        manager.stop()
    }

    @Test func repeatedTerminalSessionUpdatedOnlyTriggersCleanupOnce() async throws {
        // agentd can re-emit sessionUpdated for the same session multiple times
        // (e.g. reconnect snapshot + live update). The cleanup must only happen on
        // the first transition into a terminal status; subsequent terminal updates
        // for the same session must be silent.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-replay")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi")

        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-replay", status: .cancelled)))
        try await waitUntil { manager.voiceState == .idle }

        // Start a NEW awaited turn on a different session; the duplicate terminal
        // sessionUpdated for the OLD session must not collapse the new cursor state.
        manager.setVoiceFollowUpSessionIDForCurrentUtterance("pickle-new")
        manager.beginAwaitingAgentResponse(recognizedTranscript: "hi again")
        #expect(manager.voiceState == .processing)
        manager.applyAgentEvent(.sessionUpdated(session(id: "pickle-replay", status: .cancelled)))

        #expect(manager.voiceState == .processing, "duplicate terminal sessionUpdated for the old session must be a no-op")
        #expect(manager.voiceFollowUpSessionIDForCurrentUtterance == "pickle-new")
        manager.stop()
    }

    @Test func speechSanitizerRemovesAsciiAndFullWidthParentheticals() async throws {
        let asciiInput = "배포는 완료됐어요 (https://example.com/run/123)."
        #expect(sanitizedTextForSpeech(asciiInput) == "배포는 완료됐어요.")

        let fullWidthInput = "세션 아이디는 잘 저장됐습니다（session-abc-123）."
        #expect(sanitizedTextForSpeech(fullWidthInput) == "세션 아이디는 잘 저장됐습니다.")

        let multipleInput = "PR (#123) 을 머지했고 (development 브랜치) 로 돌아갔어요."
        #expect(sanitizedTextForSpeech(multipleInput) == "PR 을 머지했고 로 돌아갔어요.")
    }

    @Test func speechSanitizerKeepsPlainText() async throws {
        let plain = "프로덕션으로 올린 명령을 몇 분 안에 모니터링해볼게요."
        #expect(sanitizedTextForSpeech(plain) == plain)
    }

    @Test func speechSanitizerNeutralizesInlinePathsAndUrls() async throws {
        let pathHeavy = "pi-extension 분석은 ~/Documents/pi-extension, agent 분석은 ~/.pi/agent, product 분석은 ~/product 에서 돌렸어요."
        #expect(sanitizedTextForSpeech(pathHeavy) == "pi-extension 분석은 해당 경로, agent 분석은 해당 경로, product 분석은 해당 경로에서 돌렸어요.")

        let withURL = "결과는 https://example.com/report/123 에 있어요."
        #expect(sanitizedTextForSpeech(withURL) == "결과는 링크에 있어요.")
    }

    @Test func speechSanitizerReadsMarkdownTextWithoutInlineSyntax() {
        let markdown = "**회원 상세모달**에서 [설명 문서](https://example.com/guide)와 ![구조도](diagram.png)를 확인합니다."
        #expect(sanitizedTextForSpeech(markdown) == "회원 상세모달에서 설명 문서와 구조도를 확인합니다.")
    }

    @Test func speechSanitizerRemovesMarkdownBlockMarkersButKeepsTextOrder() {
        let markdown = """
        # 핵심 흐름
        - **첫 번째** 단계
        1. [두 번째 단계](https://example.com/two)
        > 마지막 참고
        """
        #expect(sanitizedTextForSpeech(markdown) == "핵심 흐름 첫 번째 단계 두 번째 단계 마지막 참고")
    }

    @Test func speechSanitizerSkipsFencedCodeButReadsInlineCode() {
        let markdown = """
        설정은 `visualDslEnabled`입니다.
        ```swift
        print("**읽지 않음**")
        ```
        이제 완료됐습니다.
        """
        #expect(sanitizedTextForSpeech(markdown) == "설정은 visualDslEnabled입니다. 이제 완료됐습니다.")
    }

    @Test func speechSanitizerDropsStandaloneParentheticalURL() async throws {
        let parentheticalURL = "(https://aws.amazon.com/ec2/pricing/on-demand/)"
        #expect(sanitizedTextForSpeech(parentheticalURL).isEmpty)
    }

    // MARK: - Interaction orchestration

    @Test func mainTurnSettledClearsOnlyMatchingWaitingTurnAndIsIdempotent() async throws {
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            initialSettings: deterministicVoiceSettings()
        )
        let context = context(source: "cli")

        manager.noteExternalSubmission(kind: .submitMain, text: "silent overlay turn", context: context)
        try await waitUntil { manager.isWaitingForCursorResponse }
        manager.beginAwaitingAgentResponse(recognizedTranscript: "show the setting")
        manager.handleAgentSubmissionAccepted(
            receipt: PickyAgentSubmissionReceipt(sessionID: "deferred-settle-session", message: ""),
            source: "voice-follow-up"
        )

        #expect(manager.voiceState == .processing)
        #expect(manager.voicePromptBubbleState == .recognized("show the setting"))
        #expect(manager.isWaitingForCursorResponse)

        let sequenceBeforeUnrelatedSettle = manager.interactionProjectionSequence
        manager.applyAgentEvent(.mainTurnSettled(contextId: "unrelated-context"))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeUnrelatedSettle }

        #expect(manager.voiceState == .processing)
        #expect(manager.voicePromptBubbleState == .recognized("show the setting"))
        #expect(manager.isWaitingForCursorResponse)

        manager.applyAgentEvent(.mainTurnSettled(contextId: context.id))
        try await waitUntil {
            manager.voiceState == .idle
                && manager.voicePromptBubbleState == .hidden
                && !manager.isWaitingForCursorResponse
        }

        let settledVoiceState = manager.voiceState
        let settledPromptBubbleState = manager.voicePromptBubbleState
        let settledWaitingProjection = manager.isWaitingForCursorResponse
        let sequenceBeforeDuplicateSettle = manager.interactionProjectionSequence
        manager.applyAgentEvent(.mainTurnSettled(contextId: context.id))
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeDuplicateSettle }

        #expect(manager.voiceState == settledVoiceState)
        #expect(manager.voicePromptBubbleState == settledPromptBubbleState)
        #expect(manager.isWaitingForCursorResponse == settledWaitingProjection)

        try await sleepPast(CompanionManager.minimumVoiceProcessingDisplayDuration)
        #expect(manager.latestAgentSessionSummary == L10n.t("agent.summary.preparingResponse"))
    }

    @Test func annotationPointerParkAppendAndSettleUpdatesOnlyCurrentPointer() async throws {
        let speechProvider = FakeSpeechPlaybackProvider()
        speechProvider.supportsIncrementalPlayback = true
        let timerScheduler = FakeInteractionTimerScheduler()
        let manager = CompanionManager(
            agentClient: FakeVoiceClient(),
            selectionStore: FakeVoiceSelectionStore(),
            speechPlaybackProvider: speechProvider,
            initialSettings: deterministicVoiceSettings(),
            interactionTimerScheduler: timerScheduler
        )
        let contextID = "annotation-pointer-context"

        manager.applyAgentEvent(.mainNarrationChunk(PickyMainNarrationChunkEvent(
            contextId: contextID,
            text: "First annotation is visible.",
            originSource: .voice,
            replyKind: .main,
            sessionId: nil
        )))
        try await waitUntil {
            speechProvider.spokenUtterances == ["First annotation is visible."]
                && timerScheduler.pendingOperationCount == 1
        }

        manager.applyAgentEvent(.annotationOverlayRequested(annotationRequest(
            id: "first",
            mode: .append,
            contextID: contextID,
            x: 20
        )))
        try await waitUntil { timerScheduler.pendingOperationCount == 2 }
        timerScheduler.fireAll()
        try await waitUntil { manager.detectedElementPointerID == "annotation-first" }

        let firstLocation = manager.detectedElementScreenLocation
        #expect(manager.detectedElementParksAtTarget)
        #expect(!manager.detectedElementReturnsToCursor)

        let sequenceBeforePark = manager.interactionProjectionSequence
        manager.parkPointerAnimation(pointerID: "annotation-first")
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforePark }

        manager.applyAgentEvent(.annotationOverlayRequested(annotationRequest(
            id: "second",
            mode: .append,
            contextID: contextID,
            x: 300
        )))
        try await waitUntil { timerScheduler.pendingOperationCount == 1 }
        timerScheduler.fireAll()
        try await waitUntil { manager.detectedElementPointerID == "annotation-second" }

        #expect(manager.detectedElementScreenLocation != firstLocation)
        #expect(manager.detectedElementParksAtTarget)
        #expect(!manager.detectedElementReturnsToCursor)

        manager.parkPointerAnimation(pointerID: "annotation-first")
        manager.advancePointerAnimation(pointerID: "annotation-first")
        #expect(manager.detectedElementPointerID == "annotation-second")
        #expect(manager.detectedElementParksAtTarget)

        let sequenceBeforeSpeechFinish = manager.interactionProjectionSequence
        speechProvider.finishSpeaking()
        try await waitUntil { manager.interactionProjectionSequence > sequenceBeforeSpeechFinish }

        manager.applyAgentEvent(.mainTurnSettled(contextId: contextID))
        try await waitUntil {
            manager.detectedElementPointerID == "annotation-second"
                && !manager.detectedElementParksAtTarget
                && manager.detectedElementReturnsToCursor
        }
    }

    // MARK: - External CLI submissions

    @Test func externalSubmitMainFlipsCursorIntoWaitingForAgent() async throws {
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.noteExternalSubmission(kind: .submitMain, text: "hello from cli", context: context(source: "cli"))

        try await waitUntil { manager.isWaitingForCursorResponse }
    }

    @Test func externalCreatePickleDoesNotFlipCursorIntoWaitingForAgent() async throws {
        // `picky pickle-create` delegates work to a Pickle: no main quickReply for the
        // captured contextID will arrive, so flipping into `.waitingForAgent` would park
        // the cursor on the yellow loading state for the whole Pickle run.
        let manager = CompanionManager(agentClient: FakeVoiceClient(), selectionStore: FakeVoiceSelectionStore())

        manager.noteExternalSubmission(kind: .createPickle, text: "", context: context(source: "cli"))

        // createPickle is rejected synchronously and schedules no timer, so a
        // settle() beat is enough for any stray coordinator hop to surface.
        try await settle()
        #expect(!manager.isWaitingForCursorResponse)
    }

    private func annotationRequest(
        id: String,
        mode: PickyAnnotationOverlayMode,
        contextID: String,
        x: Double
    ) -> PickyAnnotationOverlayRequest {
        PickyAnnotationOverlayRequest(
            id: "annotations-\(id)",
            mode: mode,
            annotations: [PickyAnnotationOverlayAnnotation(
                id: id,
                shape: .rect,
                x: x,
                y: 40,
                w: 100,
                h: 30,
                x1: nil,
                y1: nil,
                x2: nil,
                y2: nil,
                spotlight: nil,
                label: id,
                clamped: nil
            )],
            contextId: contextID,
            contextGeneration: 1,
            screenId: "screen",
            screenBounds: PickyCGRect(x: 0, y: 0, width: 800, height: 600),
            screenshotSize: PickyPointerScreenshotSize(width: 800, height: 600)
        )
    }

    private func fakeContextCaptureCoordinator(screenshots: [PickyScreenshotContext] = []) -> PickyVoiceContextCaptureCoordinator {
        PickyVoiceContextCaptureCoordinator(
            screenCapture: { _, _, _ in [] },
            contextPreflightCapture: {
                PickyContextPacketPreflight(
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    selectedText: nil,
                    warnings: []
                )
            },
            contextPreparer: { _, source, _, _ in
                PickyPreparedContextPacket(
                    id: "typed-context",
                    source: source,
                    capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    selectedText: nil,
                    cwd: "/tmp/project",
                    activeApp: nil,
                    activeWindow: nil,
                    browser: nil,
                    screenshots: screenshots,
                    inkMarks: [],
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

    private func visualNarrationIdentity(
        segmentID: String,
        ordinal: Int
    ) -> PickyVisualNarrationSegmentIdentity {
        PickyVisualNarrationSegmentIdentity(
            contextId: "visual-context",
            contextGeneration: 1,
            turnToken: "main-turn-1",
            segmentId: segmentID,
            ordinal: ordinal
        )
    }

    private func visualNarrationPointRequest(id: String) -> PickyPointerOverlayRequest {
        PickyPointerOverlayRequest(
            id: id,
            contextId: "visual-context",
            contextGeneration: 1,
            screenId: "screen-main",
            x: 30,
            y: 40,
            label: "target",
            clamped: nil,
            screenBounds: PickyCGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotSize: PickyPointerScreenshotSize(width: 100, height: 100)
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

    private func deterministicVoiceSettings() -> PickySettings {
        let appSupportRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-companion-manager-tests", isDirectory: true)
        return PickySettings.defaults(appSupportRoot: appSupportRoot, seedDefaultWorkspace: false)
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }

    /// Sleeps just past `interval` so production timers tuned to that constant
    /// have definitely fired (or, for negative checks, definitely had their
    /// chance to fire). Deriving the wait from the production constant keeps
    /// these tests valid if the constant is retuned.
    private func sleepPast(_ interval: TimeInterval, margin: TimeInterval = 0.1) async throws {
        try await Task.sleep(nanoseconds: UInt64((interval + margin) * 1_000_000_000))
    }

    private func session(id: String, status: PickySessionStatus) -> PickyAgentSession {
        PickyAgentSession(
            id: id,
            title: "Pickle",
            status: status,
            cwd: nil,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_001),
            lastSummary: nil,
            logs: [],
            tools: [],
            artifacts: [],
            changedFiles: []
        )
    }

    /// Polls `predicate` up to two seconds so timing-sensitive expectations stay
    /// stable when the test runner is under heavy parallel load. Records a
    /// regular `#expect` failure if the predicate never holds within the
    /// budget so debugging output points at the actual mismatch.
    private func waitUntil(_ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<100 {
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
