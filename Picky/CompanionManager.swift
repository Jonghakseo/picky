//
//  CompanionManager.swift
//  Picky
//
//  Central state manager for the companion voice mode. Owns the push-to-talk
//  pipeline (dictation manager + global shortcut monitor + overlay) and
//  exposes observable voice state for the panel UI.
//

import AppKit
import AVFoundation
import Combine
import Foundation
import OSLog
import ScreenCaptureKit
import SwiftUI

private enum PickySpeechPollResult {
    case speaking
    case finished
    case timedOut
    case inactive
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
    @Published private(set) var voiceState: CompanionVoiceState = .idle {
        didSet { updateMainCancelPillPresentation() }
    }
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
    @Published private(set) var isProgressiveResponseVisible = false
    @Published private(set) var hasActiveVisualNarration = false
    @Published private(set) var hasActivePointVisualNarration = false
    @Published private(set) var mainAgentMessages: [PickyMainAgentMessage] = []
    @Published private(set) var mainLiveActivities: [PickyMainActivity] = [] {
        didSet { updateMainCancelPillPresentation() }
    }
    @Published private(set) var mainPendingQuestion: PickyExtensionUiRequest?
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
    /// Whether this visit is the last in its sequence and should spring back to the real cursor.
    @Published var detectedElementReturnsToCursor = true
    /// Keeps the final annotation target in place until its streamed turn settles.
    @Published var detectedElementParksAtTarget = false
    /// Stable id for the active pointer animation. Every delayed BlueCursorView
    /// callback validates this id before mutating or clearing pointer state.
    @Published var detectedElementPointerID: String?
    /// Resolved AI annotations, rendered independently from user ink and pointer animation.
    @Published private(set) var agentAnnotations: [PickyAgentAnnotation] = []
    /// True only while settled annotations remain visible and can be explicitly dismissed.
    @Published private(set) var showsAgentAnnotationDismissControl = false
    /// Most recent main-agent context submitted by this app and the newest overlay
    /// generation accepted for it. Overlay events from an older capture must not
    /// guide the user against a newer desktop state.
    private var latestOverlayContextID: String?
    private var latestOverlayContextGeneration = 0
    /// Exact app-local screenshot samples for the latest overlay context, keyed
    /// by both screen id and screenshot id. Never serialized to agentd.
    private var latestOverlayScreenshotsByID: [String: PickyScreenshotContext] = [:]
    /// App/window/URL identity captured with the exact screenshots above. The scene
    /// monitor keeps this app-local and never extends the app-agentd protocol.
    private var latestAnnotationSceneBaseline: PickyAnnotationSceneBaseline?
    private var activeAnnotationSceneIdentity: PickyAnnotationSceneIdentity?
    private var projectedAnnotationSceneIdentity: PickyAnnotationSceneIdentity?
    private let annotationSceneMonitor: PickyAnnotationSceneMonitor?
    /// Stable base palette for each streamed context-generation/screen. Individual
    /// shapes may override it only when local contrast falls below the threshold.
    private var annotationBasePaletteByTurnScreen: [String: PickyAnnotationPaletteRole] = [:]

    let buddyDictationManager: BuddyDictationManager
    let globalPushToTalkShortcutMonitor = GlobalPushToTalkShortcutMonitor()
    let overlayWindowManager = OverlayWindowManager()
    let quickInputDoubleTapDetector = QuickInputDoubleTapDetector()
    let quickInputPanelManager: QuickInputPanelManager
    let mainQuestionPanelManager: PickyMainQuestionPanelManager
    let mainCancelPillPanelManager = PickyMainCancelPillPanelManager()
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
    let voiceContextCapturePipeline: PickyVoiceContextCapturePipeline
    private var armedPickleDispatchMode: PickyArmedPickleDispatchMode
    /// Mirrors the persisted screen-context scope so overlay views can gate the
    /// capture-context border to the display(s) that will actually be captured.
    @Published private(set) var screenContextScope: PickyScreenContextScope
    /// Mirrors the persisted "attach screenshots only when drawn" toggle so the
    /// capture-context border tracks the per-screen ink attachment gate.
    @Published private(set) var attachScreenshotsOnlyWhenInked: Bool

    /// True while Picky is actively capturing (or about to capture) the screen
    /// as neutral model context — during PTT recording or while the Quick Input
    /// panel is open. Drives the capture-context border on in-scope overlays.
    var isCapturingScreenContext: Bool {
        voiceState == .listening || isQuickInputPanelVisible
    }

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
        armedPickleDispatchMode: PickyArmedPickleDispatchMode? = nil,
        annotationSceneMonitor: PickyAnnotationSceneMonitor? = nil
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
        let resolvedVoiceContextCaptureCoordinator = voiceContextCaptureCoordinator ?? PickyVoiceContextCaptureCoordinator()
        self.voiceContextCaptureCoordinator = resolvedVoiceContextCaptureCoordinator
        self.voiceContextCapturePipeline = PickyVoiceContextCapturePipeline(
            coordinator: resolvedVoiceContextCaptureCoordinator
        )
        self.armedPickleDispatchMode = armedPickleDispatchMode ?? resolvedInitialSettings.armedPickleDispatchMode
        self.screenContextScope = resolvedInitialSettings.screenContextScope
        self.attachScreenshotsOnlyWhenInked = resolvedInitialSettings.attachScreenshotsOnlyWhenInked
        self.annotationSceneMonitor = annotationSceneMonitor
            ?? (PickyRuntimeEnvironment.isRunningUnitTests ? nil : PickyAnnotationSceneMonitor())
        self.inkCaptureCoordinator = inkCaptureCoordinator
        self.quickInputPanelManager = QuickInputPanelManager(
            appearanceStore: appearanceStore,
            fontScaleStore: fontScaleStore
        )
        self.mainQuestionPanelManager = PickyMainQuestionPanelManager(
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
        self.annotationSceneMonitor?.onOutput = { [weak self] output in
            self?.applyAnnotationSceneMonitorOutput(output)
        }
    }

    /// The currently running AI response task, if any. Cancelled when the user
    /// speaks again so a new response can begin immediately.
    var currentResponseTask: Task<Void, Never>?
    private var agentEventTask: Task<Void, Never>?
    private var directMessageContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]
    let inkCaptureCoordinator: any PickyInkCaptureCoordinating
    let pendingInkCaptures = PickyPendingInkCaptureStore()
    var screenContextVoiceTargetByInputID: [UUID: String] = [:]
    /// Monotonic marker for observing when queued interaction events have published.
    private(set) var interactionProjectionSequence: UInt64 = 0
    lazy var interactionCoordinator: PickyInteractionCoordinator = {
        let effectRunner = CompanionInteractionEffectRunner(
            manager: self,
            captureTextContext: { [weak self] in self?.runCaptureTextContextEffect(inputID: $0, text: $1) },
            submitText: { [weak self] in self?.runSubmitTextEffect(inputID: $0, context: $1, text: $2) },
            captureVoiceContext: { [weak self] in self?.runCaptureVoiceContextEffect(inputID: $0, transcript: $1, targetSessionID: $2) },
            submitMain: { [weak self] in self?.runSubmitMainEffect(inputID: $0, transcript: $1, context: $2) },
            followUpPickle: { [weak self] in self?.runFollowUpPickleEffect(inputID: $0, sessionID: $1, transcript: $2, context: $3) },
            scheduleMinimumDisplay: { [weak self] in self?.runMinimumDisplayTimerEffect(timerID: $0, speechID: $1, inputID: $2, delay: $3) },
            speak: { [weak self] in self?.runSpeakEffect(speechID: $0, text: $1, contextID: $2) },
            prefetchSpeech: { [weak self] in self?.runPrefetchSpeechEffect(text: $0) },
            stopSpeech: { [weak self] in self?.stopCurrentInteractionSpeech(speechID: $0) },
            scheduleAnnotationReveal: { [weak self] in self?.runAnnotationRevealEffect(id: $0, delay: $1) },
            scheduleAnnotationRecoveryExpiry: { [weak self] in self?.runAnnotationRecoveryExpiryEffect(identity: $0, delay: $1) }
        )
        let coordinator = PickyInteractionCoordinator(
            envelopeMaker: PickyInteractionStaticEnvelopeMaker(),
            effectRunner: effectRunner
        )
        coordinator.onProjectionPublished = { [weak self] sequence, projection in
            self?.interactionProjectionSequence = sequence
            self?.applyInteractionProjection(projection)
        }
        return coordinator
    }()

    private var shortcutTransitionCancellable: AnyCancellable?
    private var quickInputDoubleTapCancellable: AnyCancellable?
    private var mainQuestionPanelCancellable: AnyCancellable?
    private var mainCancelPillKeyWindowObservers: [NSObjectProtocol] = []
    /// Command ids currently awaiting an answer rejection from agentd. Their
    /// correlated error events keep the question panel open instead of taking
    /// the global connection-loss cleanup path.
    private var pendingMainQuestionAnswerCommandIDs = Set<String>()
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
    private var responseStateTask: Task<Void, Never>?
    private var deferredInteractionSpeechTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    private var deferredFinishAwaitingAgentResponseSessionID: String?
    /// Caps how long the recognized-transcript bubble lingers after STT.
    private var voicePromptBubbleAutoHideTask: Task<Void, Never>?
    private struct MainTurnCancellation {
        let shouldSettleLocalState: Bool
        let followUpSessionID: String?
        let generation: UInt64
    }

    /// Increments when a new main turn starts so late cancellation completions
    /// cannot reset that newer turn's local projection.
    private var mainTurnGeneration: UInt64 = 0

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
    private var pendingAgentResponseStartedAt: Date? {
        didSet { updateMainCancelPillPresentation() }
    }
    /// Follow-up destination for the currently cancellable turn. Voice uses its
    /// utterance snapshot; Quick Input records its armed Pickle after agentd
    /// accepts the dispatch so both cancellation surfaces stop the same work.
    private var activeMainTurnFollowUpSessionID: String? {
        didSet { updateMainCancelPillPresentation() }
    }
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
    @Published private(set) var isWaitingForCursorResponse: Bool = false {
        didSet { updateMainCancelPillPresentation() }
    }
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

    func makePiOAuthLoginRunner() -> PickyPiOAuthLoginRunning {
        PickyPiOAuthLoginAgentRunner(client: agentClient)
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
        wireMainQuestionPanel()
        wireMainCancelPill()
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

    func stop() {
        globalPushToTalkShortcutMonitor.stop()
        globalPushToTalkShortcutMonitor.rawEventForwarder = nil
        quickInputDoubleTapDetector.reset()
        quickInputPanelManager.dismiss()
        mainQuestionPanelManager.dismiss()
        mainCancelPillPanelManager.dismiss()
        mainCancelPillKeyWindowObservers.forEach(NotificationCenter.default.removeObserver)
        mainCancelPillKeyWindowObservers.removeAll()
        cancelInkCapture()
        inkCaptureCoordinator.teardownEventTap()
        buddyDictationManager.cancelCurrentDictation()
        overlayWindowManager.hideOverlay()
        transientHideTask?.cancel()
        annotationSceneMonitor?.stop()
        activeAnnotationSceneIdentity = nil

        currentResponseTask?.cancel()
        currentResponseTask = nil
        voiceContextCapturePipeline.cancelAll()
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
        mainQuestionPanelCancellable?.cancel()
        mainQuestionPanelCancellable = nil
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
            // Pre-warm the shared suppressing mouse tap so the first ink draw
            // doesn't leak its opening mouse-down while a fresh tap is created.
            inkCaptureCoordinator.ensureEventTapInstalled()
        } else {
            globalPushToTalkShortcutMonitor.stop()
            inkCaptureCoordinator.teardownEventTap()
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
        isRequestingScreenContent = true
        Task {
            do {
                let content = try await PickySystemPermissionGateway.shared.screenShareableContent()
                guard let display = content.displays.first else {
                    await MainActor.run { isRequestingScreenContent = false }
                    return
                }
                let filter = SCContentFilter(display: display, excludingWindows: [])
                let config = SCStreamConfiguration()
                config.width = 320
                config.height = 240
                let image = try await PickySystemPermissionGateway.shared.captureScreenshot(contentFilter: filter, configuration: config)
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

    /// Explicit user action from the post-narration annotation close control.
    /// Stop scene monitoring immediately; the reducer clear then removes projection state.
    func dismissAgentAnnotations() {
        guard showsAgentAnnotationDismissControl else { return }
        annotationBasePaletteByTurnScreen.removeAll()
        annotationSceneMonitor?.stop()
        activeAnnotationSceneIdentity = nil
        interactionCoordinator.accept(
            .agentAnnotationsRequested(mode: .clear, annotations: []),
            correlation: PickyInteractionCorrelation(source: .system)
        )
    }

    // MARK: - Private

    func setLocalOverlayReason(_ reason: PickyOverlayReason, visible: Bool) {
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

    private func cancelInkCapture() {
        inkCaptureCoordinator.cancel()
        setLocalOverlayReason(.activeInkCapture, visible: false)
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
        Task { [weak self] in
            do {
                let granted = try await PickySystemPermissionGateway.shared.requestMicrophoneAccess()
                self?.hasMicrophonePermission = granted
            } catch { self?.hasMicrophonePermission = false }
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
                self?.voiceContextCapturePipeline.cancelAll()
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
                self?.screenContextScope = settings.screenContextScope
                self?.attachScreenshotsOnlyWhenInked = settings.attachScreenshotsOnlyWhenInked
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
            mainLiveActivities = []
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
        globalPushToTalkShortcutMonitor.rawEventForwarder = { [weak self] eventType, keyCode, flagsRawValue, isAutorepeat in
            guard let self else { return }
            self.quickInputDoubleTapDetector.handleGlobalEvent(
                eventType: eventType,
                keyCode: keyCode,
                modifierFlagsRawValue: flagsRawValue
            )
            guard PickyMainCancelPillPolicy.shouldHandleEscape(
                eventType: eventType,
                keyCode: keyCode,
                isAutorepeat: isAutorepeat
            ) else { return }
            self.mainCancelPillPanelManager.handleEscape()
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

    private func wireMainCancelPill() {
        mainCancelPillPanelManager.onCancel = { [weak self] in
            guard let self else { return false }
            return await self.cancelMainTurn()
        }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
            mainCancelPillKeyWindowObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.updateMainCancelPillPresentation()
                    }
                }
            )
        }
        updateMainCancelPillPresentation()
    }

    private func updateMainCancelPillPresentation() {
        let isMainTurnInFlight = PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: pendingAgentResponseStartedAt != nil,
            voiceState: voiceState,
            isWaitingForCursorResponse: isWaitingForCursorResponse,
            hasLiveActivities: !mainLiveActivities.isEmpty,
            hasActiveFollowUpTurn: activeMainTurnFollowUpSessionID != nil
        )
        // Picky's interactive panels are non-activating but become the key
        // window. While one owns keyboard input, ESC must retain its native
        // close/cancel behavior instead of arming this global control.
        mainCancelPillPanelManager.update(
            isMainTurnInFlight: isMainTurnInFlight,
            isPickyPanelKeyWindow: NSApp.keyWindow != nil
        )
    }

    private func wireMainQuestionPanel() {
        mainQuestionPanelManager.onAnswer = { [weak self] requestID, value in
            guard let self else { return PickyAgentClientError.disconnected }
            let command = PickyCommandEnvelope(
                type: .answerMainExtensionUi,
                requestId: requestID,
                value: value
            )
            self.pendingMainQuestionAnswerCommandIDs.insert(command.id)
            defer { self.pendingMainQuestionAnswerCommandIDs.remove(command.id) }
            do {
                let answerError = try await self.agentClient.sendAwaitingError(command, timeout: 1.0)
                guard PickyMainQuestionPanelPolicy.shouldClearPendingQuestion(after: answerError) else {
                    return PickyMainQuestionPanelAnswerError(message: answerError?.message ?? "Failed to answer question")
                }
                if self.mainPendingQuestion?.id == requestID {
                    self.mainPendingQuestion = nil
                }
                return nil
            } catch {
                return error
            }
        }
        mainQuestionPanelCancellable = $mainPendingQuestion
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] request in
                Task { @MainActor [weak self] in
                    self?.mainQuestionPanelManager.update(request: request)
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
            voiceContextCapturePipeline.beginInput()
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
                let unusedInkCapture = voiceContextCapturePipeline.finishInput(
                    inputID: interactionVoiceInputID,
                    voiceFollowUpSessionID: voiceFollowUpSessionIDForCurrentUtterance,
                    inkCapture: pendingInkCaptures.consume(for: interactionVoiceInputID)
                )
                if let unusedInkCapture {
                    pendingInkCaptures.store(unusedInkCapture, for: interactionVoiceInputID)
                }
                interactionCoordinator.accept(
                    .voiceReleased(inputID: interactionVoiceInputID),
                    correlation: PickyInteractionCorrelation(inputID: interactionVoiceInputID, source: .voice)
                )
            } else {
                finishInkCapture(inputID: nil)
                voiceContextCapturePipeline.clearInputTiming()
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
            let visualDslEnabled = prepareArmedPickleVisualDslContext(contextPacket, sessionID: targetSessionID)
            try await agentClient.send(PickyCommandEnvelope(
                type: .steer,
                context: contextPacket,
                sessionId: targetSessionID,
                text: transcript,
                visualDslEnabled: visualDslEnabled
            ))
            clearScreenContextTargetIfCurrent(targetSessionID)
            return PickyAgentSubmissionReceipt(sessionID: targetSessionID, message: "")
        case .followUpPickle(let targetSessionID):
            print("🎙️ Picky voice route — FOLLOW-UP Pickle=\(targetSessionID)")
            let context = pickleFollowUpContext(contextPacket, sessionID: targetSessionID)
            let visualDslEnabled = prepareArmedPickleVisualDslContext(context, sessionID: targetSessionID)
            try await agentClient.send(PickyCommandEnvelope(
                type: .followUp,
                context: context,
                sessionId: targetSessionID,
                text: transcript,
                visualDslEnabled: visualDslEnabled
            ))
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

    private func prepareArmedPickleVisualDslContext(_ context: PickyContextPacket, sessionID: String) -> Bool {
        guard selectionStore.screenContextTargetSessionID == sessionID,
              !context.screenshots.isEmpty else { return false }
        interactionCoordinator.accept(
            .agentAnnotationsClearedForUserInput,
            correlation: PickyInteractionCorrelation(contextID: context.id, sessionID: sessionID, source: .agent)
        )
        noteMainOverlayContext(context)
        return true
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

    func clearScreenContextTargetIfCurrent(_ sessionID: String?) {
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
        activeMainTurnFollowUpSessionID = targetSessionID
        do {
            guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                transcript: text,
                source: source,
                inkCapture: inkCapture
            ) else {
                directMessageError = L10n.t("error.directMessage.contextEmpty")
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                activeMainTurnFollowUpSessionID = nil
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
            let visualDslEnabled = prepareArmedPickleVisualDslContext(context, sessionID: targetSessionID)
            let rejection = try await agentClient.sendAwaitingError(
                PickyCommandEnvelope(
                    type: commandType,
                    context: context,
                    sessionId: targetSessionID,
                    text: text,
                    visualDslEnabled: visualDslEnabled
                ),
                timeout: 1.0
            )
            if let rejection {
                directMessageError = L10n.t("error.directMessage.sendFailed", rejection.message)
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                activeMainTurnFollowUpSessionID = nil
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
            activeMainTurnFollowUpSessionID = nil
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

        activeMainTurnFollowUpSessionID = nil
        let inputID = UUID()
        if let inkCapture, inkCapture.hasVisibleInk {
            pendingInkCaptures.store(inkCapture, for: inputID)
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
        showsAgentAnnotationDismissControl = projection.showsAgentAnnotationDismissControl
        hasActiveVisualNarration = projection.state.activeVisualNarrationIdentity != nil
        hasActivePointVisualNarration = projection.hasActivePointVisualNarration
        isProgressiveResponseVisible = projection.latestDisplayText != nil
            && (hasActiveVisualNarration || projection.state.streamedResponseText != nil)
        if isProgressiveResponseVisible, let latestDisplayText = projection.latestDisplayText {
            latestAgentSessionSummary = latestDisplayText
            voicePromptBubbleState = .hidden
        }
        let previousProjectedSceneIdentity = projectedAnnotationSceneIdentity
        projectedAnnotationSceneIdentity = projection.state.annotationSceneIdentity
        annotationSceneMonitor?.setAllowsTolerantRestoration(
            projection.state.annotationSceneRecoveryAllowed
        )
        annotationSceneMonitor?.setNarrationActive(
            projection.isSpeaking || projection.state.activeVisualNarrationSentenceCount > 0
        )
        if previousProjectedSceneIdentity != nil,
           projection.state.annotationSceneIdentity == nil,
           activeAnnotationSceneIdentity == previousProjectedSceneIdentity {
            annotationSceneMonitor?.stop()
            activeAnnotationSceneIdentity = nil
        }
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
        activeMainTurnFollowUpSessionID = nil
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

    private func runCaptureTextContextEffect(inputID: UUID, text: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let inkCapture = pendingInkCaptures.consume(for: inputID)
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

    private func runSubmitTextEffect(inputID: UUID, context: PickyContextPacket, text: String) {
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

    private func runSubmitMainEffect(inputID: UUID, transcript: String, context: PickyContextPacket) {
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
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice", contextID: context.id)
                finishVoiceSubmissionIfIdle(inputID: inputID)
            } catch is CancellationError {
                // User spoke again — response was interrupted.
            } catch {
                handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
            }
        }
    }

    private func runFollowUpPickleEffect(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let isScreenContextTargetedInput = screenContextVoiceTargetByInputID.removeValue(forKey: inputID) == sessionID
            if isScreenContextTargetedInput {
                let command: PickyCommandEnvelope
                let source: String
                switch armedPickleDispatchMode {
                case .steer:
                    let visualDslEnabled = prepareArmedPickleVisualDslContext(context, sessionID: sessionID)
                    command = PickyCommandEnvelope(
                        type: .steer,
                        context: context,
                        sessionId: sessionID,
                        text: transcript,
                        visualDslEnabled: visualDslEnabled
                    )
                    source = "voice-steer"
                case .followUp:
                    let followUpContext = pickleFollowUpContext(context, sessionID: sessionID)
                    let visualDslEnabled = prepareArmedPickleVisualDslContext(followUpContext, sessionID: sessionID)
                    command = PickyCommandEnvelope(
                        type: .followUp,
                        context: followUpContext,
                        sessionId: sessionID,
                        text: transcript,
                        visualDslEnabled: visualDslEnabled
                    )
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
                    handleAgentSubmissionAccepted(receipt: receipt, source: source, contextID: context.id)
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
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice-follow-up", contextID: context.id)
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
    func completeVoiceInteractionIfCurrent(inputID: UUID) -> Bool {
        guard interactionVoiceInputID == inputID else { return false }
        interactionVoiceInputID = nil
        return true
    }

    private func runAnnotationRevealEffect(id: UUID, delay: TimeInterval) {
        interactionTimerScheduler.schedule(after: delay) { [weak self] in
            self?.interactionCoordinator.accept(
                .agentAnnotationRevealDue(id: id),
                correlation: PickyInteractionCorrelation(source: .system)
            )
        }
    }

    private func runAnnotationRecoveryExpiryEffect(identity: PickyAnnotationSceneIdentity, delay: TimeInterval) {
        interactionTimerScheduler.schedule(after: delay) { [weak self] in
            self?.interactionCoordinator.accept(
                .agentAnnotationRecoveryExpired(identity: identity),
                correlation: PickyInteractionCorrelation(source: .system)
            )
        }
    }

    private func runMinimumDisplayTimerEffect(timerID: UUID, speechID: UUID?, inputID: UUID?, delay: TimeInterval) {
        interactionTimerScheduler.schedule(after: delay) { [weak self] in
            self?.interactionCoordinator.effectCompleted(
                .minimumDisplayTimerFired(timerID: timerID, speechID: speechID, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, speechID: speechID, source: .system)
            )
        }
    }

    private func runSpeakEffect(speechID: UUID, text: String, contextID: String?) {
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        // Convert Markdown to visible prose and strip speech-hostile supplementary
        // detail immediately before synthesis. The queued reply keeps the original
        // text so cursor and conversation UI still render full Markdown.
        let spoken = sanitizedTextForSpeech(text)
        guard !spoken.isEmpty else {
            logSpeech("interaction skipped empty sanitized speechID=\(speechID) context=\(contextID ?? "none")")
            interactionCoordinator.effectCompleted(
                .speechFinished(speechID: speechID),
                correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
            )
            return
        }
        startOrDeferInteractionSpeech(speechID: speechID, text: spoken, contextID: contextID, requestedAt: Date())
    }

    private func runPrefetchSpeechEffect(text: String) {
        // Apply the same speech transform runSpeakEffect uses so the warmed
        // audio is keyed by the exact string the provider will later synthesize.
        let spoken = sanitizedTextForSpeech(text)
        guard !spoken.isEmpty else { return }
        speechPlaybackProvider.prefetch(spoken)
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
        // Queue transitions already completed the preceding utterance. Do not
        // call stopSpeaking here: Edge's explicit stop clears its warmed-audio
        // cache before speak() can reclaim the next sentence's prefetch.
        // Providers own replacement inside speak(), while reducer preemption
        // continues to use the explicit .stopSpeech effect.
        responseStateTask?.cancel()
        responseStateTask = nil
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
        // `speak` has accepted the utterance and scheduled any provider preroll;
        // this is the earliest reliable app-side "about to speak" boundary.
        interactionCoordinator.effectCompleted(
            .speechStarted(text: text, speechID: speechID, sourceContextID: contextID),
            correlation: PickyInteractionCorrelation(contextID: contextID, speechID: speechID, source: .system)
        )

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
    /// Clear resident overlay, progressive, and visual-narration state when the daemon
    /// connection drops or reports a terminal protocol error mid-response. Reuses the
    /// local session-reset cleanup (annotations, progressive narration, active visual
    /// turn, queued speech, speaking output) but does NOT clear persisted messages or
    /// send a daemon command, so a later reconnect keeps the transcript intact.
    private func clearInteractionStateForConnectionLoss() {
        mainLiveActivities = []
        mainPendingQuestion = nil
        annotationSceneMonitor?.stop()
        activeAnnotationSceneIdentity = nil
        interactionCoordinator.accept(
            .mainAgentSessionReset,
            correlation: PickyInteractionCorrelation(source: .system)
        )
    }

    func resetMainAgentSession() async -> Bool {
        guard !isResettingMainAgentSession else { return false }
        isResettingMainAgentSession = true
        directMessageError = nil
        defer { isResettingMainAgentSession = false }

        do {
            try await agentClient.send(PickyCommandEnvelope(type: .resetMainAgent))
            annotationBasePaletteByTurnScreen.removeAll()
            annotationSceneMonitor?.stop()
            activeAnnotationSceneIdentity = nil
            interactionCoordinator.accept(
                .mainAgentSessionReset,
                correlation: PickyInteractionCorrelation(source: .system)
            )
            mainAgentMessages = []
            mainLiveActivities = []
            mainPendingQuestion = nil
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

    func handleAgentSubmissionAccepted(receipt: PickyAgentSubmissionReceipt, source: String, contextID: String? = nil) {
        PickyAnalytics.trackAgentSubmissionAccepted(sessionID: receipt.sessionID)
        print("🧠 Picky local agent submission accepted: \(receipt.sessionID)")
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=packetSubmitted contextID=\(contextID ?? "none") sessionID=\(receipt.sessionID) source=\(source)"
        )

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
                    await MainActor.run {
                        self.finishAwaitingAgentResponse(visibleText: "picky-agentd disconnected", spokenText: nil)
                        self.clearInteractionStateForConnectionLoss()
                    }
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
        case .sessionResourcesReloaded, .sessionLogAppended, .toolActivityUpdated, .sessionTodoStateUpdated, .sessionArchivedAuthoritative, .pluginsReloaded,
             .packageOperationProgress, .packageOperationCompleted:
            // Progress events are already represented in the HUD. They should not
            // replace a cursor bubble that is currently speaking/showing a real
            // response, otherwise generic text like "작업 진행 중…" hides the answer.
            // pluginsReloaded is handled by the plugin manager controller in the
            // panel; CompanionManager doesn't need to react.
            break
        case .extensionUiRequest(let request):
            latestAgentSessionSummary = request.prompt ?? request.title ?? "Agent is waiting for input"
        case .quickReply(let reply):
            PickyLog.notice(
                .latency,
                prefix: "⏱️ Picky latency —",
                message: "event=quickReplyReceived contextID=\(reply.contextId) sessionID=\(reply.sessionId ?? "none") chars=\(reply.text.count)"
            )
            applyQuickReplyEvent(reply)
        case .mainTurnSettled(let contextID):
            mainLiveActivities = []
            applyMainTurnSettled(contextID: contextID)
        case .mainNarrationChunk(let chunk):
            applyMainNarrationChunk(chunk)
        case .mainVisualNarrationSegmentPrepared(let segment):
            applyVisualNarrationSegmentPrepared(segment)
        case .mainVisualNarrationSegmentSentence(let sentence):
            applyVisualNarrationSegmentSentence(sentence)
        case .mainVisualNarrationSegmentCommitted(let segment):
            applyVisualNarrationSegmentCommitted(segment)
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
        case .mainActivityUpdated(let activity):
            guard let activity else {
                mainLiveActivities = []
                break
            }
            mainLiveActivities = PickyMainActivityStack.apply(activity, to: mainLiveActivities)
        case .mainExtensionUiRequested(let request):
            mainPendingQuestion = request
        case .mainExtensionUiCancelled(let requestId):
            if mainPendingQuestion?.id == requestId {
                mainPendingQuestion = nil
            }
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
            if let commandID = error.commandId,
               pendingMainQuestionAnswerCommandIDs.contains(commandID) {
                break
            }
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
            clearInteractionStateForConnectionLoss()
        case .hello, .sessionSnapshot, .artifactUpdated, .slashCommandsSnapshot,
             .piOAuthStatus, .piOAuthUrlRequested, .piOAuthPromptRequested, .piAuthenticationReloaded,
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
        if reply.didStreamNarration == true {
            interactionCoordinator.accept(
                .streamedQuickReplyFinal(
                    contextID: reply.contextId,
                    text: reply.text,
                    originSource: originSource,
                    replyKind: replyKind,
                    sessionID: reply.sessionId,
                    inputID: reply.inputId
                ),
                correlation: PickyInteractionCorrelation(contextID: reply.contextId, sessionID: reply.sessionId, source: .agent)
            )
            return
        }
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
            let spoken = sanitizedTextForSpeech(reply.text)
            finishAwaitingAgentResponse(visibleText: reply.text, spokenText: spoken, enforceMinimumProcessingDuration: true)
        }
    }

    private func applyMainTurnSettled(contextID: String) {
        activeMainTurnFollowUpSessionID = nil
        let isMatchingWaitingTurn: Bool
        if case .waitingForAgent(_, let waitingContextID, _) = interactionCoordinator.projection.state.output {
            isMatchingWaitingTurn = waitingContextID == contextID
        } else {
            isMatchingWaitingTurn = false
        }
        interactionCoordinator.accept(
            .mainTurnSettled(contextID: contextID),
            correlation: PickyInteractionCorrelation(contextID: contextID, source: .agent)
        )
        guard isMatchingWaitingTurn else { return }
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        if voiceState == .processing {
            reduceVoiceInteraction(.reset)
        }
    }

    private func applyMainNarrationChunk(_ chunk: PickyMainNarrationChunkEvent) {
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=mainNarrationChunkReceived contextID=\(chunk.contextId) sessionID=\(chunk.sessionId ?? "none") chars=\(chunk.text.count)"
        )
        let owner = interactionOwner(for: chunk.contextId)
        let originSource = chunk.originSource ?? owner.map { $0.isVoiceOwned ? .voice : .text }
        let supportsIncrementalPlayback = ttsPlaybackEnabled && speechPlaybackProvider.supportsIncrementalPlayback
        interactionCoordinator.accept(
            .narrationChunk(
                contextID: chunk.contextId,
                text: chunk.text,
                originSource: originSource,
                replyKind: chunk.replyKind ?? .main,
                sessionID: chunk.sessionId,
                shouldSpeak: supportsIncrementalPlayback,
                shouldSpeakFinalReply: ttsPlaybackEnabled && !supportsIncrementalPlayback
            ),
            correlation: PickyInteractionCorrelation(contextID: chunk.contextId, sessionID: chunk.sessionId, source: .agent)
        )
    }

    private func applyVisualNarrationSegmentPrepared(
        _ segment: PickyVisualNarrationSegmentPreparedEvent
    ) {
        guard shouldApplyOverlay(
            contextID: segment.identity.contextId,
            generation: segment.identity.contextGeneration
        ) else { return }
        do {
            let visual: PickyResolvedVisualNarrationVisual
            switch segment.visual {
            case .point(let request):
                guard request.contextId == segment.identity.contextId,
                      request.contextGeneration == segment.identity.contextGeneration else { return }
                let target = try PickyPointerOverlayResolver.resolve(request)
                visual = .point(PickyPointerTarget(
                    id: request.id,
                    source: .agent,
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    bubbleText: target.bubbleText,
                    duration: target.duration
                ))
            case .annotations(let request):
                guard request.contextId == segment.identity.contextId,
                      request.contextGeneration == segment.identity.contextGeneration else { return }
                let (annotations, screenshot) = try resolveAgentAnnotations(request)
                prepareAnnotationSceneIfNeeded(
                    request: request,
                    screenshot: screenshot,
                    annotations: annotations
                )
                visual = .annotations(annotations)
            }
            interactionCoordinator.accept(
                .visualNarrationSegmentPrepared(identity: segment.identity, visual: visual),
                correlation: PickyInteractionCorrelation(contextID: segment.identity.contextId, source: .agent)
            )
        } catch {
            PickyLog.logger(.agentClient).debug(
                "Visual narration segment prepare ignored ordinal=\(segment.identity.ordinal) error=\(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func applyVisualNarrationSegmentSentence(
        _ sentence: PickyVisualNarrationSegmentSentenceEvent
    ) {
        PickyLog.notice(
            .latency,
            prefix: "⏱️ Picky latency —",
            message: "event=visualNarrationSentenceReceived contextID=\(sentence.identity.contextId) sessionID=\(sentence.sessionId ?? "none") ordinal=\(sentence.identity.ordinal) index=\(sentence.index) chars=\(sentence.text.count)"
        )
        guard shouldApplyOverlay(
            contextID: sentence.identity.contextId,
            generation: sentence.identity.contextGeneration
        ) else { return }
        let playbackMode: PickyVisualNarrationPlaybackMode
        if !ttsPlaybackEnabled {
            playbackMode = .silent
        } else if speechPlaybackProvider.supportsIncrementalPlayback {
            playbackMode = .incremental
        } else {
            playbackMode = .finalReply
        }
        let owner = interactionOwner(for: sentence.identity.contextId)
        let originSource = sentence.originSource ?? owner.map { $0.isVoiceOwned ? .voice : .text }
        interactionCoordinator.accept(
            .visualNarrationSegmentSentence(
                identity: sentence.identity,
                index: sentence.index,
                text: sentence.text,
                originSource: originSource,
                replyKind: sentence.replyKind ?? .main,
                sessionID: sentence.sessionId,
                playbackMode: playbackMode
            ),
            correlation: PickyInteractionCorrelation(
                contextID: sentence.identity.contextId,
                sessionID: sentence.sessionId,
                source: .agent
            )
        )
    }

    private func applyVisualNarrationSegmentCommitted(
        _ segment: PickyVisualNarrationSegmentCommittedEvent
    ) {
        guard shouldApplyOverlay(
            contextID: segment.identity.contextId,
            generation: segment.identity.contextGeneration
        ) else { return }
        interactionCoordinator.accept(
            .visualNarrationSegmentCommitted(
                identity: segment.identity,
                text: segment.text,
                sentenceCount: segment.sentenceCount
            ),
            correlation: PickyInteractionCorrelation(
                contextID: segment.identity.contextId,
                sessionID: segment.sessionId,
                source: .agent
            )
        )
    }

    private func applyPointerOverlayRequest(_ request: PickyPointerOverlayRequest) {
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let target = try PickyPointerOverlayResolver.resolve(request)
            interactionCoordinator.accept(
                .pointerRequested(PickyPointerTarget(
                    id: request.id,
                    source: .agent,
                    screenLocation: target.screenLocation,
                    displayFrame: target.displayFrame,
                    bubbleText: target.bubbleText,
                    duration: target.duration
                )),
                correlation: PickyInteractionCorrelation(pointerID: request.id, source: .pointer)
            )
            latestAgentSessionSummary = target.bubbleText.map { L10n.t("agent.summary.pointingScreen", $0) } ?? L10n.t("agent.summary.pointingScreenAnon")
        } catch {
            latestAgentSessionSummary = "Pointer overlay ignored: \(error.localizedDescription)"
        }
    }

    private func applyAnnotationOverlayRequest(_ request: PickyAnnotationOverlayRequest) {
        if request.mode == .clear {
            annotationBasePaletteByTurnScreen.removeAll()
            annotationSceneMonitor?.stop()
            activeAnnotationSceneIdentity = nil
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: .clear, annotations: []),
                correlation: PickyInteractionCorrelation(source: .agent)
            )
            return
        }
        guard shouldApplyOverlay(contextID: request.contextId, generation: request.contextGeneration) else { return }
        do {
            let (annotations, screenshot) = try resolveAgentAnnotations(request)
            prepareAnnotationSceneIfNeeded(
                request: request,
                screenshot: screenshot,
                annotations: annotations
            )
            interactionCoordinator.accept(
                .agentAnnotationsRequested(mode: request.mode, annotations: annotations),
                correlation: PickyInteractionCorrelation(contextID: request.contextId, source: .agent)
            )
            if request.mode != .clear {
                latestAgentSessionSummary = "Showing \(annotations.count) screen annotation\(annotations.count == 1 ? "" : "s")."
            }
        } catch {
            latestAgentSessionSummary = "Annotation overlay ignored: \(error.localizedDescription)"
        }
    }

    private func resolveAgentAnnotations(
        _ request: PickyAnnotationOverlayRequest
    ) throws -> ([PickyAgentAnnotation], PickyScreenshotContext?) {
        let screenshotSize = request.screenshotSize.map { CGSize(width: $0.width, height: $0.height) }
        let screenshot = overlayScreenshot(for: request)
        let sampleGrid = screenshot?.annotationColorSampleGrid
        let paletteKey = annotationPaletteKey(for: request)
        if request.mode == .replace {
            annotationBasePaletteByTurnScreen[paletteKey] = nil
        }
        let basePalette = annotationBasePaletteByTurnScreen[paletteKey]
            ?? screenshotSize.flatMap {
                PickyAnnotationPaletteResolver.basePalette(
                    for: request.annotations,
                    screenshotSize: $0,
                    sampleGrid: sampleGrid
                )
            }
        let annotations = try PickyAnnotationOverlayResolver.resolve(
            request,
            sampleGrid: sampleGrid,
            preferredBasePalette: basePalette
        )
        if let basePalette {
            annotationBasePaletteByTurnScreen[paletteKey] = basePalette
        }
        return (annotations, screenshot)
    }

    private func noteMainOverlayContext(_ context: PickyContextPacket) {
        mainTurnGeneration &+= 1
        annotationSceneMonitor?.stop()
        activeAnnotationSceneIdentity = nil
        latestOverlayContextID = context.id
        latestOverlayContextGeneration = 0
        latestAnnotationSceneBaseline = PickyAnnotationSceneBaseline.capture(from: context)
        annotationBasePaletteByTurnScreen.removeAll()
        latestOverlayScreenshotsByID = context.screenshots.reduce(into: [:]) { result, screenshot in
            result[screenshot.id] = screenshot
            if let screenID = screenshot.screenId {
                result[screenID] = screenshot
            }
        }
    }

    private func prepareAnnotationSceneIfNeeded(
        request: PickyAnnotationOverlayRequest,
        screenshot: PickyScreenshotContext?,
        annotations: [PickyAgentAnnotation]
    ) {
        guard let monitor = annotationSceneMonitor,
              let baseline = latestAnnotationSceneBaseline,
              let contextID = request.contextId,
              let generation = request.contextGeneration,
              baseline.contextID == contextID,
              let screenshot else {
            return
        }
        let identity: PickyAnnotationSceneIdentity
        if let active = activeAnnotationSceneIdentity,
           active.contextID == contextID,
           active.generation == generation {
            identity = active
        } else {
            identity = PickyAnnotationSceneIdentity(
                contextID: contextID,
                generation: generation,
                token: UUID()
            )
            activeAnnotationSceneIdentity = identity
            interactionCoordinator.accept(
                .agentAnnotationScenePrepared(identity: identity),
                correlation: PickyInteractionCorrelation(contextID: contextID, source: .system)
            )
            monitor.start(
                identity: identity,
                baseline: baseline,
                allowsTolerantRestoration: true
            )
        }
        monitor.updateTarget(
            screenshot: screenshot,
            annotations: annotations,
            mode: request.mode
        )
    }

    private func applyAnnotationSceneMonitorOutput(_ output: PickyAnnotationSceneMonitorOutput) {
        let identity: PickyAnnotationSceneIdentity
        let event: PickyInteractionEvent
        switch output {
        case .matched(let matchedIdentity):
            identity = matchedIdentity
            event = .agentAnnotationSceneMatched(identity: matchedIdentity)
        case .mismatched(let mismatchedIdentity, let reason):
            identity = mismatchedIdentity
            event = .agentAnnotationSceneMismatched(identity: mismatchedIdentity, reason: reason)
        }
        guard activeAnnotationSceneIdentity == identity else {
            PickyLog.logger(.annotationScene).debug(
                "dropping stale monitor output context=\(identity.contextID, privacy: .public) generation=\(identity.generation)"
            )
            return
        }
        interactionCoordinator.accept(
            event,
            correlation: PickyInteractionCorrelation(contextID: identity.contextID, source: .system)
        )
    }

    private func annotationPaletteKey(for request: PickyAnnotationOverlayRequest) -> String {
        "\(request.contextId ?? "none"):\(request.contextGeneration ?? -1):\(request.screenId ?? "default")"
    }

    private func overlayScreenshot(for request: PickyAnnotationOverlayRequest) -> PickyScreenshotContext? {
        guard request.contextId == latestOverlayContextID else { return nil }
        if let screenID = request.screenId, let screenshot = latestOverlayScreenshotsByID[screenID] {
            return screenshot
        }
        return latestOverlayScreenshotsByID.values.first(where: { $0.isCursorScreen == true })
            ?? latestOverlayScreenshotsByID.values.first
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

    private func updatePassiveAgentSummary(_ summary: String) {
        guard voiceState != .responding else { return }
        latestAgentSessionSummary = summary
    }

    /// If the cursor is in transient mode (user toggled "Show Picky" off),
    /// waits for any pointing animation to finish, then
    /// fades out the overlay after a 1-second pause. Cancelled automatically
    /// if the user starts another push-to-talk interaction.
    func scheduleTransientHideIfNeeded() {
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
        // Capture before this PTT press can begin a new turn. The abort command
        // must still precede that submission, but its eventual success must not
        // settle the new turn that follows this key press.
        let cancellation = makeMainTurnCancellation()
        stopCurrentSpeech()
        Task { [weak self] in
            _ = await self?.cancelMainTurn(cancellation, stopsLocalSpeech: false)
        }
        updateVoiceInputAudioSuppression(isVoiceInputActive: true)
        reduceVoiceInteraction(.abort)
    }

    /// Stops the current main turn regardless of whether it originated from
    /// voice or typed Quick Input. A Pickle follow-up needs its own session
    /// abort in addition to the main-agent abort.
    @discardableResult
    func cancelMainTurn() async -> Bool {
        await cancelMainTurn(makeMainTurnCancellation(), stopsLocalSpeech: true)
    }

    private func makeMainTurnCancellation() -> MainTurnCancellation {
        let hasPendingAgentResponse = pendingAgentResponseStartedAt != nil
        let shouldSettleLocalState = PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: hasPendingAgentResponse,
            voiceState: voiceState,
            isWaitingForCursorResponse: isWaitingForCursorResponse,
            hasLiveActivities: !mainLiveActivities.isEmpty,
            hasActiveFollowUpTurn: activeMainTurnFollowUpSessionID != nil
        )
        let shouldAbortFollowUpPickle = PickyMainCancelPillPolicy.shouldAbortFollowUpPickle(
            hasPendingAgentResponse: hasPendingAgentResponse,
            voiceState: voiceState
        )
        return MainTurnCancellation(
            shouldSettleLocalState: shouldSettleLocalState,
            followUpSessionID: PickyMainCancelPillPolicy.followUpAbortTarget(
                activeMainTurnFollowUpSessionID: activeMainTurnFollowUpSessionID,
                voiceFollowUpSessionID: voiceFollowUpSessionIDForCurrentUtterance,
                shouldAbortVoiceFollowUpPickle: shouldAbortFollowUpPickle
            ),
            generation: mainTurnGeneration
        )
    }

    private func cancelMainTurn(
        _ cancellation: MainTurnCancellation,
        stopsLocalSpeech: Bool
    ) async -> Bool {
        // Stop local narration immediately, but keep the in-flight projection
        // intact until agentd accepted the main abort. That lets the pill remain
        // usable when transport or command delivery fails.
        if stopsLocalSpeech {
            stopCurrentSpeech()
        }
        do {
            async let mainAbortRejection = agentClient.sendAwaitingError(
                PickyCommandEnvelope(type: .abortMainAgent),
                timeout: 1.0
            )
            async let followUpAbortRejection: PickyErrorEvent? = {
                guard let followUpSessionID = cancellation.followUpSessionID else { return nil }
                return try await agentClient.sendAwaitingError(
                    PickyCommandEnvelope(type: .abort, sessionId: followUpSessionID),
                    timeout: 1.0
                )
            }()
            let (mainRejection, followUpRejection) = try await (mainAbortRejection, followUpAbortRejection)
            if let mainRejection {
                print("⚠️ Failed to abort Picky main turn: \(mainRejection.message)")
                return false
            }
            if let followUpRejection {
                print("⚠️ Failed to abort Pickle session: \(followUpRejection.message)")
                return false
            }
        } catch {
            print("⚠️ Failed to abort Picky main turn: \(error)")
            return false
        }

        // A PTT or typed submission may have started another turn while the
        // daemon was processing this cancellation. Never settle or confirm a
        // cancellation result against that newer turn.
        guard mainTurnGeneration == cancellation.generation else { return false }
        if cancellation.shouldSettleLocalState {
            settleMainTurnAfterCancellation()
        }
        return true
    }

    private func settleMainTurnAfterCancellation() {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        pendingAgentResponseStartedAt = nil
        mainLiveActivities = []
        activeMainTurnFollowUpSessionID = nil
        currentVoicePromptPreview = nil
        voicePromptBubbleState = .hidden
        // This is the same abort reduction used by the voice interruption path.
        // It clears the voice projection even though agentd's abort command has
        // no matching mainTurnSettled event.
        reduceVoiceInteraction(.abort)
        // Typed Quick Input uses the interaction coordinator rather than the
        // voice machine. Reset its waiting output as well so the cursor cannot
        // remain in the processing projection after a successful abort.
        interactionCoordinator.accept(
            .mainAgentSessionReset,
            correlation: PickyInteractionCorrelation(source: .system)
        )
    }

    func beginAwaitingAgentResponse(recognizedTranscript: String? = nil) {
        mainTurnGeneration &+= 1
        activeMainTurnFollowUpSessionID = voiceFollowUpSessionIDForCurrentUtterance
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
        if activeMainTurnFollowUpSessionID == sessionID {
            activeMainTurnFollowUpSessionID = nil
        }
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

    func finishAwaitingAgentResponse(
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
        activeMainTurnFollowUpSessionID = nil
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

    private func stopCurrentSpeech() {
        logSpeech("stop current speech active=\(activeSpeechID?.uuidString ?? "none") interaction=\(interactionSpeechID?.uuidString ?? "none") providerSpeaking=\(speechPlaybackProvider.isSpeaking)")
        reduceVoiceInteraction(.reset)
        activeSpeechID = nil
        deferredInteractionSpeechTask?.cancel()
        deferredInteractionSpeechTask = nil
        responseStateTask?.cancel()
        responseStateTask = nil
        speechPlaybackProvider.stopSpeaking()
    }

    private func stopCurrentInteractionSpeech(speechID requestedSpeechID: UUID?) {
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
