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
    private static let recognizedPromptPreviewCharacterLimit = 280

    case hidden
    case recognizing
    case recognized(String)

    var isVisible: Bool {
        if case .recognized = self { return true }
        return false
    }

    var displayText: String {
        switch self {
        case .hidden, .recognizing:
            return ""
        case .recognized(let prompt):
            return Self.truncatedPreviewText(for: prompt)
        }
    }

    private static func truncatedPreviewText(for prompt: String) -> String {
        guard prompt.count > recognizedPromptPreviewCharacterLimit else { return prompt }

        let previewEndIndex = prompt.index(prompt.startIndex, offsetBy: recognizedPromptPreviewCharacterLimit)
        return String(prompt[..<previewEndIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines) + "…"
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
            promptBubbleState = trimmedPrompt.isEmpty ? .hidden : .recognized(trimmedPrompt)
        } else if isAwaitingAgentResponse {
            promptBubbleState = trimmedPrompt.isEmpty ? .hidden : .recognized(trimmedPrompt)
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

@MainActor
final class CompanionManager: ObservableObject {
    private static let minimumVoiceProcessingDisplayDuration: TimeInterval = 1.0
    /// How long the recognized-transcript bubble stays on screen after STT
    /// finishes. The agent may still be processing — the bubble auto-hides so
    /// it doesn't sit on the cursor for the entire response wait.
    private static let recognizedTranscriptVisibleDuration: TimeInterval = 3.0

    @Published private(set) var voiceState: CompanionVoiceState = .idle
    @Published private(set) var lastTranscript: String?
    @Published private(set) var currentVoicePromptPreview: String?
    @Published private(set) var voicePromptBubbleState: CompanionVoicePromptBubbleState = .hidden {
        didSet {
            // Any transition into .hidden (whether from finishAwaitingAgentResponse,
            // a fresh PTT, or the presentation reducer) makes the auto-hide task
            // redundant. Cancel it so we don't race a stale hide against a future
            // .recognized state from the next utterance.
            if case .hidden = voicePromptBubbleState {
                voicePromptBubbleAutoHideTask?.cancel()
                voicePromptBubbleAutoHideTask = nil
            }
        }
    }
    @Published private(set) var latestAgentSessionSummary: String?
    @Published private(set) var mainAgentMessages: [PickyMainAgentMessage] = []
    @Published private(set) var isSendingDirectMessage = false
    @Published private(set) var isResettingMainAgentSession = false
    @Published private(set) var directMessageError: String?
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
    /// Optional bounding rect (global AppKit coords) of the highlighted element.
    /// When provided, the highlight overlay sizes its rings to match the bbox.
    /// When nil, the overlay falls back to a default-sized circle around the point.
    @Published var detectedElementTargetFrame: CGRect?
    /// Whether the highlight is over an in-screen element (dim the surroundings)
    /// or over Picky's own HUD chrome like the dock (no dim).
    @Published var detectedElementHighlightKind: PickyDetectedHighlightKind?

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let quickInputDoubleTapDetector = QuickInputDoubleTapDetector()
    let quickInputPanelManager = QuickInputPanelManager()
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    private let agentClient: any PickyAgentClient
    private let selectionStore: PickySessionSelectionStoring
    private var speechPlaybackProvider: any PickySpeechPlaybackProvider
    private let voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator

    init(
        agentClient: any PickyAgentClient = LocalStubPickyAgentClient(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        buddyDictationManager: BuddyDictationManager? = nil,
        speechPlaybackProvider: (any PickySpeechPlaybackProvider)? = nil,
        voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator? = nil
    ) {
        self.agentClient = agentClient
        self.selectionStore = selectionStore
        self.buddyDictationManager = buddyDictationManager ?? BuddyDictationManager()
        self.speechPlaybackProvider = speechPlaybackProvider ?? PickySpeechPlaybackProviderFactory.makeDefaultProvider()
        self.voiceContextCaptureCoordinator = voiceContextCaptureCoordinator ?? PickyVoiceContextCaptureCoordinator()
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?
    private var directMessageContextIDs = Set<String>()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var quickInputDoubleTapCancellable: AnyCancellable?
    private var shortcutCaptureObserver: NSObjectProtocol?
    private var hudDockPointerObserver: NSObjectProtocol?
    /// Tracks how many `ShortcutCaptureRecorder` instances are currently in
    /// capture mode. While > 0 the global PTT monitor and Quick Input
    /// detector are paused so the user can press their existing shortcut to
    /// rebind it without dismissing the Settings panel or triggering a voice
    /// session.
    private var activeShortcutCaptureCount: Int = 0
    private var voiceStateCancellable: AnyCancellable?
    private var audioPowerCancellable: AnyCancellable?
    private var dictationErrorCancellable: AnyCancellable?
    private var settingsChangeCancellable: AnyCancellable?
    private var accessibilityCheckTimer: Timer?
    private var pendingKeyboardShortcutStartTask: Task<Void, Never>?
    /// Scheduled hide for transient cursor mode — cancelled if the user
    /// speaks again before the delay elapses.
    private var transientHideTask: Task<Void, Never>?
    private var responseStateTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    /// Caps how long the recognized-transcript bubble lingers after STT.
    private var voicePromptBubbleAutoHideTask: Task<Void, Never>?
    private var activeSpeechID: UUID?
    /// Tracks the physical push-to-talk hold separately from dictation state so
    /// audio stays suppressed even if recording fails before the key is released.
    private var isPushToTalkShortcutHeld = false
    /// Suppresses local spoken audio while the user is starting, holding,
    /// or finalizing voice input. Responses arriving in this window update
    /// visible UI only and are not queued for delayed playback.
    private var isVoiceInputAudioSuppressionActive = false
    private var pendingAgentResponseStartedAt: Date?
    /// Voice follow-up target captured at PTT press time and used by the response
    /// task to route the utterance. Exposed read-only at module scope so tests can
    /// guard the race-condition fix in `updateVoicePresentation` (see also the
    /// regression test in PickyCompanionManagerTests). Mutate only via
    /// `setVoiceFollowUpSessionIDForCurrentUtterance(_:)`.
    private(set) var voiceFollowUpSessionIDForCurrentUtterance: String?

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
        wireQuickInputPanel()
        applyShortcutSpecsFromSettings()
        bindShortcutCaptureLifecycle()
        bindHUDDockPointerRequests()
        refreshAllPermissions()
        print("🔑 Picky start — accessibility: \(hasAccessibilityPermission), screen: \(hasScreenRecordingPermission), mic: \(hasMicrophonePermission), screenContent: \(hasScreenContentPermission)")
        startPermissionPolling()
        bindVoiceStateObservation()
        bindAudioPowerLevel()
        bindDictationErrors()
        bindShortcutTransitions()
        bindQuickInputDoubleTap()
        bindSettingsChanges()
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
        detectedElementTargetFrame = nil
        detectedElementHighlightKind = nil
        scheduleTransientHideIfNeeded()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        globalPushToTalkShortcutMonitor.rawEventForwarder = nil
        quickInputDoubleTapDetector.reset()
        quickInputPanelManager.dismiss()
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
        speechPlaybackProvider.stopSpeaking()
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        agentEventTask?.cancel()
        agentEventTask = nil
        agentClient.disconnect()
        shortcutTransitionCancellable?.cancel()
        quickInputDoubleTapCancellable?.cancel()
        if let shortcutCaptureObserver {
            NotificationCenter.default.removeObserver(shortcutCaptureObserver)
            self.shortcutCaptureObserver = nil
        }
        if let hudDockPointerObserver {
            NotificationCenter.default.removeObserver(hudDockPointerObserver)
            self.hudDockPointerObserver = nil
        }
        activeShortcutCaptureCount = 0
        globalPushToTalkShortcutMonitor.isCapturePaused = false
        voiceStateCancellable?.cancel()
        audioPowerCancellable?.cancel()
        dictationErrorCancellable?.cancel()
        settingsChangeCancellable?.cancel()
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
                self?.setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                self?.finishAwaitingAgentResponse(visibleText: message, spokenText: message)
            }
    }

    private func bindSettingsChanges() {
        settingsChangeCancellable = NotificationCenter.default.publisher(for: .pickySettingsDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let settings = PickySettingsStore().load()
                self?.reloadVoiceProvidersFromSettings(settings)
                self?.syncDaemonSettings(settings)
                self?.applyShortcutSpecsFromSettings(settings)
            }
    }

    private func bindHUDDockPointerRequests() {
        guard hudDockPointerObserver == nil else { return }
        hudDockPointerObserver = NotificationCenter.default.addObserver(
            forName: .pickyPointAtHUDDockSession,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let target = PickyHUDDockPointerTargetNotification.target(from: notification) else { return }
            Task { @MainActor [weak self] in
                self?.applyHUDDockPointerTarget(target)
            }
        }
    }

    /// Pushes the persisted PTT/Quick Input shortcut specs into the live
    /// monitor and detector. Called on launch and whenever Settings saves.
    private func applyShortcutSpecsFromSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        globalPushToTalkShortcutMonitor.currentShortcutSpec = settings.pushToTalkShortcut
        quickInputDoubleTapDetector.currentShortcutSpec = settings.quickInputShortcut
        print("⌨️  Shortcuts applied — PTT: \(settings.pushToTalkShortcut), QuickInput: \(settings.quickInputShortcut)")
    }

    private func reloadVoiceProvidersFromSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        buddyDictationManager.updateTranscriptionProvider(
            BuddyTranscriptionProviderFactory.makeDefaultProvider(settings: settings)
        )
        if speechPlaybackProvider.isSpeaking {
            stopCurrentSpeech()
        }
        speechPlaybackProvider = PickySpeechPlaybackProviderFactory.makeDefaultProvider(settings: settings)
        print("🎛️ Voice settings applied — STT: \(settings.sttProvider.rawValue), TTS: \(settings.ttsProvider.rawValue), Azure STT language: \(settings.azureSTTPreferredLanguage.isEmpty ? "auto" : settings.azureSTTPreferredLanguage)")
    }

    private func syncDaemonSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        Task {
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentThinkingLevel,
                    mainAgentThinkingLevel: settings.mainAgentThinkingLevel
                ))
                print("🎛️ Main agent thinking level applied — \(settings.mainAgentThinkingLevel.rawValue)")
            } catch {
                print("⚠️ Failed to apply main agent thinking level: \(error.localizedDescription)")
            }
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

    // Internal (instead of private) so PickyCompanionManagerTests can replay the
    // PTT-released idle window where the hover ID race used to clear the target.
    func updateVoicePresentation(
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
            // Note: hover ID reset is intentionally NOT done here. The reducer can
            // briefly report idle right after PTT release (between
            // `stopPushToTalkFromKeyboardShortcut` and the subsequent finalize +
            // `submitDraftText` -> `submitTranscriptToPickyAgent` chain), and clearing
            // `voiceFollowUpSessionIDForCurrentUtterance` here would race the response
            // task into routing voice input to the main agent instead of the hovered
            // side session. Hover-ID cleanup is handled explicitly on dictation error,
            // capture failure, and at the end of the response task. See the regression
            // test `idleVoicePresentationDoesNotClearPressedHoverIDBeforeSubmit`.
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

    /// Routes raw flags/key events from the PTT event tap into the Quick
    /// Input detector so we don't need a second CGEvent tap.
    private func wireQuickInputPanel() {
        globalPushToTalkShortcutMonitor.rawEventForwarder = { [weak self] eventType, keyCode, flagsRawValue in
            guard let self else { return }
            self.quickInputDoubleTapDetector.handleGlobalEvent(
                eventType: eventType,
                keyCode: keyCode,
                modifierFlagsRawValue: flagsRawValue
            )
        }
        quickInputPanelManager.onSubmit = { [weak self] text in
            self?.handleQuickInputSubmit(text: text)
        }
    }

    private func bindQuickInputDoubleTap() {
        quickInputDoubleTapCancellable = quickInputDoubleTapDetector
            .eventPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] event in
                self?.handleQuickInputDoubleTap(event)
            }
    }

    private func handleQuickInputDoubleTap(_ event: QuickInputDoubleTapEvent) {
        // PTT-in-progress and the input panel are mutually exclusive: voice and
        // typed quick input share the same submission lane and we don't want a
        // floating focus stealer mid-utterance.
        guard activeShortcutCaptureCount == 0,
              !isPushToTalkShortcutHeld,
              !buddyDictationManager.isDictationInProgress else { return }
        quickInputPanelManager.presentPanel(near: event.mouseLocation)
    }

    /// Wires the global "is anyone currently rebinding a shortcut?" signal so
    /// the PTT monitor and Quick Input detector pause while the Settings
    /// capture UI is open.
    private func bindShortcutCaptureLifecycle() {
        if let shortcutCaptureObserver {
            NotificationCenter.default.removeObserver(shortcutCaptureObserver)
        }
        shortcutCaptureObserver = NotificationCenter.default.addObserver(
            forName: .pickyShortcutCaptureDidChange,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let isCapturing = (note.userInfo?[PickyShortcutCaptureNotificationKeys.isCapturing] as? Bool) ?? false
            Task { @MainActor [weak self] in
                self?.applyShortcutCaptureLifecycleChange(isCapturing: isCapturing)
            }
        }
    }

    private func applyShortcutCaptureLifecycleChange(isCapturing: Bool) {
        if isCapturing {
            activeShortcutCaptureCount += 1
        } else {
            activeShortcutCaptureCount = max(0, activeShortcutCaptureCount - 1)
        }
        let shouldPause = activeShortcutCaptureCount > 0
        globalPushToTalkShortcutMonitor.isCapturePaused = shouldPause
        if shouldPause {
            quickInputDoubleTapDetector.reset()
        }
    }

    private func handleQuickInputSubmit(text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await self.sendDirectMessage(text)
            self.quickInputPanelManager.panelDidFinishSending(
                success: success,
                errorMessage: success ? nil : self.directMessageError
            )
        }
    }

    private func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        // Defensive: even though GlobalPushToTalkShortcutMonitor short-circuits
        // its callback while paused, swallowing transitions here too keeps any
        // already-queued event from slipping through and dismissing the panel.
        if activeShortcutCaptureCount > 0 { return }
        switch transition {
        case .pressed:
            isPushToTalkShortcutHeld = true
            guard !buddyDictationManager.isDictationInProgress else { return }
            interruptSpokenResponseForVoiceInput()
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            setVoiceFollowUpSessionIDForCurrentUtterance(selectionStore.hoveredVoiceFollowUpSessionID)

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
                ) else {
                    setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                    return
                }
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

            setVoiceFollowUpSessionIDForCurrentUtterance(nil)

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
        if let targetSessionID = normalizedVoiceFollowUpSessionID(voiceFollowUpSessionID) {
            try await agentClient.send(PickyCommandEnvelope(type: .steer, context: contextPacket, sessionId: targetSessionID, text: transcript))
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        }
        return try await agentClient.submit(PickyAgentSubmission(transcript: transcript, context: contextPacket))
    }

    // Internal (instead of private) so PickyCompanionManagerTests can seed the
    // utterance-scoped hover ID exactly the way the PTT pressed handler does.
    func setVoiceFollowUpSessionIDForCurrentUtterance(_ sessionID: String?) {
        let normalized = normalizedVoiceFollowUpSessionID(sessionID)
        guard voiceFollowUpSessionIDForCurrentUtterance != normalized else { return }
        voiceFollowUpSessionIDForCurrentUtterance = normalized
        var userInfo: [String: String] = [:]
        if let normalized {
            userInfo[PickyVoiceFollowUpTargetNotification.sessionIDKey] = normalized
        }
        NotificationCenter.default.post(name: .pickyVoiceFollowUpTargetChanged, object: nil, userInfo: userInfo)
    }

    private func normalizedVoiceFollowUpSessionID(_ sessionID: String?) -> String? {
        let trimmed = sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    @discardableResult
    func sendDirectMessage(_ text: String) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        isSendingDirectMessage = true
        directMessageError = nil
        var submittedContextID: String?
        defer { isSendingDirectMessage = false }

        do {
            guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                transcript: trimmedText,
                source: "text"
            ) else { return false }
            submittedContextID = captureResult.contextPacket.id
            directMessageContextIDs.insert(captureResult.contextPacket.id)
            _ = try await agentClient.submit(PickyAgentSubmission(transcript: trimmedText, context: captureResult.contextPacket))
            PickyAnalytics.trackUserMessageSent(transcript: trimmedText)
            return true
        } catch {
            if let submittedContextID {
                directMessageContextIDs.remove(submittedContextID)
            }
            let message = error.localizedDescription
            directMessageError = "메시지를 보내지 못했어요: \(message)"
            latestAgentSessionSummary = directMessageError
            return false
        }
    }

    @discardableResult
    func resetMainAgentSession() async -> Bool {
        guard !isResettingMainAgentSession else { return false }
        isResettingMainAgentSession = true
        directMessageError = nil
        defer { isResettingMainAgentSession = false }

        do {
            try await agentClient.send(PickyCommandEnvelope(type: .resetMainAgent))
            mainAgentMessages = []
            directMessageContextIDs.removeAll()
            latestAgentSessionSummary = "Started a new Messages session"
            return true
        } catch {
            let message = error.localizedDescription
            directMessageError = "새 메시지 세션을 시작하지 못했어요: \(message)"
            latestAgentSessionSummary = directMessageError
            return false
        }
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
                    await MainActor.run {
                        self.latestAgentSessionSummary = "picky-agentd connected"
                        self.syncDaemonSettings()
                    }
                    try? await self.agentClient.send(PickyCommandEnvelope(type: .listMainMessages))
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
            if directMessageContextIDs.remove(reply.contextId) != nil {
                latestAgentSessionSummary = reply.text
            } else {
                let spoken = stripParentheticalsForSpeech(reply.text)
                finishAwaitingAgentResponse(visibleText: reply.text, spokenText: spoken, enforceMinimumProcessingDuration: true)
            }
        case .mainMessagesSnapshot(let messages):
            mainAgentMessages = Array(messages.suffix(100))
        case .mainMessageAppended(let message):
            mainAgentMessages = Array((mainAgentMessages + [message]).suffix(100))
        case .pointerOverlayRequested(let request):
            applyPointerOverlayRequest(request)
        case .error(let error):
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
        case .hello, .sessionSnapshot, .artifactUpdated, .artifactOpened, .slashCommandsSnapshot, .unknown,
             .sessionMessageAppended, .sessionMessageReplaced, .sessionMessageRemoved, .sessionQueueUpdated, .sessionActivityUpdated:
            break
        }
    }

    private func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            detectedElementDisplayFrame = target.displayFrame
            detectedElementBubbleText = target.bubbleText
            detectedElementDisplayDuration = target.duration
            detectedElementTargetFrame = nil
            detectedElementHighlightKind = .screenElement
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

    private func applyHUDDockPointerTarget(_ target: PickyHUDDockPointerTarget) {
        let screenLocation = target.screenLocation
        let displayFrame = NSScreen.screens.first { $0.frame.insetBy(dx: -1, dy: -1).contains(screenLocation) }?.frame
            ?? NSScreen.main?.frame
            ?? target.screenFrame
        detectedElementDisplayFrame = displayFrame
        detectedElementBubbleText = target.label
        detectedElementDisplayDuration = target.duration
        detectedElementTargetFrame = target.screenFrame
        detectedElementHighlightKind = .hudDockIcon
        detectedElementScreenLocation = screenLocation
        latestAgentSessionSummary = "새 사이드 에이전트를 가리키는 중…"

        if !overlayWindowManager.isShowingOverlay(), ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
            isOverlayVisible = true
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
        abortMainAgentForVoiceInput()
    }

    private func abortMainAgentForVoiceInput() {
        Task { [agentClient] in
            do {
                try await agentClient.send(PickyCommandEnvelope(type: .abortMainAgent))
            } catch {
                print("⚠️ Failed to abort main agent for voice input: \(error)")
            }
        }
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
        voicePromptBubbleState = trimmedTranscript.isEmpty ? .hidden : .recognized(trimmedTranscript)
        pendingAgentResponseStartedAt = Date()
        latestAgentSessionSummary = "응답 준비 중…"
        voiceState = .processing
        scheduleRecognizedTranscriptAutoHide(trimmedTranscript: trimmedTranscript)
    }

    private func scheduleRecognizedTranscriptAutoHide(trimmedTranscript: String) {
        voicePromptBubbleAutoHideTask?.cancel()
        voicePromptBubbleAutoHideTask = nil
        guard !trimmedTranscript.isEmpty else { return }

        let visibleDuration = Self.recognizedTranscriptVisibleDuration
        voicePromptBubbleAutoHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(visibleDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                // Only retract the bubble if it's still showing the same
                // recognized transcript. If the agent already responded, or a
                // new utterance replaced it, the didSet on voicePromptBubbleState
                // already cancelled this task — but guard defensively anyway.
                guard case .recognized = self.voicePromptBubbleState else { return }
                self.voicePromptBubbleState = .hidden
                self.currentVoicePromptPreview = nil
            }
        }
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

        voiceState = .responding

        #if DEBUG
        print("🔊 Picky TTS start — id: \(speechID), provider: \(speechPlaybackProvider.displayName), chars: \(utterance.count)")
        #endif
        guard speechPlaybackProvider.speak(utterance, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.handleSpeechFinished(speechID: speechID, didFinish: didFinish)
            }
        }) else {
            handleSpeechFinished(speechID: speechID, didFinish: false)
            return
        }

        responseStateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let shouldFinish = await MainActor.run { [weak self] in
                    guard let self,
                          self.activeSpeechID == speechID else {
                        return false
                    }
                    return !self.speechPlaybackProvider.isSpeaking
                }
                guard shouldFinish else { continue }
                await MainActor.run { [weak self] in
                    self?.handleSpeechFinished(speechID: speechID, didFinish: true)
                }
                return
            }
        }
    }

    private func stopCurrentSpeech() {
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechPlaybackProvider.stopSpeaking()
    }

    private func handleSpeechFinished(speechID: UUID, didFinish _: Bool) {
        guard activeSpeechID == speechID else { return }
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
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

/// Removes parenthesised passages so the TTS layer skips supplementary detail
/// (URLs, paths, identifiers) that the main agent placed in `(...)`. Handles
/// both ASCII parentheses and the full-width Korean variants. Visible text
/// keeps the parentheses intact.
func stripParentheticalsForSpeech(_ text: String) -> String {
    let pattern = #"[\(\uFF08][^\(\)\uFF08\uFF09]*[\)\uFF09]"#
    guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let stripped = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
    let collapsed = stripped
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " ([,.!?。，！？])", with: "$1", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? text : collapsed
}
