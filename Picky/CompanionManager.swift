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
import OSLog
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

private enum PickySpeechPollResult {
    case speaking
    case finished
    case timedOut
    case inactive
}

@MainActor
protocol PickyInteractionTimerScheduling: AnyObject {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void)
}

@MainActor
private final class PickyTaskInteractionTimerScheduler: PickyInteractionTimerScheduling {
    func schedule(after delay: TimeInterval, operation: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, delay) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled else { return }
            operation()
        }
    }
}

/// The subset of persisted settings that changes the live STT/TTS providers.
/// Settings saves are global, so unrelated edits (for example the main model)
/// must not rebuild the voice stack or interrupt an active cursor reply.
private struct PickyVoiceProviderSettings: Equatable {
    let sttProvider: PickyVoiceProviderSelection
    let ttsProvider: PickyVoiceProviderSelection
    let ttsEnabled: Bool
    let edgeTTSVoice: String
    let azureOpenAIEndpoint: String
    let azureOpenAIAPIKey: String
    let azureOpenAITTSEndpoint: String
    let azureOpenAITTSAPIKey: String
    let azureOpenAITTSVoice: String
    let azureSTTPreferredLanguage: String
    let openAITTSAPIKey: String
    let openAITTSVoice: String
    let openAITTSModel: String
    let openAISTTAPIKey: String
    let openAISTTModel: String
    let openAISTTPreferredLanguage: String
    let openAITTSBaseURL: String
    let openAISTTBaseURL: String
    let elevenLabsTTSAPIKey: String
    let elevenLabsTTSVoiceID: String
    let elevenLabsTTSModel: String
    let elevenLabsTTSOutputFormat: String
    let elevenLabsTTSBaseURL: String
    let elevenLabsSTTAPIKey: String
    let elevenLabsSTTModel: String
    let elevenLabsSTTLanguage: String

    init(_ settings: PickySettings) {
        sttProvider = settings.sttProvider
        ttsProvider = settings.ttsProvider
        ttsEnabled = settings.ttsEnabled
        edgeTTSVoice = settings.edgeTTSVoice
        azureOpenAIEndpoint = settings.azureOpenAIEndpoint
        azureOpenAIAPIKey = settings.azureOpenAIAPIKey
        azureOpenAITTSEndpoint = settings.azureOpenAITTSEndpoint
        azureOpenAITTSAPIKey = settings.azureOpenAITTSAPIKey
        azureOpenAITTSVoice = settings.azureOpenAITTSVoice
        azureSTTPreferredLanguage = settings.azureSTTPreferredLanguage
        openAITTSAPIKey = settings.openAITTSAPIKey
        openAITTSVoice = settings.openAITTSVoice
        openAITTSModel = settings.openAITTSModel
        openAISTTAPIKey = settings.openAISTTAPIKey
        openAISTTModel = settings.openAISTTModel
        openAISTTPreferredLanguage = settings.openAISTTPreferredLanguage
        openAITTSBaseURL = settings.openAITTSBaseURL
        openAISTTBaseURL = settings.openAISTTBaseURL
        elevenLabsTTSAPIKey = settings.elevenLabsTTSAPIKey
        elevenLabsTTSVoiceID = settings.elevenLabsTTSVoiceID
        elevenLabsTTSModel = settings.elevenLabsTTSModel
        elevenLabsTTSOutputFormat = settings.elevenLabsTTSOutputFormat
        elevenLabsTTSBaseURL = settings.elevenLabsTTSBaseURL
        elevenLabsSTTAPIKey = settings.elevenLabsSTTAPIKey
        elevenLabsSTTModel = settings.elevenLabsSTTModel
        elevenLabsSTTLanguage = settings.elevenLabsSTTLanguage
    }
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
    // Internal (not private) so tests can derive waits from the real value
    // instead of hardcoding sleeps tuned to it.
    static let minimumVoiceProcessingDisplayDuration: TimeInterval = 1.0
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
    /// Most recent Picky main-agent Pi session location reported by
    /// picky-agentd. Used by the Status → Recent conversation sub-page to expose "Open in Pi" / "Copy
    /// resume command" affordances so users can drop into a real Pi TUI
    /// against the same session file the daemon is driving. Both fields can be
    /// nil before the daemon has started a real Pi session for the main agent.
    @Published private(set) var mainAgentSessionInfo: PickyMainAgentSessionInfo = .init()
    @Published private(set) var isSendingDirectMessage = false
    @Published private(set) var isResettingMainAgentSession = false
    @Published private(set) var directMessageError: String?
    @Published private(set) var currentAudioPowerLevel: CGFloat = 0
    @Published private(set) var hasAccessibilityPermission = false
    @Published private(set) var hasScreenRecordingPermission = false
    @Published private(set) var hasMicrophonePermission = false
    @Published private(set) var hasScreenContentPermission = false
    /// Developer override: when `PICKY_FORCE_PERMISSIONS_MISSING=1` is set, every
    /// macOS permission flag is reported as false regardless of the actual system
    /// state, so the panel renders the full setup surface without anyone having
    /// to revoke real permissions. The underlying side effects (PTT monitor,
    /// screen capture) still follow real macOS state because there's no safe way
    /// to simulate a denial there. Mirrors `PICKY_AGENTD_RUNTIME=mock`.
    private let forcePermissionsMissing: Bool = ProcessInfo.processInfo.environment["PICKY_FORCE_PERMISSIONS_MISSING"] == "1"
    /// Onboarding-only: when set, every voice / text submission path consults
    /// this closure first. Returning a non-nil receipt fakes a successful submit
    /// without touching the real agent client — the cursor still shows the
    /// transcript, the user still hears the full Picky experience, but no real
    /// Pi call goes out. The onboarding flow controller installs this on entry
    /// and clears it on exit.
    var submissionInterceptor: (@MainActor (PickyAgentSubmission) async -> PickyAgentSubmissionReceipt?)?

    /// Onboarding-only: when true, the real shortcut handlers (PTT mic kick-off
    /// and Quick Input panel) bail out. The onboarding narrates 'I'll drive'
    /// and the user is told to just watch, so a stray hotkey press should not
    /// pop the real pill or arm the dictation pipeline underneath the demo.
    /// Toggled by OnboardingFlowController on enter/exit.
    var isShortcutHandlingSuppressed: Bool = false

    /// Onboarding-only: when non-nil, BlueCursorView renders this as a guide
    /// bubble pinned to the cursor. The onboarding flow controller updates it
    /// per beat to walk the user through the demo without a takeover panel.
    @Published var onboardingBubbleText: String?

    /// Toggle the onboarding-active overlay reason from outside CompanionManager
    /// so the flow controller can keep the Picky cursor visible during the demo
    /// independent of the user's cursor preference, then revert when done.
    func setOnboardingOverlayVisibility(_ visible: Bool) {
        setLocalOverlayReason(.onboardingActive, visible: visible)
    }

    /// Programmatically arm ink capture so the next click-and-drag becomes a
    /// drawing. Used by the onboarding flow to invite the user to circle a
    /// region on the page without first going through the Quick Input panel
    /// path. No-op if ink capture is already running.
    func beginOnboardingInkCapture() {
        guard !inkCaptureCoordinator.isActive else { return }
        beginInkCapture(source: .text)
    }

    /// Cancels onboarding ink capture if the user abandons the gesture or the
    /// flow is skipped. Mirrors `beginOnboardingInkCapture()` so teardown can
    /// leave ink state clean.
    func cancelOnboardingInkCapture() {
        if inkCaptureCoordinator.isActive {
            cancelInkCapture()
        }
    }
    @Published private(set) var mainAgentModelOptions: [PickyMainAgentModelOption] = []
    @Published private(set) var isLoadingMainAgentModelOptions = false
    @Published private(set) var screenContextTargetSessionID: String?

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
    /// Resolved AI annotations, rendered independently from user ink and pointer animation.
    @Published private(set) var agentAnnotations: [PickyAgentAnnotation] = []
    /// Most recent main-agent context submitted by this app and the newest overlay
    /// generation accepted for it. Overlay events from an older capture must not
    /// guide the user against a newer desktop state.
    private var latestOverlayContextID: String?
    private var latestOverlayContextGeneration = 0

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let quickInputDoubleTapDetector = QuickInputDoubleTapDetector()
    let quickInputPanelManager: QuickInputPanelManager
    // Response text is now displayed inline on the cursor overlay via
    // streamingResponseText, so no separate response overlay manager is needed.

    /// Both events (`agentClient.events`) and outbound commands
    /// (`agentClient.send` / `agentClient.submit`) flow through a single
    /// `PickyAgentClient`. In production this is the shared
    /// `PickyAgentClientRouter` so session-scoped commands (steer, followUp,
    /// abort…) reach the right child daemon for sessions that live outside
    /// the primary daemon, AND so server-side unicast responses to
    /// Companion-issued requests (e.g. `listMainAgentModels`) arrive on the
    /// same connection Companion is listening on. The router's multi-
    /// subscriber events stream lets the HUD viewModel subscribe to the
    /// same instance without fighting over a single AsyncStream consumer.
    private let agentClient: any PickyAgentClient
    /// `true` when `CompanionManager` owns the `agentClient` and is
    /// responsible for its lifecycle. `false` when the client is shared
    /// with another owner (in production the HUD's
    /// `hudAgentClientRouter`) — in that case `stop()` must NOT disconnect,
    /// otherwise it would tear down the primary daemon socket AND every
    /// cached child connection out from under the HUD viewModel. Tests
    /// and headless harnesses that pass their own fake client take the
    /// default (`true`) so the existing teardown behavior is preserved.
    private let ownsAgentClientLifecycle: Bool
    private let selectionStore: PickySessionSelectionStoring
    private let transcriptionProviderFactory: (PickySettings) -> any BuddyTranscriptionProvider
    private let speechPlaybackProviderFactory: (PickySettings) -> any PickySpeechPlaybackProvider
    private let interactionTimerScheduler: any PickyInteractionTimerScheduling
    private var speechPlaybackProvider: any PickySpeechPlaybackProvider
    private var appliedVoiceProviderSettings: PickyVoiceProviderSettings
    private var ttsPlaybackEnabled: Bool
    private let speechWatchdogTimeoutOverride: TimeInterval?
    private let voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator
    private var armedPickleDispatchMode: PickyArmedPickleDispatchMode

    init(
        agentClient: any PickyAgentClient = LocalStubPickyAgentClient(),
        ownsAgentClientLifecycle: Bool = true,
        selectionStore: PickySessionSelectionStoring = PickyUserDefaultsSessionSelectionStore.shared,
        buddyDictationManager: BuddyDictationManager? = nil,
        speechPlaybackProvider: (any PickySpeechPlaybackProvider)? = nil,
        initialSettings: PickySettings? = nil,
        transcriptionProviderFactory: ((PickySettings) -> any BuddyTranscriptionProvider)? = nil,
        speechPlaybackProviderFactory: ((PickySettings) -> any PickySpeechPlaybackProvider)? = nil,
        interactionTimerScheduler: (any PickyInteractionTimerScheduling)? = nil,
        voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator? = nil,
        inkCaptureCoordinator: any PickyInkCaptureCoordinating = PickyInkCaptureCenter.shared,
        appearanceStore: PickyAppearanceStore? = nil,
        fontScaleStore: PickyAppFontScaleStore? = nil,
        speechWatchdogTimeout: TimeInterval? = nil,
        armedPickleDispatchMode: PickyArmedPickleDispatchMode? = nil
    ) {
        let resolvedInitialSettings = initialSettings
            ?? Self.migrateLegacyCursorPreferenceIfNeeded(store: PickySettingsStore())
        self.isCursorPreferenceEnabled = resolvedInitialSettings.cursor.showPiCursor
        let resolvedTranscriptionProviderFactory = transcriptionProviderFactory
            ?? { BuddyTranscriptionProviderFactory.makeDefaultProvider(settings: $0) }
        let resolvedSpeechPlaybackProviderFactory = speechPlaybackProviderFactory
            ?? { PickySpeechPlaybackProviderFactory.makeDefaultProvider(settings: $0) }
        self.agentClient = agentClient
        self.ownsAgentClientLifecycle = ownsAgentClientLifecycle
        self.selectionStore = selectionStore
        self.transcriptionProviderFactory = resolvedTranscriptionProviderFactory
        self.speechPlaybackProviderFactory = resolvedSpeechPlaybackProviderFactory
        self.interactionTimerScheduler = interactionTimerScheduler ?? PickyTaskInteractionTimerScheduler()
        self.buddyDictationManager = buddyDictationManager ?? BuddyDictationManager(
            transcriptionProvider: resolvedTranscriptionProviderFactory(resolvedInitialSettings)
        )
        self.speechPlaybackProvider = speechPlaybackProvider ?? resolvedSpeechPlaybackProviderFactory(resolvedInitialSettings)
        self.appliedVoiceProviderSettings = PickyVoiceProviderSettings(resolvedInitialSettings)
        self.ttsPlaybackEnabled = speechPlaybackProvider == nil ? resolvedInitialSettings.ttsEnabled : true
        self.speechWatchdogTimeoutOverride = speechWatchdogTimeout
        self.voiceContextCaptureCoordinator = voiceContextCaptureCoordinator ?? PickyVoiceContextCaptureCoordinator()
        self.armedPickleDispatchMode = armedPickleDispatchMode ?? resolvedInitialSettings.armedPickleDispatchMode
        self.inkCaptureCoordinator = inkCaptureCoordinator
        self.quickInputPanelManager = QuickInputPanelManager(
            appearanceStore: appearanceStore,
            fontScaleStore: fontScaleStore
        )
        self.screenContextTargetSessionID = selectionStore.screenContextTargetSessionID
        self.inkCaptureCoordinator.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inkOverlayState = state
                self.setLocalOverlayReason(.activeInkCapture, visible: state.isActive)
                self.pushQuickInputScreenshotStateIfPanelVisible()
            }
        }
        self.inkCaptureCoordinator.shouldPassThroughMouseEvent = { [weak self] point, source in
            self?.shouldPassThroughInkMouseEvent(point: point, source: source) == true
        }
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    private var currentResponseTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?
    private var directMessageContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    private let inkCaptureCoordinator: any PickyInkCaptureCoordinating
    private var pendingInkCapturesByInputID: [UUID: PickyInkCapture] = [:]
    private var screenContextVoiceTargetByInputID: [UUID: String] = [:]
    /// Monotonic marker for observing when queued interaction events have published.
    private(set) var interactionProjectionSequence: UInt64 = 0
    private lazy var interactionCoordinator: PickyInteractionCoordinator = {
        let coordinator = PickyInteractionCoordinator(
            envelopeMaker: PickyInteractionStaticEnvelopeMaker(),
            effectRunner: CompanionInteractionEffectRunner(manager: self)
        )
        coordinator.onProjectionPublished = { [weak self] sequence, projection in
            self?.interactionProjectionSequence = sequence
            self?.applyInteractionProjection(projection)
        }
        return coordinator
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var quickInputDoubleTapCancellable: AnyCancellable?
    private var screenContextTargetCancellable: AnyCancellable?
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
    private var annotationExpiryTask: Task<Void, Never>?
    private var responseStateTask: Task<Void, Never>?
    private var deferredInteractionSpeechTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseSessionID: String?
    /// Caps how long the recognized-transcript bubble lingers after STT.
    private var voicePromptBubbleAutoHideTask: Task<Void, Never>?
    private var voiceInteractionState = PickyVoiceInteractionState()
    private var activeSpeechID: UUID?
    private var lastQuickReplyTTSDedupKey: String?
    private var lastQuickReplyTTSDedupAt: Date?
    private var interactionSpeechID: UUID?
    private var interactionVoiceInputID: UUID?
    /// Tracks the physical push-to-talk hold separately from dictation state so
    /// audio stays suppressed even if recording fails before the key is released.
    private var isPushToTalkShortcutHeld = false
    /// Suppresses local spoken audio while the user is starting, holding,
    /// or finalizing voice input. If a voice-owned reply arrives during the
    /// finalizing→idle transition, speech is deferred briefly rather than failed
    /// so fast agent replies are not dropped by the tail of the same utterance.
    private var isVoiceInputAudioSuppressionActive = false
    private var pendingAgentResponseStartedAt: Date?
    /// Tracks the last status we saw per session so `applyAgentEvent(.sessionUpdated)`
    /// can detect the *transition* into a terminal status (cancelled/failed/completed)
    /// rather than reacting on every snapshot. Used by the HUD-abort cursor-cleanup path:
    /// when a session the cursor is waiting on becomes terminal without a `quickReply`,
    /// CompanionManager releases the cursor processing state. Idempotent against
    /// duplicate terminal updates (the second one observes status == prior == terminal
    /// and short-circuits).
    private var lastObservedSessionStatuses: [String: PickySessionStatus] = [:]
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

    /// Everything the user needs in place before the panel hides its setup
    /// surface. Agent runtime health is reported by agentd itself rather than
    /// a separate local Pi executable probe.
    var allPrerequisitesMet: Bool {
        allPermissionsGranted
    }

    /// Whether the blue cursor overlay is currently visible on screen.
    /// Used by the panel to show accurate status text ("Active" vs "Ready").
    @Published private(set) var isOverlayVisible: Bool = false
    @Published private(set) var overlayVisibilityReasons: Set<PickyOverlayReason> = []
    @Published private(set) var isQuickInputPanelVisible: Bool = false
    @Published private(set) var isWaitingForCursorResponse: Bool = false
    @Published private(set) var inkOverlayState: PickyInkOverlayState = .inactive

    private var localOverlayVisibilityReasons: Set<PickyOverlayReason> = []
    private var interactionOverlayVisibilityReasons: Set<PickyOverlayReason> = []

    /// Whether the cursor overlay windows should exist at all. Sourced from
    /// Settings → Cursor → "Show Picky cursor" (`cursor.showPiCursor`) — the
    /// same key the rendering layer (`BlueCursorView`) reads — so the window
    /// lifecycle and rendering can never disagree. Refreshed on settings save.
    private var isCursorPreferenceEnabled: Bool

    /// One-shot migration: older builds gated the overlay *windows* behind a
    /// separate `isPickyCursorEnabled` UserDefaults key while Settings'
    /// `cursor.showPiCursor` only gated the *rendering*. Fold a legacy
    /// "disabled" value into the settings file (preserving what the user
    /// actually saw) and delete the key so `cursor.showPiCursor` becomes the
    /// single source of truth.
    static func migrateLegacyCursorPreferenceIfNeeded(
        store: PickySettingsStore,
        defaults: UserDefaults = .standard
    ) -> PickySettings {
        var settings = store.load()
        if defaults.object(forKey: "isPickyCursorEnabled") != nil {
            if !defaults.bool(forKey: "isPickyCursorEnabled") && settings.cursor.showPiCursor {
                settings.cursor.showPiCursor = false
                try? store.save(settings)
            }
            defaults.removeObject(forKey: "isPickyCursorEnabled")
        }
        return settings
    }

    /// Applies the "Show Picky cursor" preference to the overlay window
    /// lifecycle. Turning it off tears every overlay reason down immediately;
    /// turning it back on restores the always-on cursor once permissions allow.
    func applyCursorPreferenceFromSettings(_ settings: PickySettings) {
        let enabled = settings.cursor.showPiCursor
        guard enabled != isCursorPreferenceEnabled else { return }
        isCursorPreferenceEnabled = enabled
        transientHideTask?.cancel()
        transientHideTask = nil

        if enabled {
            if allPermissionsGranted {
                setLocalOverlayReason(.cursorPreferenceEnabled, visible: true)
            }
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
        bindScreenContextTarget()
        bindSettingsChanges()
        // Show the cursor as soon as all permissions are available and the
        // cursor preference is enabled.
        if allPermissionsGranted && isCursorPreferenceEnabled {
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
        annotationExpiryTask?.cancel()
        annotationExpiryTask = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        activeSpeechID = nil
        lastQuickReplyTTSDedupKey = nil
        lastQuickReplyTTSDedupAt = nil
        speechPlaybackProvider.stopSpeaking()
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        reduceVoiceInteraction(.reset)
        agentEventTask?.cancel()
        agentEventTask = nil
        // Only tear down the agentClient if Companion owns it. When the
        // client is shared (in production, the HUD's router) the owner is
        // responsible for `disconnect()` — calling it from here would
        // also kill the HUD viewModel's primary socket + every cached
        // child connection.
        if ownsAgentClientLifecycle {
            agentClient.disconnect()
        }
        shortcutTransitionCancellable?.cancel()
        quickInputDoubleTapCancellable?.cancel()
        screenContextTargetCancellable?.cancel()
        screenContextTargetCancellable = nil
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

        // UI-only simulation: flip every flag to false AFTER the real probe so
        // the analytics/grant-tracking branches above still see realistic
        // transitions during a normal launch, while the panel renders the
        // setup-needed state on next bind.
        if forcePermissionsMissing {
            hasAccessibilityPermission = false
            hasScreenRecordingPermission = false
            hasMicrophonePermission = false
            hasScreenContentPermission = false
        }

        if !previouslyHadAll && allPermissionsGranted {
            PickyAnalytics.trackAllPermissionsGranted()
            if isCursorPreferenceEnabled {
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
        guard !PickyRuntimeEnvironment.isRunningUnitTests else {
            print("🔑 Screen content permission request skipped during unit tests")
            return
        }
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

                    if allPermissionsGranted && isCursorPreferenceEnabled {
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

    private func shouldPassThroughInkMouseEvent(point: CGPoint, source: PickyInkCaptureSource) -> Bool {
        guard source == .text else { return false }
        if quickInputPanelManager.containsInteractiveGlobalPoint(point) { return true }
        return NSApp.windows.contains { window in
            guard window is PickyHUDPanel, window.isVisible else { return false }
            return window.frame.insetBy(dx: -8, dy: -8).contains(point)
        }
    }

    private func beginInkCapture(source: PickyInkCaptureSource) {
        interactionCoordinator.accept(.agentAnnotationsClearedForUserInput, correlation: PickyInteractionCorrelation(source: .text))
        if inkCaptureCoordinator.isActive {
            setLocalOverlayReason(.activeInkCapture, visible: true)
            return
        }
        if !inkCaptureCoordinator.begin(source: source) {
            setLocalOverlayReason(.activeInkCapture, visible: false)
        }
    }

    private func finishInkCapture(inputID: UUID?) {
        let capture = inkCaptureCoordinator.finish()
        if let inputID, let capture, capture.hasVisibleInk {
            pendingInkCapturesByInputID[inputID] = capture
        }
        setLocalOverlayReason(.activeInkCapture, visible: false)
    }

    private func finishInkCaptureForDeferredTextSubmission() -> PickyInkCapture? {
        let capture = inkCaptureCoordinator.finish()
        setLocalOverlayReason(.activeInkCapture, visible: false)
        return capture?.hasVisibleInk == true ? capture : nil
    }

    private func cancelInkCapture() {
        inkCaptureCoordinator.cancel()
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
        let blockers: Set<PickyOverlayReason> = [.activeVoiceInput, .waitingForVoiceResponse, .speakingResponse, .activePointerAnimation, .activeInkCapture, .screenContextTarget]
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
                self?.selectionStore.screenContextTargetSessionID = nil
                self?.applyScreenContextTarget(nil)
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
                print("⚠️ Failed to list Picky models: \(error.localizedDescription)")
            }
        }
    }

    private func bindSettingsChanges() {
        settingsChangeCancellable = NotificationCenter.default.publisher(for: .pickySettingsDidSave)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                let settings = PickySettingsStore().load()
                self?.applyCursorPreferenceFromSettings(settings)
                self?.reloadVoiceProvidersFromSettings(settings)
                self?.armedPickleDispatchMode = settings.armedPickleDispatchMode
                self?.syncDaemonSettings(settings)
                self?.applyShortcutSpecsFromSettings(settings)
                self?.pushQuickInputScreenshotStateIfPanelVisible()
            }
    }

    /// Pushes the persisted PTT/Quick Input shortcut specs into the live
    /// monitor and detector. Called on launch and whenever Settings saves.
    private func applyShortcutSpecsFromSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        globalPushToTalkShortcutMonitor.currentShortcutSpec = settings.pushToTalkShortcut
        quickInputDoubleTapDetector.currentShortcutSpec = settings.quickInputShortcut
        print("⌨️  Shortcuts applied — PTT: \(settings.pushToTalkShortcut), QuickInput: \(settings.quickInputShortcut)")
    }

    func reloadVoiceProvidersFromSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        let updatedVoiceProviderSettings = PickyVoiceProviderSettings(settings)
        guard updatedVoiceProviderSettings != appliedVoiceProviderSettings else { return }
        appliedVoiceProviderSettings = updatedVoiceProviderSettings

        buddyDictationManager.updateTranscriptionProvider(
            transcriptionProviderFactory(settings)
        )
        ttsPlaybackEnabled = settings.ttsEnabled
        if speechPlaybackProvider.isSpeaking {
            if let interactionSpeechID, isCurrentInteractionSpeechOutput(interactionSpeechID) {
                // Provider replacement is a real interruption. Settle the canonical
                // interaction state as well as the legacy voice presentation state so
                // a later projection cannot resurrect this reply bubble.
                stopCurrentInteractionSpeech(speechID: interactionSpeechID)
            } else {
                stopCurrentSpeech()
            }
        }
        speechPlaybackProvider = speechPlaybackProviderFactory(settings)
        print("🎛️ Voice settings applied — STT: \(settings.sttProvider.rawValue), TTS: \(settings.ttsEnabled ? settings.ttsProvider.rawValue : "off"), Azure STT language: \(settings.azureSTTPreferredLanguage.isEmpty ? "auto" : settings.azureSTTPreferredLanguage)")
    }

    private func syncDaemonSettings(_ settings: PickySettings = PickySettingsStore().load()) {
        Task {
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setDefaultCwd,
                    defaultCwd: settings.defaultCwd.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                print("🎛️ Pickle default cwd applied — \(settings.defaultCwd)")
            } catch {
                print("⚠️ Failed to apply Pickle default cwd: \(error.localizedDescription)")
            }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentThinkingLevel,
                    mainAgentThinkingLevel: settings.mainAgentThinkingLevel
                ))
                print("🎛️ Picky thinking level applied — \(settings.mainAgentThinkingLevel.rawValue)")
            } catch {
                print("⚠️ Failed to apply Picky thinking level: \(error.localizedDescription)")
            }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentModel,
                    mainAgentModelPattern: settings.mainAgentModelPattern.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
                print("🎛️ Picky model applied — \(settings.mainAgentModelPattern.isEmpty ? "Pi default" : settings.mainAgentModelPattern)")
            } catch {
                print("⚠️ Failed to apply Picky model: \(error.localizedDescription)")
            }
            do {
                let disabledNames = settings.disabledBuiltinTools.map(\.rawValue).sorted()
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setDisabledBuiltinTools,
                    disabledBuiltinTools: disabledNames
                ))
                print("🏛️ Picky disabled built-in tools applied — \(disabledNames.isEmpty ? "<none>" : disabledNames.joined(separator: ","))")
            } catch {
                print("⚠️ Failed to apply disabled built-in tools: \(error.localizedDescription)")
            }
            do {
                try await agentClient.send(PickyCommandEnvelope(
                    type: .setMainAgentTTSEnabled,
                    enabled: settings.ttsEnabled
                ))
                print("🔊 Picky tts enabled applied — \(settings.ttsEnabled)")
            } catch {
                print("⚠️ Failed to apply Picky tts enabled: \(error.localizedDescription)")
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
        if voiceInteractionState.phase == .speaking {
            applyVoiceInteractionProjection(voiceInteractionState.projection)
        } else if isPushToTalkShortcutHeld || isKeyboardRecording || isMicrophoneRecording {
            if voiceInteractionState.phase != .pttInput, let interactionVoiceInputID {
                reduceVoiceInteraction(.pttPressed(inputID: interactionVoiceInputID, targetSessionID: voiceFollowUpSessionIDForCurrentUtterance))
            } else {
                applyVoiceInteractionProjection(CompanionVoicePresentationState(voiceState: .listening, promptBubbleState: voiceInteractionState.projection.promptBubbleState))
            }
        } else if isFinalizing || isPreparing || pendingAgentResponseStartedAt != nil {
            if voiceInteractionState.phase == .idle {
                reduceVoiceInteraction(.loadingStarted(inputID: interactionVoiceInputID, transcript: currentVoicePromptPreview, targetSessionID: voiceFollowUpSessionIDForCurrentUtterance, now: Date(), promptBubbleVisibility: .visible))
            } else {
                applyVoiceInteractionProjection(voiceInteractionState.projection)
            }
        } else {
            reduceVoiceInteraction(.reset)
        }
        let presentation = voiceInteractionState.projection

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
            // task into routing voice input to Picky instead of the hovered
            // Pickle. Hover-ID cleanup is handled explicitly on dictation error,
            // capture failure, and at the end of the response task. See the regression
            // test `idleVoicePresentationDoesNotClearPressedHoverIDBeforeSubmit`.
            scheduleTransientHideIfNeeded()
        }
    }

    @discardableResult
    private func reduceVoiceInteraction(_ event: PickyVoiceInteractionEvent) -> PickyVoiceInteractionTransition {
        let transition = PickyVoiceInteractionMachine.reduce(state: voiceInteractionState, event: event)
        voiceInteractionState = transition.state
        applyVoiceInteractionProjection(transition.state.projection)
        if let responseText = transition.state.context.responseBubbleText,
           !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            latestAgentSessionSummary = responseText
        }
        return transition
    }

    private func applyVoiceInteractionProjection(_ projection: CompanionVoicePresentationState) {
        voiceState = projection.voiceState
        voicePromptBubbleState = projection.promptBubbleState
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

    private func bindScreenContextTarget() {
        applyScreenContextTarget(selectionStore.screenContextTargetSessionID)
        screenContextTargetCancellable = NotificationCenter.default.publisher(for: .pickyScreenContextTargetChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                let sessionID = notification.userInfo?[PickyScreenContextTargetNotification.sessionIDKey] as? String
                self?.applyScreenContextTarget(sessionID)
            }
    }

    private func applyScreenContextTarget(_ sessionID: String?) {
        let normalized = normalizedVoiceFollowUpSessionID(sessionID)
        screenContextTargetSessionID = normalized
        setLocalOverlayReason(.screenContextTarget, visible: normalized != nil)
    }

    private func handleQuickInputDoubleTap(_ event: QuickInputDoubleTapEvent) {
        // PTT-in-progress and the input panel are mutually exclusive: voice and
        // typed quick input share the same submission lane and we don't want a
        // floating focus stealer mid-utterance.
        if isShortcutHandlingSuppressed { return }
        guard activeShortcutCaptureCount == 0,
              !isPushToTalkShortcutHeld,
              !buddyDictationManager.isDictationInProgress else { return }
        if !quickInputPanelManager.isPanelVisible {
            beginInkCapture(source: .text)
        }
        quickInputPanelManager.updateScreenshotState(currentQuickInputScreenshotState())
        quickInputPanelManager.presentPanel(near: event.mouseLocation)
    }

    /// Recomputes the Quick Input screenshot-attachment state from live ink
    /// state + persisted settings. Mirrors the gate applied later by
    /// `PickyVoiceContextCaptureCoordinator.applyInkOnlyAttachmentGate` so the
    /// pill indicator matches what the model actually receives.
    private func currentQuickInputScreenshotState(
        settings: PickySettings? = nil
    ) -> QuickInputScreenshotState {
        let resolved = settings ?? PickySettingsStore().load()
        let hasInk = !inkOverlayState.strokes.isEmpty
        if resolved.attachScreenshotsOnlyWhenInked, !hasInk { return .gated }
        return .attached
    }

    private func pushQuickInputScreenshotStateIfPanelVisible() {
        guard quickInputPanelManager.isPanelVisible else { return }
        quickInputPanelManager.updateScreenshotState(currentQuickInputScreenshotState())
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

    /// Allows external hardware integrations to drive the same push-to-talk
    /// lifecycle as the global keyboard shortcut through `picky ptt press|release`.
    /// Duplicate presses/releases are ignored so button bounce cannot start a
    /// second voice turn or stop an unrelated microphone-button dictation.
    func controlPushToTalkFromExternal(action: PickyPushToTalkControlAction) {
        switch action {
        case .press:
            guard !isPushToTalkShortcutHeld else { return }
            handleShortcutTransition(.pressed)
        case .release:
            guard isPushToTalkShortcutHeld else { return }
            handleShortcutTransition(.released)
        }
    }

    // Internal so PickyCompanionManagerTests can exercise the production PTT
    // transition through context capture and coordinator effect dispatch.
    func handleShortcutTransition(_ transition: BuddyPushToTalkShortcut.ShortcutTransition) {
        // Defensive: even though GlobalPushToTalkShortcutMonitor short-circuits
        // its callback while paused, swallowing transitions here too keeps any
        // already-queued event from slipping through and dismissing the panel.
        if activeShortcutCaptureCount > 0 { return }
        if isShortcutHandlingSuppressed { return }
        switch transition {
        case .pressed:
            isPushToTalkShortcutHeld = true
            guard !buddyDictationManager.isDictationInProgress else { return }
            interruptSpokenResponseForVoiceInput()
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            let screenContextTargetSessionID = normalizedVoiceFollowUpSessionID(selectionStore.screenContextTargetSessionID)
            let targetSessionID = screenContextTargetSessionID ?? normalizedVoiceFollowUpSessionID(selectionStore.hoveredVoiceFollowUpSessionID)
            let inputID = UUID()
            if let screenContextTargetSessionID {
                screenContextVoiceTargetByInputID[inputID] = screenContextTargetSessionID
            }
            interactionVoiceInputID = inputID
            reduceVoiceInteraction(.pttPressed(inputID: inputID, targetSessionID: targetSessionID))
            beginInkCapture(source: .voice)
            print("🎙️ Picky voice route — PTT pressed; screenContext=\(selectionStore.screenContextTargetSessionID ?? "<nil>") storeHover=\(selectionStore.hoveredVoiceFollowUpSessionID ?? "<nil>") prevTask=\(currentResponseTask != nil)")
            setVoiceFollowUpSessionIDForCurrentUtterance(targetSessionID, caller: "PTT-pressed")
            interactionCoordinator.accept(
                .voicePressed(targetSessionID: targetSessionID),
                correlation: PickyInteractionCorrelation(inputID: inputID, sessionID: targetSessionID, source: .voice)
            )

            // Cancel any pending transient hide so the overlay stays visible
            transientHideTask?.cancel()
            transientHideTask = nil

            // If the cursor is hidden, bring it back transiently for this interaction
            if !isCursorPreferenceEnabled {
                setLocalOverlayReason(.activeVoiceInput, visible: true)
            }

            // Dismiss the menu bar panel so it doesn't cover the screen
            NotificationCenter.default.post(name: .pickyDismissPanel, object: nil)

            // Cancel any in-progress response from a previous utterance.
            currentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask = nil
            deferredFinishAwaitingAgentResponseSessionID = nil
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
            if let releasedInputID = interactionVoiceInputID {
                reduceVoiceInteraction(.pttReleased(inputID: releasedInputID))
            }
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
    // Internal so PickyCompanionManagerTests can finalize a production PTT turn
    // without depending on microphone transcription.
    func submitTranscriptToPickyAgent(transcript: String) {
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
        switch PickyVoiceTranscriptRoutingPolicy.route(
            voiceFollowUpSessionID: voiceFollowUpSessionID,
            screenContextTargetSessionID: selectionStore.screenContextTargetSessionID,
            armedDispatchMode: armedPickleDispatchMode
        ) {
        case .steerPickle(let targetSessionID):
            print("🎙️ Picky voice route — STEER Pickle=\(targetSessionID)")
            try await agentClient.send(PickyCommandEnvelope(type: .steer, context: contextPacket, sessionId: targetSessionID, text: transcript))
            clearScreenContextTargetIfCurrent(targetSessionID)
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        case .followUpPickle(let targetSessionID):
            print("🎙️ Picky voice route — FOLLOW-UP Pickle=\(targetSessionID)")
            try await agentClient.send(PickyCommandEnvelope(type: .followUp, context: pickleFollowUpContext(contextPacket, sessionID: targetSessionID), sessionId: targetSessionID, text: transcript))
            clearScreenContextTargetIfCurrent(targetSessionID)
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        case .submitToMain:
            print("🎙️ Picky voice route — SUBMIT Picky (arg=\(voiceFollowUpSessionID ?? "<nil>") self=\(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>"))")
            return try await submitOrIntercept(PickyAgentSubmission(transcript: transcript, context: contextPacket))
        }
    }

    /// Routes a submission through the onboarding interceptor when one is
    /// installed; falls back to the real agent client otherwise. Centralising
    /// the check keeps every submit call site honest — onboarding doesn't have
    /// to know about voice vs text vs follow-up paths, and production code
    /// keeps its existing behavior when no interceptor is attached.
    private func submitOrIntercept(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        noteMainOverlayContext(submission.context)
        if let interceptor = submissionInterceptor,
           let receipt = await interceptor(submission) {
            return receipt
        }
        return try await agentClient.submit(submission)
    }

    private func pickleFollowUpContext(_ context: PickyContextPacket, sessionID: String) -> PickyContextPacket {
        let isScreenContextTargeted = selectionStore.screenContextTargetSessionID == sessionID
        let hasUserMarks = !context.inkMarks.isEmpty
        guard isScreenContextTargeted || hasUserMarks else {
            return PickyContextPacket(
                id: context.id,
                source: context.source,
                capturedAt: context.capturedAt,
                transcript: context.transcript,
                selectedText: context.selectedText,
                cwd: context.cwd,
                activeApp: context.activeApp,
                activeWindow: context.activeWindow,
                browser: context.browser,
                screenshots: [],
                inkMarks: [],
                warnings: context.warnings
            )
        }
        return context
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
        PickyVoiceTranscriptRoutingPolicy.normalizedSessionID(sessionID)
    }

    private func clearScreenContextTargetIfCurrent(_ sessionID: String?) {
        guard let sessionID, selectionStore.screenContextTargetSessionID == sessionID else { return }
        // Sticky armed Pickles persist across follow-up/steer dispatches; only
        // an explicit user gesture (re-tap, arming another Pickle) or a hard
        // failure (dictation error, session removed) clears them.
        if selectionStore.screenContextTargetSticky { return }
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        applyScreenContextTarget(nil)
    }

    private func sendPickleMessageFromInput(
        targetSessionID: String,
        text: String,
        source: String,
        inkCapture: PickyInkCapture?,
        dispatchMode: PickyArmedPickleDispatchMode
    ) async -> Bool {
        do {
            guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                transcript: text,
                source: source,
                inkCapture: inkCapture
            ) else {
                directMessageError = L10n.t("error.directMessage.contextEmpty")
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                return false
            }
            // `sendAwaitingError` waits up to 1s for the daemon to emit a
            // `type="error"` rejection (e.g. `Unknown session: …` when the
            // target Pickle lives in a child daemon the router can't reach).
            // agentd has no positive ack today, so absence of error within
            // the window is treated as success.
            let commandType: PickyCommandType
            let context: PickyContextPacket
            switch dispatchMode {
            case .steer:
                commandType = .steer
                context = captureResult.contextPacket
            case .followUp:
                commandType = .followUp
                context = pickleFollowUpContext(captureResult.contextPacket, sessionID: targetSessionID)
            }
            let rejection = try await agentClient.sendAwaitingError(
                PickyCommandEnvelope(
                    type: commandType,
                    context: context,
                    sessionId: targetSessionID,
                    text: text
                ),
                timeout: 1.0
            )
            if let rejection {
                directMessageError = L10n.t("error.directMessage.sendFailed", rejection.message)
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                return false
            }
            latestAgentSessionSummary = dispatchMode == .steer
                ? L10n.t("directMessage.steerDelivered")
                : L10n.t("directMessage.followUpDelivered")
            clearScreenContextTargetIfCurrent(targetSessionID)
            return true
        } catch {
            let message = error.localizedDescription
            directMessageError = L10n.t("error.directMessage.sendFailed", message)
            latestAgentSessionSummary = directMessageError
            clearScreenContextTargetIfCurrent(targetSessionID)
            return false
        }
    }

    @discardableResult
    func sendDirectMessage(_ text: String, source: PickyInteractionSource = .text, inkCapture: PickyInkCapture? = nil) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        directMessageError = nil

        if source == .quickInput, let targetSessionID = normalizedVoiceFollowUpSessionID(selectionStore.screenContextTargetSessionID) {
            return await sendPickleMessageFromInput(
                targetSessionID: targetSessionID,
                text: trimmedText,
                source: "text-follow-up",
                inkCapture: inkCapture,
                dispatchMode: armedPickleDispatchMode
            )
        }

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
        isWaitingForCursorResponse = projection.isWaitingForCursorResponse
        agentAnnotations = projection.agentAnnotations
        scheduleAnnotationExpiryIfNeeded(for: projection.agentAnnotations)
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
        deferredFinishAwaitingAgentResponseSessionID = nil
        pendingAgentResponseStartedAt = nil
    }

    private func speechWatchdogTimeout(for utterance: String) -> TimeInterval {
        if let speechWatchdogTimeoutOverride {
            return max(0.05, speechWatchdogTimeoutOverride)
        }

        // This is a last-resort stuck-state recovery guard, not a normal TTS
        // duration limiter. Keep it deliberately generous so slow voices,
        // remote TTS latency, or long Korean replies are not cut off. macOS
        // Speech can occasionally miss NSSpeechSynthesizer's finish callback
        // and keep reporting `isSpeaking` after audible playback ended,
        // especially with path-like strings; use a tighter local fallback so
        // the cursor bubble does not sit in `.responding` for ~30s+.
        let characterCount = max(1, utterance.trimmingCharacters(in: .whitespacesAndNewlines).count)
        if speechPlaybackProvider is PickySystemSpeechPlaybackProvider {
            let localEstimatedDuration = Double(characterCount) / 8.0 + 8.0
            return min(localEstimatedDuration, 90.0)
        }
        let estimatedDuration = Double(characterCount) / 4.0 + 10.0
        return min(estimatedDuration, 300.0)
    }

    private func logSpeech(_ message: String) {
        PickyLog.notice(.speech, prefix: "🔊 Picky speech —", message: message)
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

    private func quickReplyWouldUseTTS(owner: PickyContextOwner?, replyKind: PickyQuickReplyKind) -> Bool {
        (owner?.isVoiceOwned == true) || (owner?.usesCursorResponsePresentation == true) || replyKind == .pickleCompletion
    }

    private func shouldSuppressDuplicateQuickReplyTTS(_ reply: PickyQuickReplyEvent, replyKind: PickyQuickReplyKind) -> Bool {
        let key = [
            reply.contextId,
            replyKind.rawValue,
            reply.sessionId ?? "",
            reply.text
        ].joined(separator: "\u{1f}")
        let now = Date()
        defer {
            lastQuickReplyTTSDedupKey = key
            lastQuickReplyTTSDedupAt = now
        }
        guard lastQuickReplyTTSDedupKey == key, let previous = lastQuickReplyTTSDedupAt else { return false }
        return now.timeIntervalSince(previous) <= 1.0
    }

    private func completeDirectMessage(inputID: UUID, success: Bool) {
        directMessageContinuations.removeValue(forKey: inputID)?.resume(returning: success)
    }

    private func failDirectMessage(inputID: UUID, message: String) {
        directMessageError = L10n.t("error.directMessage.deliverFailed", message)
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
                _ = try await submitOrIntercept(PickyAgentSubmission(transcript: text, context: context))
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
                    screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
                    interactionCoordinator.effectCompleted(
                        .transcriptFailed(message: "Context capture returned no packet.", inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
                    )
                    if completeVoiceInteractionIfCurrent(inputID: inputID) {
                        clearScreenContextTargetIfCurrent(targetSessionID)
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
                screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
                // User spoke again — response was interrupted.
            } catch {
                screenContextVoiceTargetByInputID.removeValue(forKey: inputID)
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
                let receipt = try await submitOrIntercept(PickyAgentSubmission(transcript: transcript, context: context))
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

    fileprivate func runFollowUpPickleEffect(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isScreenContextTargetedInput = screenContextVoiceTargetByInputID.removeValue(forKey: inputID) == sessionID
            if isScreenContextTargetedInput {
                let command: PickyCommandEnvelope
                let source: String
                switch armedPickleDispatchMode {
                case .steer:
                    command = PickyCommandEnvelope(type: .steer, context: context, sessionId: sessionID, text: transcript)
                    source = "voice-steer"
                case .followUp:
                    command = PickyCommandEnvelope(type: .followUp, context: pickleFollowUpContext(context, sessionID: sessionID), sessionId: sessionID, text: transcript)
                    source = "voice-follow-up"
                }
                do {
                    try await agentClient.send(command)
                    guard !Task.isCancelled else { return }
                    clearScreenContextTargetIfCurrent(sessionID)
                    let receipt = PickyAgentSubmissionReceipt(sessionID: sessionID, message: "")
                    interactionCoordinator.effectCompleted(
                        .agentSubmissionAccepted(contextID: context.id, sessionID: sessionID, inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: sessionID, source: .agent)
                    )
                    handleAgentSubmissionAccepted(receipt: receipt, source: source)
                    finishVoiceSubmissionIfIdle(inputID: inputID)
                } catch is CancellationError {
                    // User spoke again — response was interrupted.
                } catch {
                    handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
                }
                return
            }

            do {
                try await agentClient.send(PickyCommandEnvelope(type: .followUp, context: self.pickleFollowUpContext(context, sessionID: sessionID), sessionId: sessionID, text: transcript))
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
            clearScreenContextTargetIfCurrent(voiceFollowUpSessionIDForCurrentUtterance)
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "voice-submission-failure")
        }
    }

    private func finishVoiceSubmissionIfIdle(inputID: UUID) {
        let completedCurrentInput = completeVoiceInteractionIfCurrent(inputID: inputID)
        print("🎙️ Picky voice route — responseTask end; cancelled=\(Task.isCancelled) selfBeforeReset=\(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>")")
        if completedCurrentInput {
            clearScreenContextTargetIfCurrent(voiceFollowUpSessionIDForCurrentUtterance)
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
        interactionTimerScheduler.schedule(after: delay) { [weak self] in
            self?.interactionCoordinator.effectCompleted(
                .minimumDisplayTimerFired(timerID: timerID, speechID: speechID, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, speechID: speechID, source: .system)
            )
        }
    }

    fileprivate func runSpeakEffect(speechID: UUID, text: String, contextID: String?) {
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        // Strip parenthesised supplementary detail right before synthesis so
        // every interaction-coordinator-routed reply (the modern path through
        // PickyQueuedSpeechReply) skips URLs, paths, and identifiers that
        // Picky placed in `(...)`. Visible text keeps the parens intact — the
        // queued reply still holds the original `text`. Legacy callers go
        // through `speakSystemMessage` and pre-strip there, so this is the
        // only remaining funnel that needed the transform.
        let spoken = stripParentheticalsForSpeech(text)
        startOrDeferInteractionSpeech(speechID: speechID, text: spoken, contextID: contextID, requestedAt: Date())
    }

    private func startOrDeferInteractionSpeech(speechID: UUID, text: String, contextID: String?, requestedAt: Date) {
        guard isCurrentInteractionSpeechOutput(speechID) else {
            logSpeech("interaction start skipped stale projection speechID=\(speechID) context=\(contextID ?? "none")")
            return
        }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            let elapsed = Date().timeIntervalSince(requestedAt)
            guard elapsed < Self.deferredSpeechMaximumWait else {
                logSpeech("interaction start failed deferred audio suppression timeout speechID=\(speechID) elapsedMs=\(Int(elapsed * 1000)) context=\(contextID ?? "none")")
                interactionCoordinator.effectCompleted(
                    .speechFailed(speechID: speechID),
                    correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
                )
                return
            }

            logSpeech("interaction start deferred by active voice input speechID=\(speechID) elapsedMs=\(Int(elapsed * 1000)) context=\(contextID ?? "none")")
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
        reduceVoiceInteraction(.agentReply(text: text, shouldSpeak: true, speechID: speechID, timerID: speechID, inputID: interactionVoiceInputID, now: Date()))

        logSpeech("interaction start speechID=\(speechID) provider=\(speechPlaybackProvider.displayName) chars=\(text.count) context=\(contextID ?? "none")")
        guard speechPlaybackProvider.speak(text, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.logSpeech("interaction provider callback speechID=\(speechID) didFinish=\(didFinish) context=\(contextID ?? "none")")
                self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: didFinish, contextID: contextID)
            }
        }) else {
            logSpeech("interaction provider refused start speechID=\(speechID) context=\(contextID ?? "none")")
            handleInteractionSpeechFinished(speechID: speechID, didFinish: false, contextID: contextID)
            return
        }

        let startedAt = Date()
        let watchdogDeadline = Date().addingTimeInterval(speechWatchdogTimeout(for: text))
        responseStateTask = Task { [weak self] in
            var lastLoggedSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let pollResult = await MainActor.run { [weak self] in
                    guard let self, self.activeSpeechID == speechID else { return PickySpeechPollResult.inactive }
                    let isSpeaking = self.speechPlaybackProvider.isSpeaking
                    let elapsedSecond = Int(Date().timeIntervalSince(startedAt))
                    if elapsedSecond != lastLoggedSecond {
                        lastLoggedSecond = elapsedSecond
                        self.logSpeech("interaction poll speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) providerSpeaking=\(isSpeaking) voiceState=\(self.voiceState) context=\(contextID ?? "none")")
                    }
                    if !isSpeaking { return .finished }
                    if Date() >= watchdogDeadline { return .timedOut }
                    return .speaking
                }
                switch pollResult {
                case .speaking:
                    continue
                case .inactive:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("interaction poll inactive speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    }
                    return
                case .finished:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("interaction poll detected provider finished speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self?.handleInteractionSpeechFinished(speechID: speechID, didFinish: true, contextID: contextID)
                    }
                    return
                case .timedOut:
                    await MainActor.run { [weak self] in
                        guard let self, self.activeSpeechID == speechID else { return }
                        self.logSpeech("interaction poll timed out speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self.speechPlaybackProvider.stopSpeaking()
                        self.handleInteractionSpeechFinished(speechID: speechID, didFinish: false, contextID: contextID)
                    }
                    return
                }
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
        guard activeSpeechID == speechID else {
            logSpeech("interaction finish ignored stale speechID=\(speechID) active=\(activeSpeechID?.uuidString ?? "none") didFinish=\(didFinish) context=\(contextID ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
            return
        }
        logSpeech("interaction finish accepted speechID=\(speechID) didFinish=\(didFinish) context=\(contextID ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        reduceVoiceInteraction(didFinish ? .speechFinished(speechID: speechID, now: Date()) : .speechFailed(speechID: speechID, now: Date()))
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
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
            directMessageError = L10n.t("error.directMessage.startFailed", message)
            latestAgentSessionSummary = directMessageError
            return false
        }
    }

    /// Notify the interaction reducer that a picky CLI submission is in flight. The
    /// router-side context provider calls this right after capturing the desktop context
    /// and before handing it back to the daemon, so the reducer can register the cursor
    /// owner for the captured contextID and transition to `.waitingForAgent` — which is
    /// what turns the cursor into the loading state while the daemon resolves the
    /// matching quickReply. Without this notification the CLI path would skip the
    /// processing cursor entirely and jump straight from idle to the response bubble.
    ///
    /// Only `submitMain` entries may flip the cursor: a `createPickle` entry delegates
    /// the work to a Pickle whose progress is already visible on its dock icon, and no
    /// main quickReply for the captured contextID arrives until the Pickle completes
    /// (if ever) — so `.waitingForAgent` would park the cursor on the yellow loading
    /// state for the whole Pickle run.
    func noteExternalSubmission(kind: PickyExternalEntryKind, text: String, context: PickyContextPacket) {
        guard kind == .submitMain else { return }
        noteMainOverlayContext(context)
        let inputID = UUID()
        interactionCoordinator.accept(
            .externalContextCaptured(inputID: inputID, text: text, context: context),
            correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, source: .system)
        )
    }

    func handleAgentSubmissionAccepted(receipt: PickyAgentSubmissionReceipt, source: String) {
        PickyAnalytics.trackAgentSubmissionAccepted(sessionID: receipt.sessionID)
        print("🧠 Picky local agent submission accepted: \(receipt.sessionID)")

        let receiptMessage = receipt.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !receiptMessage.isEmpty {
            finishAwaitingAgentResponse(visibleText: receiptMessage, spokenText: receiptMessage)
        } else if source == "voice-follow-up" || source == "voice-steer" {
            let shouldEnforceMinimumDisplay = currentVoicePromptPreview != nil
            finishAwaitingAgentResponse(
                visibleText: L10n.t("directMessage.steerDelivered"),
                spokenText: nil,
                enforceMinimumProcessingDuration: shouldEnforceMinimumDisplay,
                deferredSessionID: shouldEnforceMinimumDisplay ? receipt.sessionID : nil
            )
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
            handleSessionStatusTransition(session: session)
            updatePassiveAgentSummary(session.lastSummary ?? "\(session.title) · \(session.status.rawValue)")
        case .sessionResourcesReloaded, .sessionLogAppended, .toolActivityUpdated, .sessionTodoStateUpdated, .sessionArchivedAuthoritative, .pluginsReloaded:
            // Progress events are already represented in the HUD. They should not
            // replace a cursor bubble that is currently speaking/showing a real
            // response, otherwise generic text like "작업 진행 중…" hides the answer.
            // pluginsReloaded is handled by the plugin manager controller in the
            // panel; CompanionManager doesn't need to react.
            break
        case .extensionUiRequest(let request):
            latestAgentSessionSummary = request.prompt ?? request.title ?? "Agent is waiting for input"
        case .quickReply(let reply):
            applyQuickReplyEvent(reply)
        case .externalEntryAccepted(let accepted):
            guard let sessionId = accepted.sessionId else { break }
            interactionCoordinator.accept(
                .agentSubmissionAccepted(contextID: accepted.contextId, sessionID: sessionId, inputID: nil),
                correlation: PickyInteractionCorrelation(contextID: accepted.contextId, sessionID: sessionId, source: .agent)
            )
        case .mainMessagesSnapshot(let messages):
            mainAgentMessages = Array(messages.suffix(100))
            // Snapshot fires on session load/reset for the whole transcript,
            // so do not auto-dispatch deep links here — we would re-open
            // panels for stale replies the user already saw.
        case .mainMessageAppended(let message):
            mainAgentMessages = Array((mainAgentMessages + [message]).suffix(100))
            autoDispatchPickyDeepLinkIfPresent(in: message)
        case .mainAgentSessionInfoUpdated(let sessionFilePath, let cwd):
            mainAgentSessionInfo = PickyMainAgentSessionInfo(sessionFilePath: sessionFilePath, cwd: cwd)
        case .mainAgentModelsSnapshot(let models):
            mainAgentModelOptions = models
            isLoadingMainAgentModelOptions = false
        case .pointerOverlayRequested(let request):
            applyPointerOverlayRequest(request)
        case .annotationOverlayRequested(let request):
            applyAnnotationOverlayRequest(request)
        case .error(let error):
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
        case .hello, .sessionSnapshot, .artifactUpdated, .slashCommandsSnapshot,
             .autocompleteCapabilitiesSnapshot, .autocompleteSuggestionsSnapshot, .autocompleteCompletionApplied,
             .rewindTargetsSnapshot, .sessionRewound, .unknown,
             .sessionMessageAppended, .sessionMessagesImported, .sessionMessageReplaced, .sessionMessageRemoved, .sessionQueueUpdated, .sessionActivityUpdated, .terminalSessionSyncOutcome,
             .pickleHandoffRequested, .pickleBridgeRequested, .externalEntryRequested, .dockGroupsRequested, .pushToTalkControlRequested:
            break
        }
    }

    private func applyQuickReplyEvent(_ reply: PickyQuickReplyEvent) {
        let owner = interactionOwner(for: reply.contextId)
        let originSource = reply.originSource ?? owner.map { $0.isVoiceOwned ? .voice : .text }
        let replyKind = reply.replyKind ?? .main
        if quickReplyWouldUseTTS(owner: owner, replyKind: replyKind), shouldSuppressDuplicateQuickReplyTTS(reply, replyKind: replyKind) {
            return
        }
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
    }

    private func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            detectedElementPointerID = nil
            detectedElementDisplayFrame = target.displayFrame
            detectedElementBubbleText = target.bubbleText
            detectedElementDisplayDuration = target.duration
            detectedElementTargetFrame = target.targetFrame
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
                    targetFrame: target.targetFrame,
                    highlightKind: .screenElement
                )),
                correlation: PickyInteractionCorrelation(pointerID: request.id, source: .pointer)
            )
            latestAgentSessionSummary = target.bubbleText.map { L10n.t("agent.summary.pointingScreen", $0) } ?? L10n.t("agent.summary.pointingScreenAnon")

            setLocalOverlayReason(.activePointerAnimation, visible: true)
        } catch {
            latestAgentSessionSummary = "Pointer overlay ignored: \(error.localizedDescription)"
        }
    }

    private func applyAnnotationOverlayRequest(_ request: PickyAnnotationOverlayRequest) {
        if request.mode == .clear {
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: .clear, annotations: []),
                correlation: PickyInteractionCorrelation(source: .agent)
            )
            return
        }
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let annotations = try PickyAnnotationOverlayResolver.resolve(request)
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: request.mode, annotations: annotations),
                correlation: PickyInteractionCorrelation(source: .agent)
            )
            if request.mode != .clear {
                latestAgentSessionSummary = "Showing \(annotations.count) screen annotation\(annotations.count == 1 ? "" : "s")."
            }
        } catch {
            latestAgentSessionSummary = "Annotation overlay ignored: \(error.localizedDescription)"
        }
    }

    private func noteMainOverlayContext(_ context: PickyContextPacket) {
        latestOverlayContextID = context.id
    }

    private func shouldApplyOverlay(contextID: String?, generation: Int?) -> Bool {
        guard let contextID, let generation else {
            if latestOverlayContextID != nil {
                PickyLog.logger(.agentClient).debug("Dropping overlay without a capture generation after a newer context was submitted")
                return false
            }
            return true
        }
        if let latestOverlayContextID, contextID != latestOverlayContextID {
            PickyLog.logger(.agentClient).debug("Dropping stale overlay context=\(contextID, privacy: .public) latest=\(latestOverlayContextID, privacy: .public)")
            return false
        }
        if generation < latestOverlayContextGeneration {
            PickyLog.logger(.agentClient).debug("Dropping stale overlay generation=\(generation) latest=\(self.latestOverlayContextGeneration)")
            return false
        }
        latestOverlayContextID = contextID
        latestOverlayContextGeneration = generation
        return true
    }

    private func scheduleAnnotationExpiryIfNeeded(for annotations: [PickyAgentAnnotation]) {
        annotationExpiryTask?.cancel()
        guard let expiresAt = annotations.map(\.expiresAt).min() else {
            annotationExpiryTask = nil
            return
        }
        let delay = max(0, expiresAt.timeIntervalSinceNow)
        annotationExpiryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                self?.interactionCoordinator.accept(
                    .agentAnnotationsExpired(now: Date()),
                    correlation: PickyInteractionCorrelation(source: .system)
                )
            }
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
        guard !isCursorPreferenceEnabled && isOverlayVisible else { return }
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
        // Voice input (PTT) means the user is taking over: drop any active
        // agent state so the UI flips off the yellow loading / blue speaking
        // indicator immediately and the STT subsystem can promote to
        // `.listening` on its own.
        if voiceState == .responding || voiceState == .processing {
            voiceState = .idle
        }
    }

    func interruptSpokenResponseForVoiceInput() {
        abortMainAgentForVoiceInput()
        updateVoiceInputAudioSuppression(isVoiceInputActive: true)
        reduceVoiceInteraction(.abort)
        // Clear the pending timing marker AFTER `abortMainAgentForVoiceInput`
        // has read it to decide whether to also dispatch a session-scoped
        // abort for the in-flight Pickle.
        pendingAgentResponseStartedAt = nil
    }

    private func abortMainAgentForVoiceInput() {
        // The previous utterance may have been routed to a Pickle via
        // follow-up/steer; in that case `abortMainAgent` alone does not stop
        // it, so we also dispatch a session-scoped `.abort` for the captured
        // target. Gate that on a real in-flight response (loading) so a PTT
        // press fired *after* the previous turn already finished does not
        // overwrite a `done` Pickle's status back to `cancelled` on agentd.
        let isAgentResponseInFlight = pendingAgentResponseStartedAt != nil || voiceState == .responding
        let previousPickleSessionID = isAgentResponseInFlight ? voiceFollowUpSessionIDForCurrentUtterance : nil
        Task { [agentClient] in
            do {
                try await agentClient.send(PickyCommandEnvelope(type: .abortMainAgent))
            } catch {
                print("⚠️ Failed to abort Picky for voice input: \(error)")
            }
        }
        if let previousPickleSessionID {
            Task { [agentClient] in
                do {
                    try await agentClient.send(PickyCommandEnvelope(type: .abort, sessionId: previousPickleSessionID))
                } catch {
                    print("⚠️ Failed to abort Pickle session \(previousPickleSessionID) for voice input: \(error)")
                }
            }
        }
    }

    func beginAwaitingAgentResponse(recognizedTranscript: String? = nil) {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        if !buddyDictationManager.isDictationInProgress {
            updateVoiceInputAudioSuppression(isVoiceInputActive: false)
        }
        stopCurrentSpeech()
        let trimmedTranscript = recognizedTranscript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        currentVoicePromptPreview = trimmedTranscript.isEmpty ? nil : trimmedTranscript
        let startedAt = Date()
        pendingAgentResponseStartedAt = startedAt
        latestAgentSessionSummary = L10n.t("agent.summary.preparingResponse")
        reduceVoiceInteraction(.loadingStarted(
            inputID: interactionVoiceInputID,
            transcript: trimmedTranscript,
            targetSessionID: voiceFollowUpSessionIDForCurrentUtterance,
            now: startedAt,
            promptBubbleVisibility: .visible
        ))
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
                self.reduceVoiceInteraction(.promptBubbleAutoHide)
                self.currentVoicePromptPreview = nil
            }
        }
    }

    /// Releases cursor state tied to a session that just transitioned to a terminal
    /// status. The normal completion path runs through `quickReply` -> `finishAwaitingAgentResponse`,
    /// but HUD aborts (and runtime cancel/fail) reach the client only as a `sessionUpdated`
    /// with `.cancelled` / `.failed` — no `quickReply` ever lands. Without this hook the
    /// cursor stays at `.processing` (yellow) forever because both channels that drive it
    /// (`pendingAgentResponseStartedAt` + interaction state `.waitingForAgent`) never clear.
    ///
    /// Idempotent and side-effect-light when nothing matches:
    ///   - only the *transition* into a terminal status triggers cleanup (duplicate
    ///     `sessionUpdated` snapshots for the same terminal status are no-ops);
    ///   - voice-follow-up tracking is only released when the terminated session is the
    ///     one the cursor is actively waiting on;
    ///   - the interaction-coordinator dispatch is harmless when the reducer never
    ///     observed an `agentSubmissionAccepted` for this sessionID.
    private func handleSessionStatusTransition(session: PickyAgentSession) {
        let previous = lastObservedSessionStatuses[session.id]
        lastObservedSessionStatuses[session.id] = session.status
        guard session.status.isTerminal else { return }
        if let previous, previous.isTerminal { return }
        releaseCursorForTerminatedSession(sessionID: session.id, status: session.status)
    }

    private func releaseCursorForTerminatedSession(sessionID: String, status: PickySessionStatus) {
        releaseDeferredAcceptedReceiptIfNeeded(sessionID: sessionID)
        // Only release the voice-input "awaiting agent" timing when the cursor is
        // actually waiting on THIS session. Otherwise we'd race-clear a fresh voice
        // turn that started against a different (still-running) Pickle, or an in-flight
        // spoken reply for an unrelated completed session.
        if voiceFollowUpSessionIDForCurrentUtterance == sessionID {
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseTask = nil
            deferredFinishAwaitingAgentResponseSessionID = nil
            responseStateTask?.cancel()
            responseStateTask = nil
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            voicePromptBubbleState = .hidden
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "session-terminated-\(status.rawValue)")
            // Re-run the voice presentation pipeline. With pendingAgentResponseStartedAt
            // cleared and no dictation in progress, this falls through to the
            // `reduceVoiceInteraction(.reset)` branch which moves voiceState out of
            // `.processing` (the yellow cursor) back to `.idle`. Without this nudge the
            // PickyVoiceInteractionMachine stays parked in `.loading` and voiceState
            // never updates because nothing else drives a projection refresh.
            updateVoicePresentation()
        }
        // Dispatch the synthetic terminal event into the interaction reducer so any
        // `.waitingForAgent` output that the reducer recorded against this session
        // (CLI / quickInput / voice with cursor presentation) flips back to `.idle`.
        // The reducer is idempotent: unknown sessionIDs become `.staleEvent` records.
        interactionCoordinator.accept(
            .sessionTerminated(sessionID: sessionID),
            correlation: PickyInteractionCorrelation(sessionID: sessionID, source: .agent)
        )
    }

    private func releaseDeferredAcceptedReceiptIfNeeded(sessionID: String) {
        guard deferredFinishAwaitingAgentResponseSessionID == sessionID else { return }
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        if voiceState == .processing {
            reduceVoiceInteraction(.reset)
        } else {
            updateVoicePresentation()
        }
    }

    private func finishAwaitingAgentResponse(
        visibleText: String,
        spokenText: String?,
        enforceMinimumProcessingDuration: Bool = false,
        deferredSessionID: String? = nil
    ) {
        if enforceMinimumProcessingDuration,
           let pendingAgentResponseStartedAt,
           Date().timeIntervalSince(pendingAgentResponseStartedAt) < Self.minimumVoiceProcessingDisplayDuration {
            let remainingDelay = Self.minimumVoiceProcessingDisplayDuration - Date().timeIntervalSince(pendingAgentResponseStartedAt)
            deferredFinishAwaitingAgentResponseTask?.cancel()
            deferredFinishAwaitingAgentResponseSessionID = deferredSessionID
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
        deferredFinishAwaitingAgentResponseSessionID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        latestAgentSessionSummary = visibleText
        currentVoicePromptPreview = nil
        let textToSpeak = spokenText?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let textToSpeak, !textToSpeak.isEmpty else {
            reduceVoiceInteraction(.textReply(text: visibleText))
            if !shouldSuppressSpokenAudioForVoiceInput {
                scheduleTransientHideIfNeeded()
            }
            return
        }
        guard !shouldSuppressSpokenAudioForVoiceInput else {
            stopCurrentSpeech()
            reduceVoiceInteraction(.textReply(text: visibleText))
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
        reduceVoiceInteraction(.agentReply(text: utterance, shouldSpeak: true, speechID: speechID, timerID: speechID, inputID: interactionVoiceInputID, now: Date()))

        logSpeech("system start speechID=\(speechID) provider=\(speechPlaybackProvider.displayName) chars=\(utterance.count)")
        guard speechPlaybackProvider.speak(utterance, onFinish: { [weak self] didFinish in
            Task { @MainActor [weak self] in
                self?.logSpeech("system provider callback speechID=\(speechID) didFinish=\(didFinish)")
                self?.handleSpeechFinished(speechID: speechID, didFinish: didFinish)
            }
        }) else {
            logSpeech("system provider refused start speechID=\(speechID)")
            handleSpeechFinished(speechID: speechID, didFinish: false)
            return
        }

        let startedAt = Date()
        let watchdogDeadline = Date().addingTimeInterval(speechWatchdogTimeout(for: utterance))
        responseStateTask = Task { [weak self] in
            var lastLoggedSecond = -1
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard !Task.isCancelled else { return }
                let pollResult = await MainActor.run { [weak self] in
                    guard let self,
                          self.activeSpeechID == speechID else {
                        return PickySpeechPollResult.inactive
                    }
                    let isSpeaking = self.speechPlaybackProvider.isSpeaking
                    let elapsedSecond = Int(Date().timeIntervalSince(startedAt))
                    if elapsedSecond != lastLoggedSecond {
                        lastLoggedSecond = elapsedSecond
                        self.logSpeech("system poll speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000)) providerSpeaking=\(isSpeaking) voiceState=\(self.voiceState)")
                    }
                    if !isSpeaking { return .finished }
                    if Date() >= watchdogDeadline { return .timedOut }
                    return .speaking
                }
                switch pollResult {
                case .speaking:
                    continue
                case .inactive:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("system poll inactive speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                    }
                    return
                case .finished:
                    await MainActor.run { [weak self] in
                        self?.logSpeech("system poll detected provider finished speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self?.handleSpeechFinished(speechID: speechID, didFinish: true)
                    }
                    return
                case .timedOut:
                    await MainActor.run { [weak self] in
                        guard let self, self.activeSpeechID == speechID else { return }
                        self.logSpeech("system poll timed out speechID=\(speechID) elapsedMs=\(Int(Date().timeIntervalSince(startedAt) * 1000))")
                        self.speechPlaybackProvider.stopSpeaking()
                        self.handleSpeechFinished(speechID: speechID, didFinish: false)
                    }
                    return
                }
            }
        }
    }

    fileprivate func stopCurrentSpeech() {
        logSpeech("stop current speech active=\(activeSpeechID?.uuidString ?? "none") interaction=\(interactionSpeechID?.uuidString ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        reduceVoiceInteraction(.reset)
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
        logSpeech("stop current interaction speech requested=\(requestedSpeechID?.uuidString ?? "none") resolved=\(speechID?.uuidString ?? "none")")
        stopCurrentSpeech()
        guard let speechID else { return }
        interactionCoordinator.effectCompleted(
            .speechFailed(speechID: speechID),
            correlation: PickyInteractionCorrelation(speechID: speechID, source: .system)
        )
    }

    private func handleSpeechFinished(speechID: UUID, didFinish: Bool) {
        guard activeSpeechID == speechID else {
            logSpeech("system finish ignored stale speechID=\(speechID) active=\(activeSpeechID?.uuidString ?? "none") didFinish=\(didFinish) providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
            return
        }
        logSpeech("system finish accepted speechID=\(speechID) didFinish=\(didFinish) providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        let machineCompletionTime = Date().addingTimeInterval(PickyVoiceInteractionMachine.minimumDisplayDuration + 0.01)
        reduceVoiceInteraction(didFinish ? .speechFinished(speechID: speechID, now: machineCompletionTime) : .speechFailed(speechID: speechID, now: machineCompletionTime))
        activeSpeechID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        scheduleTransientHideIfNeeded()
    }

    /// Scans an assistant reply for the first `[label](picky://...)` link
    /// and asks `PickyDeepLinkDispatcher` to open that screen. The link is
    /// treated as a side-effect of the reply (no click needed): as soon as
    /// the message lands on the messages tab, the panel auto-routes to the
    /// matching settings/tab. The LLM is told (in the user-guide tool
    /// description) to emit at most one such link per response, so we just
    /// take the first match here.
    private func autoDispatchPickyDeepLinkIfPresent(in message: PickyMainAgentMessage) {
        guard message.role == .assistant else { return }
        guard let url = Self.firstPickyDeepLinkURL(in: message.text) else { return }
        PickyDeepLinkDispatcher.shared.handle(url)
    }

    /// Markdown link pattern: `[label](picky://...)`. We deliberately match
    /// only the markdown form — a bare `picky://` URL elsewhere in prose
    /// should not trigger navigation, because the LLM is taught to wrap the
    /// intent in a bracketed label and bare URLs would otherwise fire from
    /// quoted manual excerpts.
    private static let pickyDeepLinkMarkdownPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[[^\]]+\]\((picky://[^\s)]+)\)"#, options: [])
    }()

    private static func firstPickyDeepLinkURL(in text: String) -> URL? {
        guard let regex = pickyDeepLinkMarkdownPattern else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range),
              match.numberOfRanges >= 2,
              let urlRange = Range(match.range(at: 1), in: text) else { return nil }
        return URL(string: String(text[urlRange]))
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
            case .followUpPickle(let inputID, let sessionID, let transcript, let context):
                manager?.runFollowUpPickleEffect(inputID: inputID, sessionID: sessionID, transcript: transcript, context: context)
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

/// Removes or neutralizes speech-hostile supplementary detail so the TTS
/// layer does not try to pronounce URLs, paths, and identifiers. Visible text
/// keeps the original detail intact.
func stripParentheticalsForSpeech(_ text: String) -> String {
    let parentheticalPattern = #"[\(\uFF08][^\(\)\uFF08\uFF09]*[\)\uFF09]"#
    guard let parentheticalRegex = try? NSRegularExpression(pattern: parentheticalPattern, options: []) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let withoutParentheticals = parentheticalRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

    let withoutURLs = withoutParentheticals.replacingOccurrences(
        of: #"(?i)(?:https?://|www\.)[^\s,，。！？!?]+"#,
        with: "링크",
        options: .regularExpression
    )
    let withoutPaths = withoutURLs.replacingOccurrences(
        of: #"(?<!\S)(?:~/[^\s,，。！？!?]*|\.{1,2}/[^\s,，。！？!?]*|/[^\s,，。！？!?]+)(?=[\s,，。！？!?]|$)"#,
        with: "해당 경로",
        options: .regularExpression
    )
    let collapsed = withoutPaths
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " ([,.!?。，！？])", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "해당 경로 에서", with: "해당 경로에서")
        .replacingOccurrences(of: "링크 에", with: "링크에")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? text : collapsed
}
