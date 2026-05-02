//
//  CompanionManager.swift
//  Picky
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AVFoundation
import Combine
import Foundation
import ScreenCaptureKit
import SwiftUI

enum CompanionVoiceState {
    case idle
    case listening
    case processing
    case responding
}

enum CompanionVoicePromptBubbleState: Equatable {
    case hidden
    case recognizing
    case recognized(String)

    var isVisible: Bool {
        self != .hidden
    }

    var displayText: String {
        switch self {
        case .hidden, .recognizing:
            return "음성 인식 중…"
        case .recognized(let prompt):
            return prompt
        }
    }
}

struct CompanionVoicePresentationState: Equatable {
    let voiceState: CompanionVoiceState
    let promptBubbleState: CompanionVoicePromptBubbleState
}

enum CompanionVoicePresentationReducer {
    static func reduce(
        currentVoiceState: CompanionVoiceState,
        isKeyboardRecording: Bool,
        isMicrophoneRecording: Bool,
        isFinalizingTranscript: Bool,
        isPreparingToRecord: Bool,
        isShortcutHeld: Bool,
        isAwaitingAgentResponse: Bool,
        recognizedPrompt: String?
    ) -> CompanionVoicePresentationState {
        let trimmedPrompt = recognizedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let promptBubbleState: CompanionVoicePromptBubbleState
        if isFinalizingTranscript {
            promptBubbleState = .recognizing
        } else if isAwaitingAgentResponse {
            promptBubbleState = trimmedPrompt.isEmpty ? .recognizing : .recognized(trimmedPrompt)
        } else {
            promptBubbleState = .hidden
        }

        if currentVoiceState == .responding {
            return CompanionVoicePresentationState(voiceState: .responding, promptBubbleState: .hidden)
        }
        if isShortcutHeld || isKeyboardRecording || isMicrophoneRecording {
            return CompanionVoicePresentationState(voiceState: .listening, promptBubbleState: promptBubbleState)
        }
        if isFinalizingTranscript || isPreparingToRecord {
            return CompanionVoicePresentationState(voiceState: .processing, promptBubbleState: promptBubbleState)
        }
        if isAwaitingAgentResponse {
            return CompanionVoicePresentationState(voiceState: .processing, promptBubbleState: promptBubbleState)
        }
        return CompanionVoicePresentationState(voiceState: .idle, promptBubbleState: .hidden)
    }
}

private final class PickySpeechSynthesizerDelegate: NSObject, NSSpeechSynthesizerDelegate {
    private let onFinish: (Bool) -> Void

    init(onFinish: @escaping (Bool) -> Void) {
        self.onFinish = onFinish
    }

    func speechSynthesizer(_ sender: NSSpeechSynthesizer, didFinishSpeaking finishedSpeaking: Bool) {
        onFinish(finishedSpeaking)
    }
}

enum PickySpeechPlaybackPreparation {
    /// Short pre-roll for macOS system speech. Some output devices need a tiny
    /// amount of generated audio time before the first audible phoneme; without
    /// it, the start of short TTS replies can be clipped.
    static let prerollSilenceMilliseconds = 500

    static func prepareForPlayback(_ utterance: String) -> String {
        "[[slnc \(prerollSilenceMilliseconds)]]\(utterance)"
    }
}

@MainActor
final class CompanionManager: ObservableObject {
    private static let minimumVoiceProcessingDisplayDuration: TimeInterval = 1.0

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentVoicePromptPreview: String?
    @Published private(set) var voicePromptBubbleState: CompanionVoicePromptBubbleState = .hidden
    @Published private(set) var latestAgentSessionSummary: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false

    /// Screen location (global AppKit coords) of a highlighted UI point;
    /// observed by BlueCursorView to trigger the flight animation.
    @Published var detectedElementScreenLocation: CGPoint?
    /// The display frame (global AppKit coords) of the screen the detected
    /// element is on, so BlueCursorView knows which screen overlay should animate.
    @Published var detectedElementDisplayFrame: CGRect?
    /// Custom speech bubble text for the pointing animation. When set,
    /// BlueCursorView uses this instead of a random pointer phrase.
    @Published var detectedElementBubbleText: String?
    /// How long the buddy should keep the pointer bubble visible after arriving.
    @Published var detectedElementDisplayDuration: TimeInterval?

    let buddyDictationManager = BuddyDictationManager()
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private let agentClient: any PickyAgentClient
    private let selectionStore: PickySessionSelectionStoring
    private let voiceContextCaptureCoordinator = PickyVoiceContextCaptureCoordinator()

    init(
        agentClient: any PickyAgentClient = LocalStubPickyAgentClient(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared
    ) {
        self.agentClient = agentClient
        self.selectionStore = selectionStore
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?

    private var shortcutTransitionCancellable: AnyCancellable?
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var dictationErrorCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var responseStateTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    private var speechSynthesizer: NSSpeechSynthesizer?
    private var speechSynthesizerDelegate: PickySpeechSynthesizerDelegate?
    private var activeSpeechID: UUID?
    /// Tracks the physical push-to-talk hold separately from dictation state so
    /// audio stays suppressed even if recording fails before the key is released.
    private var isPushToTalkShortcutHeld = false
    /// Suppresses local spoken audio while the user is starting, holding,
    /// or finalizing voice input. Responses arriving in this window update
    /// visible UI only and are not queued for delayed playback.
    private var isVoiceInputAudioSuppressionActive = false
    private var pendingAgentResponseStartedAt: Date?
    private var voiceFollowUpSessionIDForCurrentUtterance: String?

    /// True when all three required permissions (accessibility, screen recording,
    /// microphone) are granted. Used by the panel to show a single "all good" state.
    var allPermissionsGranted: Bool {
        hasAccessibilityPermission && hasScreenRecordingPermission && hasMicrophonePermission && hasScreenContentPermission
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false

    /// User preference for whether the Picky cursor should be shown.
    /// When toggled off, the overlay is hidden and push-to-talk is disabled.
    /// Persisted to UserDefaults so the choice survives app restarts.
    @Published var isPickyCursorEnabled: Bool = UserDefaults.standard.object(forKey: "isPickyCursorEnabled") == nil
        ? true
        : UserDefaults.standard.bool(forKey: "isPickyCursorEnabled")

    func setPickyCursorEnabled(_ enabled: Bool) {
        isPickyCursorEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "isPickyCursorEnabled")
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        } else {
            overlayWindowManager.hideOverlay()
            isOverlayVisible = false
        }
    }

    func start() {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            bindAgentEvents()
            Task { await agentClient.connect() }
        }
        refreshAllPermissions()
        print("🔑 Picky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindDictationErrors()
        bindShortcutTransitions()
        // Show the cursor as soon as all permissions are available and the
        // cursor preference is enabled.
        if allPermissionsGranted && isPickyCursorEnabled {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    func clearDetectedElementLocation() {
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementDisplayDuration = nil
        scheduleTransientHideIfNeeded()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()

        currentResponseTask?.cancel()
        currentResponseTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        activeSpeechID = nil
        speechSynthesizer?.delegate = nil
        speechSynthesizer?.stopSpeaking()
        speechSynthesizer = nil
        speechSynthesizerDelegate = nil
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        agentEventTask?.cancel()
        agentEventTask = nil
        agentClient.disconnect()
        shortcutTransitionCancellable?.cancel()
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        dictationErrorCancellable?.cancel()
        accessibilityCheckTimer?.invalidate()
        accessibilityCheckTimer = nil
    }

    func refreshAllPermissions() {
        let previouslyHadAccessibility = hasAccessibilityPermission
        let previouslyHadScreenRecording = hasScreenRecordingPermission
        let previouslyHadMicrophone = hasMicrophonePermission
        let previouslyHadAll = allPermissionsGranted

        let currentlyHasAccessibility = WindowPositionManager.hasAccessibilityPermission()
        hasAccessibilityPermission = currentlyHasAccessibility

        if currentlyHasAccessibility {
            globalPushToTalkShortcutMonitor.start()
        } else {
            globalPushToTalkShortcutMonitor.stop()
        }

        hasScreenRecordingPermission = WindowPositionManager.hasScreenRecordingPermission()

        let micAuthStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        hasMicrophonePermission = micAuthStatus == .authorized

        // Debug: log permission state on changes
        if previouslyHadAccessibility != hasAccessibilityPermission
            || previouslyHadScreenRecording != hasScreenRecordingPermission
            || previouslyHadMicrophone != hasMicrophonePermission {
            print("🔑 Permissions — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        }

        // Track individual permission grants as they happen
        if !previouslyHadAccessibility && hasAccessibilityPermission {
            PickyAnalytics.trackPermissionGranted(permission: "accessibility")
        }
        if !previouslyHadScreenRecording && hasScreenRecordingPermission {
            PickyAnalytics.trackPermissionGranted(permission: "screen_recording")
        }
        if !previouslyHadMicrophone && hasMicrophonePermission {
            PickyAnalytics.trackPermissionGranted(permission: "microphone")
        }
        // Screen content permission is persisted — once the user has approved the
        // SCShareableContent picker, we don't need to re-check it.
        if !hasScreenContentPermission {
            hasScreenContentPermission = UserDefaults.standard.bool(forKey: "hasScreenContentPermission")
        }

        if !previouslyHadAll && allPermissionsGranted {
            PickyAnalytics.trackAllPermissionsGranted()
            if isPickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        }
    }

    /// Triggers the macOS screen content picker by performing a dummy
    /// screenshot capture. Once the user approves, we persist the grant
    /// so they're not asked again on later launches.
    @Published private(set) var isRequestingScreenContent = false

    func requestScreenContentPermission() {
        guard !isRequestingScreenContent else { return }
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                // Verify the capture actually returned real content — a 0x0 or
                // fully-empty image means the user denied the prompt.
                let didCapture = image.width > 0 && image.height > 0
                print("🔑 Screen content capture result — width: \(image.width), height: \(image.height), didCapture: \(didCapture)")
                await MainActor.run {
                    isRequestingScreenContent = false
                    guard didCapture else { return }
                    hasScreenContentPermission = true
                    UserDefaults.standard.set(true, forKey: "hasScreenContentPermission")
                    PickyAnalytics.trackPermissionGranted(permission: "screen_content")

                    if allPermissionsGranted && !isOverlayVisible && isPickyCursorEnabled {
                        overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                        isOverlayVisible = true
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    /// Triggers the system microphone prompt if the user has never been asked.
    /// Once granted/denied the status sticks and polling picks it up.
    private func promptForMicrophoneIfNotDetermined() {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else { return }
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    /// Polls all permissions frequently so the UI updates live after the
    /// user grants them in System Settings. Screen Recording is the exception —
    /// macOS requires an app restart for that one to take effect.
    private func startPermissionPolling() {
        accessibilityCheckTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshAllPermissions()
            }
        }
    }

    private func bindAudioPowerLevel() {
        audioPowerCancellable = buddyDictationManager.$currentAudioPowerLevel
            .receive(on: DispatchQueue.main)
            .sink { [weak self] powerLevel in
                self?.currentAudioPowerLevel = powerLevel
            }
    }

    private func bindDictationErrors() {
        dictationErrorCancellable = buddyDictationManager.$lastErrorMessage
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] message in
                self?.voiceFollowUpSessionIDForCurrentUtterance = nil
                self?.finishAwaitingAgentResponse(visibleText: message, spokenText: message)
            }
    }

    private func bindVoiceStateObservation() {
        voiceStateCancellable = buddyDictationManager.$isRecordingFromKeyboardShortcut
            .combineLatest(
                buddyDictationManager.$isRecordingFromMicrophoneButton,
                buddyDictationManager.$isFinalizingTranscript,
                buddyDictationManager.$isPreparingToRecord
            )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] isKeyboardRecording, isMicrophoneRecording, isFinalizing, isPreparing in
                self?.updateVoicePresentation(
                    isKeyboardRecording: isKeyboardRecording,
                    isMicrophoneRecording: isMicrophoneRecording,
                    isFinalizing: isFinalizing,
                    isPreparing: isPreparing
                )
            }
    }

    private func updateVoicePresentation(
        isKeyboardRecording: Bool? = nil,
        isMicrophoneRecording: Bool? = nil,
        isFinalizing: Bool? = nil,
        isPreparing: Bool? = nil
    ) {
        let isKeyboardRecording = isKeyboardRecording ?? buddyDictationManager.isRecordingFromKeyboardShortcut
        let isMicrophoneRecording = isMicrophoneRecording ?? buddyDictationManager.isRecordingFromMicrophoneButton
        let isFinalizing = isFinalizing ?? buddyDictationManager.isFinalizingTranscript
        let isPreparing = isPreparing ?? buddyDictationManager.isPreparingToRecord
        let isVoiceInputActive = isPushToTalkShortcutHeld || isKeyboardRecording || isMicrophoneRecording || isFinalizing || isPreparing
        updateVoiceInputAudioSuppression(isVoiceInputActive: isVoiceInputActive)
        let presentation = CompanionVoicePresentationReducer.reduce(
            currentVoiceState: voiceState,
            isKeyboardRecording: isKeyboardRecording,
            isMicrophoneRecording: isMicrophoneRecording,
            isFinalizingTranscript: isFinalizing,
            isPreparingToRecord: isPreparing,
            isShortcutHeld: isPushToTalkShortcutHeld,
            isAwaitingAgentResponse: pendingAgentResponseStartedAt != nil,
            recognizedPrompt: currentVoicePromptPreview
        )
        voiceState = presentation.voiceState
        voicePromptBubbleState = presentation.promptBubbleState

        // If the user pressed and released the hotkey without saying anything,
        // no response task runs — schedule the transient hide here so the overlay
        // doesn't get stuck. Only do this when no response is in flight, otherwise
        // the brief idle gap between recording and processing would prematurely hide the overlay.
        if presentation.voiceState == .idle, pendingAgentResponseStartedAt == nil {
            scheduleTransientHideIfNeeded()
        }
    }

    private func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] transition in
                self?.handleShortcutTransition(transition)
            }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        switch transition {
        case .pressed:
            isPushToTalkShortcutHeld = true
            guard !buddyDictationManager.isDictationInProgress else { return }
            interruptSpokenResponseForVoiceInput()
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            voiceFollowUpSessionIDForCurrentUtterance = selectionStore.hoveredVoiceFollowUpSessionID

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isPickyCursorEnabled && !isOverlayVisible {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .pickyDismissPanel, object: nil)

            // Cancel any in-progress response from a previous utterance.
            currentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask = nil
            clearDetectedElementLocation()
            updateVoicePresentation()

            PickyAnalytics.trackPushToTalkStarted()

            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = Task {
                await buddyDictationManager.startPushToTalkFromKeyboardShortcut(
                    currentDraftText: "",
                    updateDraftText: { _ in
                        // Partial transcripts are hidden (waveform-only UI)
                    },
                    submitDraftText: { [weak self] finalTranscript in
                        self?.lastTranscript = finalTranscript
                        print("🗣️ Companion received transcript: \(finalTranscript)")
                        PickyAnalytics.trackUserMessageSent(transcript: finalTranscript)
                        self?.submitTranscriptToPickyAgent(transcript: finalTranscript)
                    }
                )
            }
        case .released:
            isPushToTalkShortcutHeld = false
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            PickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            if !buddyDictationManager.isDictationInProgress {
                updateVoiceInputAudioSuppression(isVoiceInputActive: false)
            }
            updateVoicePresentation()
        case .none:
            break
        }
    }

    // MARK: - Agent Submission Pipeline

    /// Captures neutral desktop context and submits it to the local Picky
    /// agent client. Phase 1 uses a local stub; later phases connect this
    /// abstraction to picky-agentd and Pi without changing the macOS capture
    /// pipeline.
    private func submitTranscriptToPickyAgent(transcript: String) {
        currentResponseTask?.cancel()
        beginAwaitingAgentResponse(recognizedTranscript: transcript)

        currentResponseTask = Task {
            do {
                let voiceFollowUpSessionID = voiceFollowUpSessionIDForCurrentUtterance
                guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                    transcript: transcript,
                    voiceFollowUpSessionID: voiceFollowUpSessionID
                ) else { return }
                guard !Task.isCancelled else { return }
                let receipt = try await routeVoiceTranscript(transcript: transcript, contextPacket: captureResult.contextPacket, voiceFollowUpSessionID: voiceFollowUpSessionID)

                guard !Task.isCancelled else { return }

                handleAgentSubmissionAccepted(receipt: receipt, source: captureResult.source)
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                PickyAnalytics.trackResponseError(error: error.localizedDescription)
                print("⚠️ Picky agent submission error: \(error)")
                finishAwaitingAgentResponse(visibleText: "I captured that, but the local agent client is not ready yet.", spokenText: "I captured that, but the local agent client is not ready yet.")
            }

            voiceFollowUpSessionIDForCurrentUtterance = nil

            if !Task.isCancelled, pendingAgentResponseStartedAt == nil, voiceState != .responding {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        }
    }

    func routeVoiceTranscript(
        transcript: String,
        contextPacket: PickyContextPacket,
        voiceFollowUpSessionID: String? = nil
    ) async throws -> PickyAgentSubmissionReceipt {
        if let targetSessionID = voiceFollowUpSessionID ?? selectionStore.hoveredVoiceFollowUpSessionID {
            try await agentClient.send(PickyCommandEnvelope(type: .steer, context: contextPacket, sessionId: targetSessionID, text: transcript))
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        }
        return try await agentClient.submit(PickyAgentSubmission(transcript: transcript, context: contextPacket))
    }

    func handleAgentSubmissionAccepted(receipt: PickyAgentSubmissionReceipt, source: String) {
        PickyAnalytics.trackAgentSubmissionAccepted(sessionID: receipt.sessionID)
        print("🧠 Picky local agent submission accepted: \(receipt.sessionID)")

        let receiptMessage = receipt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !receiptMessage.isEmpty {
            finishAwaitingAgentResponse(visibleText: receiptMessage, spokenText: receiptMessage)
        } else if source == "voice-follow-up" {
            finishAwaitingAgentResponse(visibleText: "선택한 세션에 스티어링 메시지를 전달했어요.", spokenText: nil)
        }
    }

    private func bindAgentEvents() {
        agentEventTask?.cancel()
        agentEventTask = Task { [weak self] in
            guard let self else { return }
            for await event in agentClient.events {
                switch event {
                case .protocolEvent(let envelope):
                    await MainActor.run { self.applyAgentEvent(envelope.event) }
                case .recoverableError(let message):
                    await MainActor.run { self.finishAwaitingAgentResponse(visibleText: "Agent event error: \(message)", spokenText: nil) }
                case .disconnected:
                    await MainActor.run { self.finishAwaitingAgentResponse(visibleText: "picky-agentd disconnected", spokenText: nil) }
                case .connected:
                    await MainActor.run { self.latestAgentSessionSummary = "picky-agentd connected" }
                }
            }
        }
    }

    func applyAgentEvent(_ event: PickyEvent) {
        switch event {
        case .sessionUpdated(let session):
            updatePassiveAgentSummary(session.lastSummary ?? "\(session.title) · \(session.status.rawValue)")
        case .sessionLogAppended, .toolActivityUpdated:
            // Progress events are already represented in the HUD. They should not
            // replace a cursor bubble that is currently speaking/showing a real
            // response, otherwise generic text like "작업 진행 중…" hides the answer.
            break
        case .extensionUiRequest(let request):
            latestAgentSessionSummary = request.prompt ?? request.title ?? "Agent is waiting for input"
        case .quickReply(let reply):
            finishAwaitingAgentResponse(visibleText: reply.text, spokenText: reply.text, enforceMinimumProcessingDuration: true)
        case .pointerOverlayRequested(let request):
            applyPointerOverlayRequest(request)
        case .error(let error):
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
        case .hello, .sessionSnapshot, .artifactUpdated, .artifactOpened, .unknown:
            break
        }
    }

    private func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            detectedElementDisplayFrame = target.displayFrame
            detectedElementBubbleText = target.bubbleText
            detectedElementDisplayDuration = target.duration
            detectedElementScreenLocation = target.screenLocation
            latestAgentSessionSummary = target.bubbleText.map { "가리키는 중: \($0)" } ?? "화면 위치를 가리키는 중…"

            if !overlayWindowManager.isShowingOverlay(), ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
                overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
                isOverlayVisible = true
            }
        } catch {
            latestAgentSessionSummary = "Pointer overlay ignored: \(error.localizedDescription)"
        }
    }

    private func updatePassiveAgentSummary(_ summary: String) {
        guard voiceState != .responding else { return }
        latestAgentSessionSummary = summary
    }

    /// If the cursor is in transient mode (user toggled "Show Picky" off),
    /// waits for any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    private func scheduleTransientHideIfNeeded() {
        guard !isPickyCursorEnabled && isOverlayVisible else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled else { return }
            overlayWindowManager.fadeOutAndHideOverlay()
            isOverlayVisible = false
        }
    }

    private var shouldSuppressSpokenAudioForVoiceInput: Bool {
        isPushToTalkShortcutHeld || isVoiceInputAudioSuppressionActive || buddyDictationManager.isDictationInProgress
    }

    private func updateVoiceInputAudioSuppression(isVoiceInputActive: Bool) {
        guard isVoiceInputActive else {
            isVoiceInputAudioSuppressionActive = false
            return
        }

        isVoiceInputAudioSuppressionActive = true
        stopCurrentSpeech()
        if voiceState == .responding {
            voiceState = .idle
        }
    }

    func interruptSpokenResponseForVoiceInput() {
        updateVoiceInputAudioSuppression(isVoiceInputActive: true)
    }

    func beginAwaitingAgentResponse(recognizedTranscript: String? = nil) {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        if !buddyDictationManager.isDictationInProgress {
            updateVoiceInputAudioSuppression(isVoiceInputActive: false)
        }
        stopCurrentSpeech()
        let trimmedTranscript = recognizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentVoicePromptPreview = trimmedTranscript.isEmpty ? nil : trimmedTranscript
        voicePromptBubbleState = trimmedTranscript.isEmpty ? .recognizing : .recognized(trimmedTranscript)
        pendingAgentResponseStartedAt = Date()
        latestAgentSessionSummary = "응답 준비 중…"
        voiceState = .processing
    }

    private func finishAwaitingAgentResponse(
        visibleText: String,
        spokenText: String?,
        enforceMinimumProcessingDuration: Bool = false
    ) {
        if enforceMinimumProcessingDuration,
           let pendingAgentResponseStartedAt,
           Date().timeIntervalSince(pendingAgentResponseStartedAt) < Self.minimumVoiceProcessingDisplayDuration {
            let remainingDelay = Self.minimumVoiceProcessingDisplayDuration - Date().timeIntervalSince(pendingAgentResponseStartedAt)
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(remainingDelay, 0) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.finishAwaitingAgentResponse(visibleText: visibleText, spokenText: spokenText)
                }
            }
            return
        }

        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        latestAgentSessionSummary = visibleText
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        let textToSpeak = spokenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let textToSpeak, !textToSpeak.isEmpty else {
            if !shouldSuppressSpokenAudioForVoiceInput {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
            return
        }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            stopCurrentSpeech()
            return
        }
        speakSystemMessage(textToSpeak)
    }

    /// Speaks a short local status message through macOS system speech.
    private func speakSystemMessage(_ utterance: String) {
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            stopCurrentSpeech()
            return
        }
        stopCurrentSpeech()

        let speechID = UUID()
        activeSpeechID = speechID

        let delegate = PickySpeechSynthesizerDelegate { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.handleSpeechFinished(speechID: speechID, didFinish: didFinish)
            }
        }
        let synthesizer = reusableSpeechSynthesizer()
        synthesizer.delegate = delegate
        speechSynthesizerDelegate = delegate
        voiceState = .responding

        let preparedUtterance = PickySpeechPlaybackPreparation.prepareForPlayback(utterance)
        #if DEBUG
        print("🔊 Picky TTS start — id: \(speechID), chars: \(utterance.count), prerollMs: \(PickySpeechPlaybackPreparation.prerollSilenceMilliseconds)")
        #endif
        guard synthesizer.startSpeaking(preparedUtterance) else {
            handleSpeechFinished(speechID: speechID, didFinish: false)
            return
        }

        responseStateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let shouldFinish = await MainActor.run { [weak self] in
                    guard let self,
                          self.activeSpeechID == speechID,
                          let synthesizer = self.speechSynthesizer else {
                        return false
                    }
                    return !synthesizer.isSpeaking
                }
                guard shouldFinish else { continue }
                await MainActor.run { [weak self] in
                    self?.handleSpeechFinished(speechID: speechID, didFinish: true)
                }
                return
            }
        }
    }

    private func reusableSpeechSynthesizer() -> NSSpeechSynthesizer {
        if let speechSynthesizer {
            return speechSynthesizer
        }
        let synthesizer = NSSpeechSynthesizer()
        speechSynthesizer = synthesizer
        return synthesizer
    }

    private func stopCurrentSpeech() {
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechSynthesizer?.delegate = nil
        speechSynthesizer?.stopSpeaking()
        speechSynthesizerDelegate = nil
    }

    private func handleSpeechFinished(speechID: UUID, didFinish _: Bool) {
        guard activeSpeechID == speechID else { return }
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechSynthesizer?.delegate = nil
        speechSynthesizerDelegate = nil
        #if DEBUG
        print("🔊 Picky TTS finish — id: \(speechID)")
        #endif
        if voiceState == .responding {
            voiceState = .idle
        }
        scheduleTransientHideIfNeeded()
    }

    // MARK: - Point Tag Parsing

    /// Result of parsing a [POINT:...] tag from an agent response.
    struct PointingParseResult {
        /// The response text with the [POINT:...] tag removed — this is what gets spoken.
        let spokenText: String
        /// The parsed pixel coordinate, or nil if no point was requested.
        let coordinate: CGPoint?
        /// Short label describing the element (e.g. "run button"), or "none".
        let elementLabel: String?
        /// Which screen the coordinate refers to (1-based), or nil to default to cursor screen.
        let screenNumber: Int?
    }

    /// Parses a [POINT:x,y:label:screenN] or [POINT:none] tag from the end of an agent response.
    /// Returns the spoken text (tag removed) and the optional coordinate + label + screen number.
    static func parsePointingCoordinates(from responseText: String) -> PointingParseResult {
        // Match [POINT:none] or [POINT:123,456:label] or [POINT:123,456:label:screen2]
        let pattern = #"\[POINT:(?:none|(\d+)\s*,\s*(\d+)(?::([^\]:\s][^\]:]*?))?(?::screen(\d+))?)\]\s*$"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: []),
              let match = regex.firstMatch(in: responseText, range: NSRange(responseText.startIndex..., in: responseText)) else {
            // No tag found at all
            return PointingParseResult(spokenText: responseText, coordinate: nil, elementLabel: nil, screenNumber: nil)
        }

        // Remove the tag from the spoken text
        let tagRange = Range(match.range, in: responseText)!
        let spokenText = String(responseText[..<tagRange.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)

        // Check if it's [POINT:none]
        guard match.numberOfRanges >= 3,
              let xRange = Range(match.range(at: 1), in: responseText),
              let yRange = Range(match.range(at: 2), in: responseText),
              let x = Double(responseText[xRange]),
              let y = Double(responseText[yRange]) else {
            return PointingParseResult(spokenText: spokenText, coordinate: nil, elementLabel: "none", screenNumber: nil)
        }

        var elementLabel: String? = nil
        if match.numberOfRanges >= 4, let labelRange = Range(match.range(at: 3), in: responseText) {
            elementLabel = String(responseText[labelRange]).trimmingCharacters(in: .whitespaces)
        }

        var screenNumber: Int? = nil
        if match.numberOfRanges >= 5, let screenRange = Range(match.range(at: 4), in: responseText) {
            screenNumber = Int(responseText[screenRange])
        }

        return PointingParseResult(
            spokenText: spokenText,
            coordinate: CGPoint(x: x, y: y),
            elementLabel: elementLabel,
            screenNumber: screenNumber
        )
    }

}
