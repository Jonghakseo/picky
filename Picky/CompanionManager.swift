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

enum PickyRealtimeVoiceError: LocalizedError {
    case contextCaptureReturnedNil

    var errorDescription: String? {
        switch self {
        case .contextCaptureReturnedNil:
            "Context capture returned no packet."
        }
    }
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
    private static let deferredSpeechRetryInterval: TimeInterval = 0.05
    private static let deferredSpeechMaximumWait: TimeInterval = 2.0

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
    @Published private(set) var mainAgentModelOptions: [PickyMainAgentModelOption] = []
    @Published private(set) var isLoadingMainAgentModelOptions = false

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
    /// Stable id for the active pointer animation. Every delayed BlueCursorView
    /// callback validates this id before mutating or clearing pointer state.
    @Published var detectedElementPointerID: String?

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
    private let realtimeVoiceInputManager = OpenAIRealtimeVoiceInputManager()
    private let realtimeAudioPlaybackEngine: any PickyRealtimeAudioPlaybacking

    init(
        agentClient: any PickyAgentClient = LocalStubPickyAgentClient(),
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        buddyDictationManager: BuddyDictationManager? = nil,
        speechPlaybackProvider: (any PickySpeechPlaybackProvider)? = nil,
        voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator? = nil,
        realtimeAudioPlaybackEngine: (any PickyRealtimeAudioPlaybacking)? = nil
    ) {
        self.agentClient = agentClient
        self.selectionStore = selectionStore
        self.buddyDictationManager = buddyDictationManager ?? BuddyDictationManager()
        self.speechPlaybackProvider = speechPlaybackProvider ?? PickySpeechPlaybackProviderFactory.makeDefaultProvider()
        self.voiceContextCaptureCoordinator = voiceContextCaptureCoordinator ?? PickyVoiceContextCaptureCoordinator()
        self.realtimeAudioPlaybackEngine = realtimeAudioPlaybackEngine ?? OpenAIRealtimeAudioPlaybackEngine()
        self.inkCaptureController.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                self?.inkOverlayState = state
            }
        }
        self.inkCaptureController.shouldPassThroughMouseEvent = { [weak self] point, source in
            guard source == .text else { return false }
            return self?.quickInputPanelManager.containsInteractiveGlobalPoint(point) == true
        }
        self.realtimeAudioPlaybackEngine.onPlaybackDrained = { [weak self] in
            self?.handleRealtimePlaybackDrained()
        }
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?
    private var directMessageContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let inkCaptureController = PickyInkCaptureController()
    private var pendingInkCapturesByInputID: [UUID: PickyInkCapture] = [:]
    private lazy var interactionCoordinator: PickyInteractionCoordinator = {
        let coordinator = PickyInteractionCoordinator(
            envelopeMaker: PickyInteractionStaticEnvelopeMaker(),
            effectRunner: CompanionInteractionEffectRunner(manager: self)
        )
        coordinator.onProjectionPublished = { [weak self] _, projection in
            self?.applyInteractionProjection(projection)
        }
        return coordinator
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var quickInputDoubleTapCancellable: AnyCancellable?
    private var shortcutCaptureObserver: NSObjectProtocol?
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
    private var deferredInteractionSpeechTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    /// Caps how long the recognized-transcript bubble lingers after STT.
    private var voicePromptBubbleAutoHideTask: Task<Void, Never>?
    private var activeSpeechID: UUID?
    private var interactionSpeechID: UUID?
    private var interactionVoiceInputID: UUID?
    private var realtimeVoiceInputID: UUID?
    private var realtimeCanSendAudio = false
    private var realtimeBufferedAudioChunks: [Data] = []
    private var realtimeOutputTranscriptByInputID: [UUID: String] = [:]
    /// Tracks the physical push-to-talk hold separately from dictation state so
    /// audio stays suppressed even if recording fails before the key is released.
    private var isPushToTalkShortcutHeld = false
    /// Suppresses local spoken audio while the user is starting, holding,
    /// or finalizing voice input. If a voice-owned reply arrives during the
    /// finalizing→idle transition, speech is deferred briefly rather than failed
    /// so fast agent replies are not dropped by the tail of the same utterance.
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
    @Published private(set) var overlayVisibilityReasons: Set<PickyOverlayReason> = []
    @Published private(set) var isQuickInputPanelVisible: Bool = false
    @Published private(set) var inkOverlayState: PickyInkOverlayState = .inactive

    private var localOverlayVisibilityReasons: Set<PickyOverlayReason> = []
    private var interactionOverlayVisibilityReasons: Set<PickyOverlayReason> = []

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
            setLocalOverlayReason(.cursorPreferenceEnabled, visible: true)
        } else {
            localOverlayVisibilityReasons.removeAll()
            interactionOverlayVisibilityReasons.removeAll()
            syncOverlayVisibility(animatedHide: false)
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
            setLocalOverlayReason(.cursorPreferenceEnabled, visible: true)
        }
    }

    /// Called by BlueCursorView after the buddy finishes its pointing
    /// animation and returns to cursor-following mode.
    func clearDetectedElementLocation(pointerID: String? = nil) {
        if let pointerID, detectedElementPointerID != pointerID { return }
        let clearedPointerID = detectedElementPointerID
        detectedElementScreenLocation = nil
        detectedElementDisplayFrame = nil
        detectedElementBubbleText = nil
        detectedElementDisplayDuration = nil
        detectedElementTargetFrame = nil
        detectedElementHighlightKind = nil
        detectedElementPointerID = nil
        if let clearedPointerID {
            interactionCoordinator.accept(
                .pointerAnimationFinished(pointerID: clearedPointerID),
                correlation: PickyInteractionCorrelation(pointerID: clearedPointerID, source: .pointer)
            )
        }
        setLocalOverlayReason(.activePointerAnimation, visible: false)
        scheduleTransientHideIfNeeded()
    }

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        globalPushToTalkShortcutMonitor.rawEventForwarder = nil
        quickInputDoubleTapDetector.reset()
        quickInputPanelManager.dismiss()
        cancelInkCapture()
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
            if isPickyCursorEnabled {
                setLocalOverlayReason(.cursorPreferenceEnabled, visible: true)
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

                    if allPermissionsGranted && isPickyCursorEnabled {
                        setLocalOverlayReason(.cursorPreferenceEnabled, visible: true)
                    }
                }
            } catch {
                print("⚠️ Screen content permission request failed: \(error)")
                await MainActor.run { isRequestingScreenContent = false }
            }
        }
    }

    // MARK: - Private

    private func setLocalOverlayReason(_ reason: PickyOverlayReason, visible: Bool) {
        if visible {
            localOverlayVisibilityReasons.insert(reason)
        } else {
            localOverlayVisibilityReasons.remove(reason)
        }
        syncOverlayVisibility()
    }

    private func beginInkCapture(source: PickyInkCaptureSource) {
        setLocalOverlayReason(.activeInkCapture, visible: true)
        if !inkCaptureController.begin(source: source) {
            setLocalOverlayReason(.activeInkCapture, visible: false)
        }
    }

    private func finishInkCapture(inputID: UUID?) {
        let capture = inkCaptureController.finish()
        if let inputID, let capture, capture.hasVisibleInk {
            pendingInkCapturesByInputID[inputID] = capture
        }
        setLocalOverlayReason(.activeInkCapture, visible: false)
    }

    private func finishInkCaptureForDeferredTextSubmission() -> PickyInkCapture? {
        let capture = inkCaptureController.finish()
        setLocalOverlayReason(.activeInkCapture, visible: false)
        return capture?.hasVisibleInk == true ? capture : nil
    }

    private func cancelInkCapture() {
        inkCaptureController.cancel()
        setLocalOverlayReason(.activeInkCapture, visible: false)
    }

    private func consumePendingInkCapture(inputID: UUID) -> PickyInkCapture? {
        pendingInkCapturesByInputID.removeValue(forKey: inputID)
    }

    private func setInteractionOverlayReasons(from phase: PickyOverlayPhase) {
        switch phase {
        case .hidden:
            interactionOverlayVisibilityReasons = []
        case .visible(let reasons):
            interactionOverlayVisibilityReasons = reasons
        case .hiding(_, let reason):
            interactionOverlayVisibilityReasons = [reason]
        }
        syncOverlayVisibility()
    }

    private func syncOverlayVisibility(animatedHide: Bool = true) {
        let reasons = localOverlayVisibilityReasons.union(interactionOverlayVisibilityReasons)
        overlayVisibilityReasons = reasons
        transientHideTask?.cancel()
        transientHideTask = nil

        guard !reasons.isEmpty else {
            if isOverlayVisible {
                if animatedHide {
                    overlayWindowManager.fadeOutAndHideOverlay()
                } else {
                    overlayWindowManager.hideOverlay()
                }
            }
            isOverlayVisible = false
            return
        }

        guard !isOverlayVisible else { return }
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            overlayWindowManager.showOverlay(onScreens: NSScreen.screens, companionManager: self)
        }
        isOverlayVisible = true
    }

    private var hasActiveTransientOverlayBlocker: Bool {
        let blockers: Set<PickyOverlayReason> = [.activeVoiceInput, .waitingForVoiceResponse, .speakingResponse, .activePointerAnimation, .activeInkCapture]
        return !overlayVisibilityReasons.intersection(blockers).isEmpty
    }

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

    func refreshMainAgentModelOptions() {
        isLoadingMainAgentModelOptions = true
        Task {
            do {
                try await agentClient.send(PickyCommandEnvelope(type: .listMainAgentModels))
            } catch {
                await MainActor.run { self.isLoadingMainAgentModelOptions = false }
                print("⚠️ Failed to list main agent models: \(error.localizedDescription)")
            }
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
                    type: .setDefaultCwd,
                    defaultCwd: settings.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                print("🎛️ Side agent default cwd applied — \(settings.defaultCwd)")
            } catch {
                print("⚠️ Failed to apply side agent default cwd: \(error.localizedDescription)")
            }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentThinkingLevel,
                    mainAgentThinkingLevel: settings.mainAgentThinkingLevel
                ))
                print("🎛️ Main agent thinking level applied — \(settings.mainAgentThinkingLevel.rawValue)")
            } catch {
                print("⚠️ Failed to apply main agent thinking level: \(error.localizedDescription)")
            }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentModel,
                    mainAgentModelPattern: settings.mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                print("🎛️ Main agent model applied — \(settings.mainAgentModelPattern.isEmpty ? "Pi default" : settings.mainAgentModelPattern)")
            } catch {
                print("⚠️ Failed to apply main agent model: \(error.localizedDescription)")
            }
            do {
                let effectiveRuntimeMode = AppBundleConfiguration.realtimeOptIn ? settings.mainAgentRuntimeMode : .pi
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentRuntimeMode,
                    mode: effectiveRuntimeMode.agentdEnvironmentValue
                ))
                print("🎛️ Main agent runtime mode applied — \(effectiveRuntimeMode.rawValue)")
            } catch {
                print("⚠️ Failed to apply main agent runtime mode: \(error.localizedDescription)")
            }
            if AppBundleConfiguration.realtimeOptIn, settings.mainAgentRuntimeMode == .openAIRealtime {
                await configureRealtimeMainAgent(settings: settings)
            }
            let trimmedExtra = settings.mainAgentExtraInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentExtraInstructions,
                    mainAgentExtraInstructions: trimmedExtra
                ))
                print("🎛️ Main agent extra instructions applied — \(trimmedExtra.count) chars")
            } catch {
                print("⚠️ Failed to apply main agent extra instructions: \(error.localizedDescription)")
            }
        }
    }

    private func configureRealtimeMainAgent(settings: PickySettings) async {
        let realtime = settings.openAIRealtime.normalized()
        guard !realtime.apiKey.isEmpty else {
            print("🎛️ Realtime main agent not configured — API key missing")
            return
        }
        let azureConfig: PickyOpenAIRealtimeAzureProtocolConfig?
        let modelOrDeployment: String
        if realtime.provider == .azureOpenAI {
            guard let endpoint = realtime.azureRealtimeEndpointComponents else {
                print("🎛️ Realtime main agent not configured — Azure Realtime URL missing or invalid")
                return
            }
            azureConfig = PickyOpenAIRealtimeAzureProtocolConfig(
                resourceEndpoint: endpoint.resourceEndpoint,
                apiVersion: endpoint.apiVersion,
                apiShape: endpoint.apiShape.protocolValue
            )
            modelOrDeployment = endpoint.deployment
        } else {
            azureConfig = nil
            modelOrDeployment = realtime.modelOrDeployment.isEmpty ? "gpt-realtime-2" : realtime.modelOrDeployment
        }
        do {
            try await agentClient.send(PickyCommandEnvelope(
                type: .configureMainRealtimeAuth,
                provider: realtime.provider.protocolValue,
                apiKey: realtime.apiKey,
                modelOrDeployment: modelOrDeployment,
                voice: realtime.voice.isEmpty ? "marin" : realtime.voice,
                reasoningEffort: realtime.reasoningEffort.rawValue,
                transcriptionLanguage: realtime.transcriptionLanguage.isEmpty ? nil : realtime.transcriptionLanguage,
                azure: azureConfig
            ))
            print("🎛️ Realtime main agent configured — provider: \(realtime.provider.rawValue), model: \(modelOrDeployment)")
        } catch {
            print("⚠️ Failed to configure Realtime main agent: \(error.localizedDescription)")
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
        quickInputPanelManager.onVisibilityChange = { [weak self] isVisible in
            self?.isQuickInputPanelVisible = isVisible
            if !isVisible, self?.inkOverlayState.source == .text {
                self?.cancelInkCapture()
            }
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
        if !quickInputPanelManager.isPanelVisible {
            beginInkCapture(source: .text)
        }
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
            let inkCapture = self.finishInkCaptureForDeferredTextSubmission()
            let success = await self.sendDirectMessage(text, source: .quickInput, inkCapture: inkCapture)
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
            let targetSessionID = normalizedVoiceFollowUpSessionID(selectionStore.hoveredVoiceFollowUpSessionID)
            let inputID = UUID()
            interactionVoiceInputID = inputID
            beginInkCapture(source: .voice)
            print("🎙️ Picky voice route — PTT pressed; storeHover=\(selectionStore.hoveredVoiceFollowUpSessionID ?? "<nil>") prevTask=\(currentResponseTask != nil)")
            setVoiceFollowUpSessionIDForCurrentUtterance(targetSessionID, caller: "PTT-pressed")
            interactionCoordinator.accept(
                .voicePressed(targetSessionID: targetSessionID),
                correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: targetSessionID, source: .voice)
            )

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isPickyCursorEnabled {
                setLocalOverlayReason(.activeVoiceInput, visible: true)
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
            if shouldUseRealtimeMainVoiceTurn(targetSessionID: targetSessionID) {
                beginRealtimeMainVoiceTurn(inputID: inputID)
                return
            }
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
            setLocalOverlayReason(.activeVoiceInput, visible: false)
            // Cancel the pending start task in case the user released the shortcut
            // before the async startPushToTalk had a chance to begin recording.
            // Without this, a quick press-and-release drops the release event and
            // leaves the waveform overlay stuck on screen indefinitely.
            PickyAnalytics.trackPushToTalkReleased()
            pendingKeyboardShortcutStartTask?.cancel()
            pendingKeyboardShortcutStartTask = nil
            if let interactionVoiceInputID {
                finishInkCapture(inputID: interactionVoiceInputID)
                interactionCoordinator.accept(
                    .voiceReleased(inputID: interactionVoiceInputID),
                    correlation: PickyInteractionCorrelation(inputID: interactionVoiceInputID, source: .voice)
                )
            } else {
                finishInkCapture(inputID: nil)
            }
            if realtimeVoiceInputID == interactionVoiceInputID {
                commitRealtimeMainVoiceTurn(inputID: interactionVoiceInputID)
            } else {
                buddyDictationManager.stopPushToTalkFromKeyboardShortcut()
            }
            if !buddyDictationManager.isDictationInProgress && realtimeVoiceInputID == nil {
                updateVoiceInputAudioSuppression(isVoiceInputActive: false)
            }
            updateVoicePresentation()
        case .none:
            break
        }
    }

    private func shouldUseRealtimeMainVoiceTurn(targetSessionID: String?) -> Bool {
        guard normalizedVoiceFollowUpSessionID(targetSessionID) == nil else { return false }
        return PickySettingsStore().load().mainAgentRuntimeMode == .openAIRealtime
    }

    private func beginRealtimeMainVoiceTurn(inputID: UUID) {
        let settings = PickySettingsStore().load()
        let realtime = settings.openAIRealtime.normalized()
        guard !realtime.apiKey.isEmpty else {
            interactionCoordinator.accept(
                .voiceStartFailed(message: "OpenAI Realtime API key is required.", inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )
            finishAwaitingAgentResponse(visibleText: "OpenAI Realtime API key가 필요합니다. Settings에서 입력해 주세요.", spokenText: nil)
            completeVoiceInteractionIfCurrent(inputID: inputID)
            return
        }

        realtimeVoiceInputID = inputID
        realtimeCanSendAudio = false
        realtimeBufferedAudioChunks.removeAll()
        realtimeOutputTranscriptByInputID.removeAll()
        currentResponseTask?.cancel()
        beginAwaitingAgentResponse(recognizedTranscript: nil)

        do {
            try realtimeVoiceInputManager.start(inputID: inputID) { [weak self] data in
                Task { @MainActor [weak self] in
                    self?.sendRealtimeAudioChunk(data, inputID: inputID)
                }
            }
        } catch {
            realtimeVoiceInputID = nil
            interactionCoordinator.accept(
                .voiceStartFailed(message: error.localizedDescription, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )
            finishAwaitingAgentResponse(visibleText: "Realtime microphone start failed: \(error.localizedDescription)", spokenText: nil)
            return
        }

        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                await configureRealtimeMainAgent(settings: settings)
                guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                    transcript: "",
                    source: "voice",
                    selectedSessionID: nil,
                    inkCapture: nil
                ) else {
                    throw PickyRealtimeVoiceError.contextCaptureReturnedNil
                }
                guard !Task.isCancelled, realtimeVoiceInputID == inputID else { return }
                try await agentClient.send(PickyCommandEnvelope(
                    type: .beginMainRealtimeVoiceTurn,
                    context: captureResult.contextPacket,
                    inputId: inputID
                ))
                realtimeCanSendAudio = true
                flushBufferedRealtimeAudio(inputID: inputID)
            } catch is CancellationError {
                // Superseded by a newer utterance.
            } catch {
                realtimeVoiceInputID = nil
                realtimeCanSendAudio = false
                realtimeVoiceInputManager.stop()
                interactionCoordinator.accept(
                    .transcriptFailed(message: error.localizedDescription, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                )
                finishAwaitingAgentResponse(visibleText: "Realtime turn failed: \(error.localizedDescription)", spokenText: nil)
                completeVoiceInteractionIfCurrent(inputID: inputID)
            }
        }
    }

    private func sendRealtimeAudioChunk(_ data: Data, inputID: UUID) {
        guard realtimeVoiceInputID == inputID else { return }
        guard realtimeCanSendAudio else {
            realtimeBufferedAudioChunks.append(data)
            return
        }
        let audioBase64 = data.base64EncodedString()
        Task { [agentClient] in
            try? await agentClient.send(PickyCommandEnvelope(
                type: .appendMainRealtimeInputAudio,
                inputId: inputID,
                audioBase64: audioBase64
            ))
        }
    }

    private func flushBufferedRealtimeAudio(inputID: UUID) {
        guard realtimeVoiceInputID == inputID, realtimeCanSendAudio else { return }
        let chunks = realtimeBufferedAudioChunks
        realtimeBufferedAudioChunks.removeAll()
        for chunk in chunks {
            sendRealtimeAudioChunk(chunk, inputID: inputID)
        }
    }

    private func commitRealtimeMainVoiceTurn(inputID: UUID?) {
        guard let inputID, realtimeVoiceInputID == inputID else { return }
        realtimeVoiceInputManager.stop()
        beginAwaitingAgentResponse(recognizedTranscript: currentVoicePromptPreview)
        interactionCoordinator.accept(
            .agentSubmissionAccepted(contextID: nil, sessionID: "picky-main-agent", inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: "picky-main-agent", source: .agent)
        )
        let inkCapture = consumePendingInkCapture(inputID: inputID)
        let beginTask = currentResponseTask
        Task { @MainActor [weak self, agentClient] in
            do {
                await beginTask?.value
                guard self?.realtimeVoiceInputID == inputID else { return }
                let contextPacket: PickyContextPacket?
                if let inkCapture {
                    let captureResult = try await self?.voiceContextCaptureCoordinator.captureContext(
                        transcript: "",
                        source: "voice",
                        selectedSessionID: nil,
                        inkCapture: inkCapture
                    )
                    contextPacket = captureResult?.contextPacket
                } else {
                    contextPacket = nil
                }
                try await agentClient.send(PickyCommandEnvelope(
                    type: .commitMainRealtimeVoiceTurn,
                    context: contextPacket,
                    inputId: inputID
                ))
            } catch {
                print("⚠️ Failed to commit realtime voice turn: \(error.localizedDescription)")
            }
        }
    }

    private func cancelRealtimeMainVoiceTurn(inputID: UUID? = nil) {
        let playedAudioMs = realtimeAudioPlaybackEngine.stopAndReturnPlayedAudioMs()
        realtimeVoiceInputManager.stop()
        realtimeVoiceInputID = nil
        realtimeCanSendAudio = false
        realtimeBufferedAudioChunks.removeAll()
        Task { [agentClient] in
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .cancelMainRealtimeVoiceTurn,
                    inputId: inputID,
                    playedAudioMs: playedAudioMs
                ))
            } catch {
                print("⚠️ Failed to cancel realtime voice turn: \(error.localizedDescription)")
            }
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

        let voiceFollowUpSessionID = voiceFollowUpSessionIDForCurrentUtterance
        let inputID: UUID
        if let interactionVoiceInputID {
            inputID = interactionVoiceInputID
        } else {
            inputID = UUID()
            interactionVoiceInputID = inputID
            interactionCoordinator.accept(
                .voicePressed(targetSessionID: voiceFollowUpSessionID),
                correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: voiceFollowUpSessionID, source: .voice)
            )
            interactionCoordinator.accept(
                .voiceReleased(inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )
        }
        print("🎙️ Picky voice route — transcript finalized; captured=\(voiceFollowUpSessionID ?? "<nil>")")
        interactionCoordinator.accept(
            .transcriptFinal(text: transcript, inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: voiceFollowUpSessionID, source: .voice)
        )
    }

    func routeVoiceTranscript(
        transcript: String,
        contextPacket: PickyContextPacket,
        voiceFollowUpSessionID: String? = nil
    ) async throws -> PickyAgentSubmissionReceipt {
        if let targetSessionID = normalizedVoiceFollowUpSessionID(voiceFollowUpSessionID) {
            print("🎙️ Picky voice route — FOLLOW-UP side=\(targetSessionID)")
            try await agentClient.send(PickyCommandEnvelope(type: .followUp, context: contextPacket, sessionId: targetSessionID, text: transcript))
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        }
        print("🎙️ Picky voice route — SUBMIT main (arg=\(voiceFollowUpSessionID ?? "<nil>") self=\(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>"))")
        return try await agentClient.submit(PickyAgentSubmission(transcript: transcript, context: contextPacket))
    }

    // Internal (instead of private) so PickyCompanionManagerTests can seed the
    // utterance-scoped hover ID exactly the way the PTT pressed handler does.
    func setVoiceFollowUpSessionIDForCurrentUtterance(_ sessionID: String?, caller: String = #function) {
        let normalized = normalizedVoiceFollowUpSessionID(sessionID)
        guard voiceFollowUpSessionIDForCurrentUtterance != normalized else { return }
        print("🎙️ Picky voice route — hoverID \(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>") -> \(normalized ?? "<nil>") (from \(caller))")
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
    func sendDirectMessage(_ text: String, source: PickyInteractionSource = .text, inkCapture: PickyInkCapture? = nil) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        directMessageError = nil
        let inputID = UUID()
        if let inkCapture, inkCapture.hasVisibleInk {
            pendingInkCapturesByInputID[inputID] = inkCapture
        }
        return await withCheckedContinuation { continuation in
            directMessageContinuations[inputID] = continuation
            interactionCoordinator.accept(
                .textSubmitted(text: trimmedText, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: source)
            )
        }
    }

    private func applyInteractionProjection(_ projection: PickyInteractionProjection) {
        isSendingDirectMessage = projection.hasPendingTextSubmission
        setInteractionOverlayReasons(from: projection.state.overlay)

        switch projection.state.output {
        case .showingTextReply:
            clearPendingAgentResponseTiming()
            if let latestDisplayText = projection.latestDisplayText {
                latestAgentSessionSummary = latestDisplayText
            }
        case .speaking(_, let speechID, _, _, _, _):
            clearPendingAgentResponseTiming()
            interactionSpeechID = speechID
            if let latestDisplayText = projection.latestDisplayText {
                latestAgentSessionSummary = latestDisplayText
            }
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            voiceState = .responding
        case .idle:
            break
        case .suppressedReply:
            clearPendingAgentResponseTiming()
        case .waitingForAgent:
            if projection.isWaitingForCursorResponse {
                voiceState = .processing
            }
        }

        // Safety net: any path that leaves the cursor in `.responding` while the
        // projection is no longer speaking must clear the responding state, otherwise
        // the cursor response bubble lingers indefinitely.
        //
        // The reducer cleans up `.speaking` when transitioning to a non-`.speaking`
        // output (stopSpeech effect + speakingResponse overlay drop), so under normal
        // flow this guard is paired with the reducer-side preemption. It also catches
        // edge cases the reducer might miss: the `.speaking → .idle` direct path via
        // `.speechFinished`, voicePressed-driven cleanup, and any future event that
        // forgets to call `preemptSpeakingOutputIfNeeded`.
        //
        // Gated by `interactionSpeechID != nil` so a `speakSystemMessage` flow (which
        // sets `voiceState = .responding` without a corresponding `.speaking` projection)
        // is never clipped by an unrelated projection update.
        if voiceState == .responding, !projection.isSpeaking, interactionSpeechID != nil {
            voiceState = .idle
            interactionSpeechID = nil
            scheduleTransientHideIfNeeded()
        }
    }

    private func clearPendingAgentResponseTiming() {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        pendingAgentResponseStartedAt = nil
    }

    private func isInteractionTextReply(_ output: PickyOutputPhase) -> Bool {
        switch output {
        case .showingTextReply:
            true
        case .idle, .waitingForAgent, .speaking, .suppressedReply:
            false
        }
    }

    private func interactionOwner(for contextID: String) -> PickyContextOwner? {
        interactionCoordinator.projection.state.contextOwnership[contextID]
    }

    private func completeDirectMessage(inputID: UUID, success: Bool) {
        directMessageContinuations.removeValue(forKey: inputID)?.resume(returning: success)
    }

    private func failDirectMessage(inputID: UUID, message: String) {
        directMessageError = "메시지를 보내지 못했어요: \(message)"
        latestAgentSessionSummary = directMessageError
        completeDirectMessage(inputID: inputID, success: false)
    }

    fileprivate func runCaptureTextContextEffect(inputID: UUID, text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let inkCapture = consumePendingInkCapture(inputID: inputID)
                guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(transcript: text, source: "text", inkCapture: inkCapture) else {
                    interactionCoordinator.effectCompleted(
                        .textSubmissionFailed(message: "Context capture returned no packet.", inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .text)
                    )
                    failDirectMessage(inputID: inputID, message: "Context capture returned no packet.")
                    return
                }
                interactionCoordinator.effectCompleted(
                    .textContextCaptured(inputID: inputID, context: captureResult.contextPacket),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: captureResult.contextPacket.id, source: .text)
                )
            } catch {
                let message = error.localizedDescription
                interactionCoordinator.effectCompleted(
                    .textSubmissionFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .text)
                )
                failDirectMessage(inputID: inputID, message: message)
            }
        }
    }

    fileprivate func runSubmitTextEffect(inputID: UUID, context: PickyContextPacket, text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                _ = try await agentClient.submit(PickyAgentSubmission(transcript: text, context: context))
                PickyAnalytics.trackUserMessageSent(transcript: text)
                interactionCoordinator.effectCompleted(
                    .textSubmissionAccepted(contextID: context.id, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, source: .agent)
                )
                completeDirectMessage(inputID: inputID, success: true)
            } catch {
                let message = error.localizedDescription
                interactionCoordinator.effectCompleted(
                    .textSubmissionFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, source: .agent)
                )
                failDirectMessage(inputID: inputID, message: message)
            }
        }
    }

    fileprivate func runCaptureVoiceContextEffect(inputID: UUID, transcript: String, targetSessionID: String?) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let inkCapture = consumePendingInkCapture(inputID: inputID)
                guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                    transcript: transcript,
                    voiceFollowUpSessionID: targetSessionID,
                    inkCapture: inkCapture
                ) else {
                    guard !Task.isCancelled else { return }
                    interactionCoordinator.effectCompleted(
                        .transcriptFailed(message: "Context capture returned no packet.", inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                    )
                    if completeVoiceInteractionIfCurrent(inputID: inputID) {
                        setVoiceFollowUpSessionIDForCurrentUtterance(nil)
                    }
                    return
                }
                guard !Task.isCancelled else { return }
                interactionCoordinator.effectCompleted(
                    .voiceContextCaptured(
                        inputID: inputID,
                        transcript: transcript,
                        context: captureResult.contextPacket,
                        targetSessionID: targetSessionID
                    ),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: captureResult.contextPacket.id, source: .voice)
                )
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                let message = error.localizedDescription
                PickyAnalytics.trackResponseError(error: message)
                print("⚠️ Picky context capture error: \(error)")
                interactionCoordinator.effectCompleted(
                    .transcriptFailed(message: message, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                )
                finishAwaitingAgentResponse(visibleText: "I captured that, but the local agent client is not ready yet.", spokenText: "I captured that, but the local agent client is not ready yet.")
                completeVoiceInteractionIfCurrent(inputID: inputID)
            }
        }
    }

    fileprivate func runSubmitMainEffect(inputID: UUID, transcript: String, context: PickyContextPacket) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let receipt = try await agentClient.submit(PickyAgentSubmission(transcript: transcript, context: context))
                guard !Task.isCancelled else { return }
                PickyAnalytics.trackUserMessageSent(transcript: transcript)
                interactionCoordinator.effectCompleted(
                    .agentSubmissionAccepted(contextID: context.id, sessionID: receipt.sessionID, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: receipt.sessionID, source: .agent)
                )
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice")
                finishVoiceSubmissionIfIdle(inputID: inputID)
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
            }
        }
    }

    fileprivate func runFollowUpSideEffect(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await agentClient.send(PickyCommandEnvelope(type: .followUp, context: context, sessionId: sessionID, text: transcript))
                guard !Task.isCancelled else { return }
                let receipt = PickyAgentSubmissionReceipt(sessionID: sessionID, message: "")
                interactionCoordinator.effectCompleted(
                    .agentSubmissionAccepted(contextID: context.id, sessionID: sessionID, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: sessionID, source: .agent)
                )
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice-follow-up")
                finishVoiceSubmissionIfIdle(inputID: inputID)
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
            }
        }
    }

    private func handleVoiceSubmissionFailure(_ error: Error, inputID: UUID, contextID: String?) {
        let message = error.localizedDescription
        PickyAnalytics.trackResponseError(error: message)
        print("⚠️ Picky agent submission error: \(error)")
        interactionCoordinator.effectCompleted(
            .transcriptFailed(message: message, inputID: inputID),
            correlation: PickyInteractionCorrelation(inputID: inputID, contextID: contextID, source: .agent)
        )
        finishAwaitingAgentResponse(visibleText: "I captured that, but the local agent client is not ready yet.", spokenText: "I captured that, but the local agent client is not ready yet.")
        if completeVoiceInteractionIfCurrent(inputID: inputID) {
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "voice-submission-failure")
        }
    }

    private func finishVoiceSubmissionIfIdle(inputID: UUID) {
        let completedCurrentInput = completeVoiceInteractionIfCurrent(inputID: inputID)
        print("🎙️ Picky voice route — responseTask end; cancelled=\(Task.isCancelled) selfBeforeReset=\(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>")")
        if completedCurrentInput {
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "responseTask-end")
        }
        if !Task.isCancelled, pendingAgentResponseStartedAt == nil, voiceState != .responding {
            voiceState = .idle
            scheduleTransientHideIfNeeded()
        }
    }

    @discardableResult
    private func completeVoiceInteractionIfCurrent(inputID: UUID) -> Bool {
        guard interactionVoiceInputID == inputID else { return false }
        interactionVoiceInputID = nil
        return true
    }

    fileprivate func runMinimumDisplayTimerEffect(timerID: UUID, speechID: UUID?, inputID: UUID?, delay: TimeInterval) {
        Task { @MainActor [weak self] in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            self?.interactionCoordinator.effectCompleted(
                .minimumDisplayTimerFired(timerID: timerID, speechID: speechID, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, speechID: speechID, source: .system)
            )
        }
    }

    fileprivate func runSpeakEffect(speechID: UUID, text: String, contextID: String?) {
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        startOrDeferInteractionSpeech(speechID: speechID, text: text, contextID: contextID, requestedAt: Date())
    }

    private func startOrDeferInteractionSpeech(speechID: UUID, text: String, contextID: String?, requestedAt: Date) {
        guard isCurrentInteractionSpeechOutput(speechID) else { return }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            let elapsed = Date().timeIntervalSince(requestedAt)
            guard elapsed < Self.deferredSpeechMaximumWait else {
                interactionCoordinator.effectCompleted(
                    .speechFailed(speechID: speechID),
                    correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
                )
                return
            }

            deferredInteractionSpeechTask?.cancel()
            deferredInteractionSpeechTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.deferredSpeechRetryInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run { [weak self] in
                    self?.startOrDeferInteractionSpeech(speechID: speechID, text: text, contextID: contextID, requestedAt: requestedAt)
                }
            }
            return
        }

        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        stopCurrentSpeech()
        activeSpeechID = speechID
        interactionSpeechID = speechID
        voiceState = .responding

        #if DEBUG
        print("🔊 Picky TTS start — id: \(speechID), provider: \(speechPlaybackProvider.displayName), chars: \(text.count)")
        #endif
        guard speechPlaybackProvider.speak(text, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: didFinish, contextID: contextID)
            }
        }) else {
            handleInteractionSpeechFinished(speechID: speechID, didFinish: false, contextID: contextID)
            return
        }

        responseStateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let shouldFinish = await MainActor.run { [weak self] in
                    guard let self, self.activeSpeechID == speechID else { return false }
                    return !self.speechPlaybackProvider.isSpeaking
                }
                guard shouldFinish else { continue }
                await MainActor.run { [weak self] in
                    self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: true, contextID: contextID)
                }
                return
            }
        }
    }

    private func isCurrentInteractionSpeechOutput(_ speechID: UUID) -> Bool {
        if case .speaking(_, let currentSpeechID, _, _, _, _) = interactionCoordinator.projection.state.output {
            return currentSpeechID == speechID
        }
        return false
    }

    private func handleInteractionSpeechFinished(speechID: UUID, didFinish: Bool, contextID: String?) {
        guard activeSpeechID == speechID else { return }
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        #if DEBUG
        print("🔊 Picky TTS finish — id: \(speechID)")
        #endif
        interactionCoordinator.effectCompleted(
            didFinish ? .speechFinished(speechID: speechID) : .speechFailed(speechID: speechID),
            correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
        )
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
                    try? await self.agentClient.send(PickyCommandEnvelope(type: .listMainAgentModels))
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
            let owner = interactionOwner(for: reply.contextId)
            let originSource = reply.originSource ?? owner.map { $0.isVoiceOwned ? .voice : .text }
            let replyKind = reply.replyKind ?? .main
            if owner != nil || originSource != nil || reply.replyKind != nil {
                interactionCoordinator.accept(
                    .quickReply(
                        contextID: reply.contextId,
                        text: reply.text,
                        originSource: originSource,
                        replyKind: replyKind,
                        sessionID: reply.sessionId,
                        inputID: reply.inputId
                    ),
                    correlation: PickyInteractionCorrelation(contextID: reply.contextId, sessionID: reply.sessionId, source: .agent)
                )
            } else {
                let spoken = stripParentheticalsForSpeech(reply.text)
                finishAwaitingAgentResponse(visibleText: reply.text, spokenText: spoken, enforceMinimumProcessingDuration: true)
            }
        case .mainMessagesSnapshot(let messages):
            mainAgentMessages = Array(messages.suffix(100))
        case .mainMessageAppended(let message):
            mainAgentMessages = Array((mainAgentMessages + [message]).suffix(100))
        case .mainAgentModelsSnapshot(let models):
            mainAgentModelOptions = models
            isLoadingMainAgentModelOptions = false
        case .mainRealtimeStateChanged(let event):
            applyMainRealtimeState(event)
        case .mainRealtimeInputTranscriptDelta(let inputId, let delta):
            guard realtimeVoiceInputID == inputId else { break }
            let updated = (currentVoicePromptPreview ?? "") + delta
            currentVoicePromptPreview = updated
            voicePromptBubbleState = .recognized(updated)
        case .mainRealtimeInputTranscriptCompleted(let inputId, let transcript):
            guard realtimeVoiceInputID == inputId else { break }
            lastTranscript = transcript
            currentVoicePromptPreview = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : transcript
            voicePromptBubbleState = transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .hidden : .recognized(transcript)
        case .mainRealtimeOutputAudioDelta(_, let audioBase64):
            stopCurrentSpeech()
            hideVoicePromptBubbleForRealtimeResponse()
            realtimeAudioPlaybackEngine.enqueuePCM16Base64(audioBase64)
            clearPendingAgentResponseTiming()
            voiceState = .responding
        case .mainRealtimeOutputAudioDone:
            break
        case .mainRealtimeOutputTranscriptDelta(let inputId, let delta):
            hideVoicePromptBubbleForRealtimeResponse()
            let key = inputId ?? realtimeVoiceInputID ?? UUID()
            let updated = (realtimeOutputTranscriptByInputID[key] ?? "") + delta
            realtimeOutputTranscriptByInputID[key] = updated
            latestAgentSessionSummary = updated
        case .mainRealtimeOutputTranscriptCompleted(let inputId, let transcript):
            hideVoicePromptBubbleForRealtimeResponse()
            let key = inputId ?? realtimeVoiceInputID ?? UUID()
            realtimeOutputTranscriptByInputID[key] = transcript
            latestAgentSessionSummary = transcript
            realtimeOutputTranscriptByInputID.removeValue(forKey: key)
        case .mainRealtimeTurnDone(let done):
            if let inputId = done.inputId {
                realtimeOutputTranscriptByInputID.removeValue(forKey: inputId)
                if realtimeVoiceInputID == inputId {
                    realtimeVoiceInputID = nil
                    realtimeCanSendAudio = false
                    realtimeBufferedAudioChunks.removeAll()
                    completeVoiceInteractionIfCurrent(inputID: inputId)
                }
            }
            if let final = done.finalTranscript, !final.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                latestAgentSessionSummary = final
            }
            if !realtimeAudioPlaybackEngine.isPlaying {
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        case .pointerOverlayRequested(let request):
            applyPointerOverlayRequest(request)
        case .error(let error):
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
        case .hello, .sessionSnapshot, .artifactUpdated, .slashCommandsSnapshot, .unknown,
             .sessionMessageAppended, .sessionMessageReplaced, .sessionMessageRemoved, .sessionQueueUpdated, .sessionActivityUpdated, .terminalSessionSyncOutcome:
            break
        }
    }

    private func hideVoicePromptBubbleForRealtimeResponse() {
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
    }

    private func handleRealtimePlaybackDrained() {
        guard realtimeVoiceInputID == nil else { return }
        guard voiceState == .responding else { return }
        voiceState = .idle
        scheduleTransientHideIfNeeded()
    }

    private func applyMainRealtimeState(_ event: PickyMainRealtimeStateEvent) {
        switch event.state {
        case .connecting:
            latestAgentSessionSummary = "Realtime 연결 중…"
            voiceState = .processing
        case .ready:
            if realtimeVoiceInputID == nil && !realtimeAudioPlaybackEngine.isPlaying {
                clearPendingAgentResponseTiming()
                voiceState = .idle
                scheduleTransientHideIfNeeded()
            }
        case .listening:
            voiceState = .listening
        case .thinking:
            latestAgentSessionSummary = "응답 준비 중…"
            voiceState = .processing
        case .speaking:
            clearPendingAgentResponseTiming()
            voiceState = .responding
        case .failed:
            clearPendingAgentResponseTiming()
            latestAgentSessionSummary = event.message ?? "Realtime main agent failed"
            voiceState = .idle
            realtimeVoiceInputID = nil
            realtimeCanSendAudio = false
            realtimeBufferedAudioChunks.removeAll()
            scheduleTransientHideIfNeeded()
        }
    }

    private func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            detectedElementPointerID = nil
            detectedElementDisplayFrame = target.displayFrame
            detectedElementBubbleText = target.bubbleText
            detectedElementDisplayDuration = target.duration
            detectedElementTargetFrame = nil
            detectedElementHighlightKind = .screenElement
            detectedElementScreenLocation = target.screenLocation
            detectedElementPointerID = request.id
            interactionCoordinator.accept(
                .pointerRequested(PickyPointerTarget(
                    id: request.id,
                    source: .agent,
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    bubbleText: target.bubbleText,
                    duration: target.duration,
                    targetFrame: nil,
                    highlightKind: .screenElement
                )),
                correlation: PickyInteractionCorrelation(pointerID: request.id, source: .pointer)
            )
            latestAgentSessionSummary = target.bubbleText.map { "가리키는 중: \($0)" } ?? "화면 위치를 가리키는 중…"

            setLocalOverlayReason(.activePointerAnimation, visible: true)
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
        guard !hasActiveTransientOverlayBlocker else { return }

        transientHideTask?.cancel()
        transientHideTask = Task {
            // Wait for pointing animation to finish (location is cleared
            // when the buddy flies back to the cursor)
            while detectedElementScreenLocation != nil || hasActiveTransientOverlayBlocker {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard !Task.isCancelled else { return }
            }

            // Pause 1s after everything finishes, then fade out
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, !hasActiveTransientOverlayBlocker else { return }
            localOverlayVisibilityReasons.removeAll()
            interactionOverlayVisibilityReasons.removeAll()
            syncOverlayVisibility(animatedHide: true)
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
        if PickySettingsStore().load().mainAgentRuntimeMode == .openAIRealtime {
            cancelRealtimeMainVoiceTurn(inputID: realtimeVoiceInputID)
            return
        }
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

    fileprivate func stopCurrentSpeech() {
        activeSpeechID = nil
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechPlaybackProvider.stopSpeaking()
    }

    fileprivate func stopCurrentInteractionSpeech(speechID requestedSpeechID: UUID?) {
        // Prefer the speechID the reducer explicitly preempted. Falling back
        // to interactionSpeechID/activeSpeechID covers legacy call sites that
        // didn't know which utterance was active (e.g., voicePressed when no
        // interaction speech was running, just a system status message).
        let speechID = requestedSpeechID ?? interactionSpeechID ?? activeSpeechID
        stopCurrentSpeech()
        guard let speechID else { return }
        interactionCoordinator.effectCompleted(
            .speechFailed(speechID: speechID),
            correlation: PickyInteractionCorrelation(speechID: speechID, source: .system)
        )
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

@MainActor
private final class CompanionInteractionEffectRunner: PickyInteractionEffectRunning {
    private weak var manager: CompanionManager?

    init(manager: CompanionManager) {
        self.manager = manager
    }

    func run(_ effects: [PickyInteractionEffect]) {
        for effect in effects {
            switch effect {
            case .captureTextContext(let inputID, let text):
                manager?.runCaptureTextContextEffect(inputID: inputID, text: text)
            case .submitText(let inputID, let context, let text):
                manager?.runSubmitTextEffect(inputID: inputID, context: context, text: text)
            case .captureVoiceContext(let inputID, let transcript, let targetSessionID):
                manager?.runCaptureVoiceContextEffect(inputID: inputID, transcript: transcript, targetSessionID: targetSessionID)
            case .submitMain(let inputID, let transcript, let context):
                manager?.runSubmitMainEffect(inputID: inputID, transcript: transcript, context: context)
            case .followUpSide(let inputID, let sessionID, let transcript, let context):
                manager?.runFollowUpSideEffect(inputID: inputID, sessionID: sessionID, transcript: transcript, context: context)
            case .scheduleMinimumDisplay(let timerID, let speechID, let inputID, let delay):
                manager?.runMinimumDisplayTimerEffect(timerID: timerID, speechID: speechID, inputID: inputID, delay: delay)
            case .speak(let speechID, let text, let contextID):
                manager?.runSpeakEffect(speechID: speechID, text: text, contextID: contextID)
            case .stopSpeech(_, let speechID):
                manager?.stopCurrentInteractionSpeech(speechID: speechID)
            case .recordContextOwnership, .startDictation, .stopDictation:
                break
            case .showOverlay, .scheduleTransientHide, .cancelTransientHide,
                 .startPointerAnimation, .cancelPointerAnimation:
                break
            }
        }
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
