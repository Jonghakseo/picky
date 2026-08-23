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

// Shared only by CompanionManager's speech-lifecycle extension; the manager remains
// the sole mutable owner of speech state.
enum PickySpeechPollResult {
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
    // Used by the main-turn lifecycle extension; state ownership remains here.
    static let recognizedTranscriptVisibleDuration: TimeInterval = 3.0
    /// Mutated only by CompanionManager and its lifecycle extensions.
    @Published var voiceState: CompanionVoiceState = .idle {
        didSet { updateMainCancelPillPresentation() }
    }
    @Published private(set) var lastTranscript: String?
    /// Mutated only by CompanionManager and its main-turn lifecycle extension.
    @Published var currentVoicePromptPreview: String?
    /// Mutated only by CompanionManager and its main-turn lifecycle extension.
    @Published var voicePromptBubbleState: CompanionVoicePromptBubbleState = .hidden {
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
    /// Mutated only by CompanionManager and its main-turn lifecycle extension.
    @Published var latestAgentSessionSummary: String?
    @Published private(set) var isProgressiveResponseVisible = false
    @Published private(set) var hasActiveVisualNarration = false
    @Published private(set) var activeVisualNarrationSegmentID: String?
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
    private var screenContextTargetLabel: String?

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
    /// Read and written by CompanionManager+AgentAnnotationOverlay.swift, which is
    /// why the overlay/annotation state below is internal rather than private.
    var latestOverlayContextID: String?
    var latestOverlayContextGeneration = 0
    /// Exact app-local screenshot samples for the latest overlay context, keyed
    /// by both screen id and screenshot id. Never serialized to agentd.
    var latestOverlayScreenshotsByID: [String: PickyScreenshotContext] = [:]
    /// App/window/URL identity captured with the exact screenshots above. The scene
    /// monitor keeps this app-local and never extends the app-agentd protocol.
    var latestAnnotationSceneBaseline: PickyAnnotationSceneBaseline?
    var activeAnnotationSceneIdentity: PickyAnnotationSceneIdentity?
    private var projectedAnnotationSceneIdentity: PickyAnnotationSceneIdentity?
    let annotationSceneMonitor: PickyAnnotationSceneMonitor?
    /// Stable base palette for each streamed context-generation/screen. Individual
    /// shapes may override it only when local contrast falls below the threshold.
    var annotationBasePaletteByTurnScreen: [String: PickyAnnotationPaletteRole] = [:]

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
    // Access is internal only for the main-turn lifecycle extension; CompanionManager
    // remains the sole owner of commands sent through this client.
    let agentClient: any PickyAgentClient
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
    private let voiceTargetResolver: any PickyVoiceTargetResolving
    private let pointerLocationProvider: @MainActor () -> CGPoint
    private let transcriptionProviderFactory: (PickySettings) -> any BuddyTranscriptionProvider
    private let speechPlaybackProviderFactory: (PickySettings) -> any PickySpeechPlaybackProvider
    private let interactionTimerScheduler: any PickyInteractionTimerScheduling
    // Mutated only by CompanionManager; read and driven by its speech-lifecycle extension.
    var speechPlaybackProvider: any PickySpeechPlaybackProvider
    private var appliedVoiceProviderSettings: PickyVoiceProviderSettings
    var ttsPlaybackEnabled: Bool
    private let speechWatchdogTimeoutOverride: TimeInterval?
    let voiceContextCaptureCoordinator: PickyVoiceContextCaptureCoordinator
    let voiceContextCapturePipeline: PickyVoiceContextCapturePipeline
    private var armedPickleDispatchMode: PickyArmedPickleDispatchMode
    /// Mirrors the persisted screen-context scope so overlay views can gate the
    /// capture-context border to the display(s) that will actually be captured.
    @Published private(set) var screenContextScope: PickyScreenContextScope
    /// Mirrors the persisted "attach screenshots only when drawn" toggle so the
    /// capture-context border tracks the per-screen ink attachment gate.
    @Published private(set) var attachScreenshotsOnlyWhenInked: Bool
    /// Per-turn display choices from the status pill; manual choices override scope and ink gating.
    @Published var screenContextDisplayOverrides: PickyScreenContextDisplayOverrides = [:]
    /// True only while an open Quick Input draft can still change its screen choices.
    @Published private(set) var isQuickInputScreenContextControlsVisible = false
    /// Physical display containing the pointer, updated only when the pointer crosses displays.
    @Published var screenContextFocusedDisplayID: CGDirectDisplayID?

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
        annotationSceneMonitor: PickyAnnotationSceneMonitor? = nil,
        voiceTargetResolver: (any PickyVoiceTargetResolving)? = nil,
        pointerLocationProvider: @escaping @MainActor () -> CGPoint = { NSEvent.mouseLocation }
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
        self.voiceTargetResolver = voiceTargetResolver ?? PickyVoiceTargetHitTestRegistry()
        self.pointerLocationProvider = pointerLocationProvider
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
        self.screenContextTargetLabel = (selectionStore as? PickyScreenContextTargetLabelStoring)?.screenContextTargetLabel
        self.inkCaptureCoordinator.onStateChange = { [weak self] state in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.inkOverlayState = state
                self.setLocalOverlayReason(.activeInkCapture, visible: state.isActive)
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
    var voiceInputTargetSnapshotsByInputID: [UUID: PickyVoiceInputTargetSnapshot] = [:]
    var screenContextDisplayOverridesByTextInputID: [UUID: PickyScreenContextDisplayOverrides] = [:]
    var screenContextDisplaySelectionSnapshotsByTextInputID: [UUID: PickyScreenContextDisplaySelectionSnapshot] = [:]
    private var failedQuickInputInkCapture: PickyInkCapture?
    var screenContextControlHitTest: (CGPoint) -> Bool = { _ in false }
    /// True when the point sits over visibly rendered HUD chrome (dock rail,
    /// conversation card, toast). Wired by the app to the HUD overlay manager.
    var hudInkPassThroughHitTest: (CGPoint) -> Bool = { _ in false }
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
    /// Cancellation rejections are delivered both to `sendAwaitingError` and
    /// the general event stream. Keep their errors from clearing a still-running
    /// turn before the cancellation attempt can restore a retryable pill.
    var pendingMainTurnCancellationCommandIDs = Set<String>()
    /// A router may resume the cancellation waiter before its broadcast event
    /// reaches this manager. Command ids are UUIDs, so retaining the completed
    /// ids prevents that later copy from being mistaken for a connection-wide
    /// failure without risking a future command collision.
    var completedMainTurnCancellationCommandIDs = Set<String>()
    /// Deferred clear for the cursor activity chips. The daemon emits a clear
    /// (`mainActivityUpdated(nil)`) at turn terminal, right before the reply. We
    /// hold the chips a short beat so they linger beside the response bubble and
    /// fade, instead of vanishing the instant the response appears. A fresh
    /// activity or a hard reset cancels it.
    private var mainActivityClearTask: Task<Void, Never>?
    private static let mainActivityLingerDelay: Duration = .seconds(2)
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
    // Lifecycle task state is mutable only through CompanionManager's extensions.
    // Internal visibility permits those coherent responsibilities to stay in named files.
    var transientHideTask: Task<Void, Never>?
    var responseStateTask: Task<Void, Never>?
    var deferredInteractionSpeechTask: Task<Void, Never>?
    var deferredFinishAwaitingAgentResponseTask: Task<Void, Never>?
    var deferredFinishAwaitingAgentResponseSessionID: String?
    /// Caps how long the recognized-transcript bubble lingers after STT.
    var voicePromptBubbleAutoHideTask: Task<Void, Never>?
    struct ArmedPickleDispatch {
        let token: UUID
        let generation: UInt64
        var contextID: String?
    }

    // Shared only with CompanionManager+MainTurnLifecycle.swift.
    struct MainTurnCancellation {
        let shouldSettleLocalState: Bool
        let followUpSessionID: String?
        let generation: UInt64
        let armedPickleDispatchToken: UUID?
    }

    /// Increments when a new main turn starts so late cancellation completions
    /// cannot reset that newer turn's local projection.
    var mainTurnGeneration: UInt64 = 0
    /// Identity of the armed Pickle dispatch currently capturing or awaiting
    /// agentd. Its token prevents stale capture completions and settled events
    /// from affecting a newer armed Pickle turn.
    var activeArmedPickleDispatch: ArmedPickleDispatch?

    var voiceInteractionState = PickyVoiceInteractionState()
    var activeSpeechID: UUID?
    private var lastQuickReplyTTSDedupKey: String?
    private var lastQuickReplyTTSDedupAt: Date?
    var interactionSpeechID: UUID?
    var interactionVoiceInputID: UUID?
    /// Tracks the physical push-to-talk hold separately from dictation state so
    /// audio stays suppressed even if recording fails before the key is released.
    var isPushToTalkShortcutHeld = false
    /// Suppresses local spoken audio while the user is starting, holding,
    /// or finalizing voice input. If a voice-owned reply arrives during the
    /// finalizing→idle transition, speech is deferred briefly rather than failed
    /// so fast agent replies are not dropped by the tail of the same utterance.
    var isVoiceInputAudioSuppressionActive = false
    var pendingAgentResponseStartedAt: Date? {
        didSet { updateMainCancelPillPresentation() }
    }
    /// Follow-up destination for the currently cancellable turn. Voice uses its
    /// utterance snapshot; Quick Input records its armed Pickle after agentd
    /// accepts the dispatch so both cancellation surfaces stop the same work.
    var activeMainTurnFollowUpSessionID: String? {
        didSet { updateMainCancelPillPresentation() }
    }
    /// Tracks the last status we saw per session so `applyAgentEvent(.sessionUpdated)`
    /// can detect the *transition* into a terminal status (cancelled/failed/completed)
    /// rather than reacting on every snapshot. Used by the HUD-abort cursor-cleanup path:
    /// when a session the cursor is waiting on becomes terminal without a `quickReply`,
    /// CompanionManager releases the cursor processing state. Idempotent against
    /// duplicate terminal updates (the second one observes status == prior == terminal
    /// and short-circuits).
    var lastObservedSessionStatuses: [String: PickySessionStatus] = [:]
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

    var localOverlayVisibilityReasons: Set<PickyOverlayReason> = []
    var interactionOverlayVisibilityReasons: Set<PickyOverlayReason> = []

    /// Whether the cursor overlay windows should exist at all. Sourced from
    /// Settings → Cursor → "Show Picky cursor" (`cursor.showPiCursor`) — the
    /// same key the rendering layer (`BlueCursorView`) reads — so the window
    /// lifecycle and rendering can never disagree. Refreshed on settings save.
    var isCursorPreferenceEnabled: Bool

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

    func shouldPassThroughInkMouseEvent(point: CGPoint, source: PickyInkCaptureSource) -> Bool {
        if screenContextControlHitTest(point) { return true }
        guard source == .text else { return false }
        if quickInputPanelManager.containsInteractiveGlobalPoint(point) { return true }
        // The HUD panel's frame reserves a transparent card-width column beside
        // the dock rail. Only visibly rendered chrome may claim the gesture; a
        // click on transparent pixels would fall through to the app underneath
        // and steal key focus mid-ink. Wired to the HUD overlay manager, which
        // tracks the SwiftUI-reported chrome frames per display.
        return hudInkPassThroughHitTest(point)
    }

    private func beginInkCapture(
        source: PickyInkCaptureSource,
        priorCapture: PickyInkCapture? = nil
    ) {
        // A fresh input is unrelated to a failed Quick Input retry. Only the
        // explicit retry path below is allowed to keep its prior user marks.
        if priorCapture == nil {
            failedQuickInputInkCapture = nil
        }
        interactionCoordinator.accept(.agentAnnotationsClearedForUserInput, correlation: PickyInteractionCorrelation(source: .text))
        if inkCaptureCoordinator.isActive {
            setLocalOverlayReason(.activeInkCapture, visible: true)
            return
        }
        if !inkCaptureCoordinator.begin(
            source: source,
            origin: NSEvent.mouseLocation,
            priorCapture: priorCapture
        ) {
            setLocalOverlayReason(.activeInkCapture, visible: false)
        }
    }

    private func cancelInkCapture() {
        failedQuickInputInkCapture = nil
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

    func syncOverlayVisibility(animatedHide: Bool = true) {
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

    var hasActiveTransientOverlayBlocker: Bool {
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

    // Internal so tests can exercise production terminal-event teardown without
    // starting microphone hardware or the global event tap.
    func bindDictationErrors() {
        dictationErrorCancellable = buddyDictationManager.sessionEventPublisher
            .sink { [weak self] event in
                self?.handleDictationSessionEvent(event)
            }
    }

    func handleDictationSessionEvent(_ event: BuddyDictationSessionEvent) {
        switch event {
        case .failed(let inputID, let message):
            guard let inputID else {
                guard interactionVoiceInputID == nil else { return }
                finishAwaitingAgentResponse(visibleText: message, spokenText: message)
                return
            }
            let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
            voiceContextCapturePipeline.cancel(inputID: inputID)
            interactionCoordinator.accept(
                .voiceStartFailed(message: message, inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )
            reduceVoiceInteraction(.sttFailed(inputID: inputID, message: message))
            guard completeVoiceInteractionIfCurrent(inputID: inputID) else { return }
            clearScreenContextTargetIfCurrent(targetSnapshot, includingSticky: true)
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "dictation-error")
            finishAwaitingAgentResponse(visibleText: message, spokenText: message)

        case .discarded(let inputID):
            guard let inputID else { return }
            voiceContextCapturePipeline.cancel(inputID: inputID)
            interactionCoordinator.accept(
                .voiceStartFailed(message: "Voice input discarded", inputID: inputID),
                correlation: PickyInteractionCorrelation(inputID: inputID, source: .voice)
            )
            reduceVoiceInteraction(.sttFailed(inputID: inputID, message: "Voice input discarded"))
            guard completeVoiceInteractionIfCurrent(inputID: inputID) else { return }
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "dictation-discarded")
            updateVoicePresentation()
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
        let isCapturing = isPushToTalkShortcutHeld || isKeyboardRecording || isMicrophoneRecording
        let isVoiceInputActive = isCapturing || isFinalizing || isPreparing
        updateVoiceInputAudioSuppression(isVoiceInputActive: isVoiceInputActive)

        // Align the voice machine with reality using semantic events only.
        // The cursor presentation itself is derived by
        // PickyCursorVoiceStatePolicy below, so a briefly stale machine can
        // no longer flicker the cursor.
        if isCapturing {
            if voiceInteractionState.phase != .pttInput, let interactionVoiceInputID {
                reduceVoiceInteraction(.pttPressed(inputID: interactionVoiceInputID, targetSessionID: voiceFollowUpSessionIDForCurrentUtterance))
            }
        } else if isFinalizing || isPreparing || pendingAgentResponseStartedAt != nil {
            if voiceInteractionState.phase == .idle {
                reduceVoiceInteraction(.loadingStarted(inputID: interactionVoiceInputID, transcript: currentVoicePromptPreview, targetSessionID: voiceFollowUpSessionIDForCurrentUtterance, now: Date(), promptBubbleVisibility: .visible))
            }
        } else if voiceInteractionState.phase != .speaking {
            reduceVoiceInteraction(.reset)
        }

        applyCursorVoicePresentation(
            isCapturingVoiceInput: isCapturing,
            isFinalizingTranscript: isFinalizing || isPreparing
        )

        // If the user pressed and released the hotkey without saying anything,
        // no response task runs — schedule the transient hide here so the overlay
        // doesn't get stuck. Only do this when no response is in flight, otherwise
        // the brief idle gap between recording and processing would prematurely hide the overlay.
        if voiceState == .idle, pendingAgentResponseStartedAt == nil {
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
    func reduceVoiceInteraction(_ event: PickyVoiceInteractionEvent) -> PickyVoiceInteractionTransition {
        let transition = PickyVoiceInteractionMachine.reduce(state: voiceInteractionState, event: event)
        voiceInteractionState = transition.state
        applyCursorVoicePresentation()
        let streamedResponseOwnsBubble = interactionCoordinator.projection.state.streamedResponseText != nil
        if !streamedResponseOwnsBubble,
           let responseText = transition.state.context.responseBubbleText,
           !responseText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Visual/system speech still relies on the voice machine's current
            // utterance. Cumulative narration is owned by the interaction projection;
            // replacing it here with one sentence causes a one-frame regression.
            latestAgentSessionSummary = responseText
        }
        return transition
    }

    /// The only writer of `voiceState` / `voicePromptBubbleState`. Reads every
    /// axis fresh and resolves them through `PickyCursorVoiceStatePolicy`, so
    /// call sites request a recomputation instead of assigning cursor state.
    /// Capture flags may be passed in when the caller holds newer values than
    /// the dictation manager's published properties (Combine sink delivery).
    func applyCursorVoicePresentation(
        isCapturingVoiceInput: Bool? = nil,
        isFinalizingTranscript: Bool? = nil
    ) {
        let machineProjection = voiceInteractionState.projection
        let isCapturing = isCapturingVoiceInput ?? (
            isPushToTalkShortcutHeld
                || buddyDictationManager.isRecordingFromKeyboardShortcut
                || buddyDictationManager.isRecordingFromMicrophoneButton
        )
        let isFinalizing = isFinalizingTranscript ?? (
            buddyDictationManager.isFinalizingTranscript || buddyDictationManager.isPreparingToRecord
        )
        voiceState = PickyCursorVoiceStatePolicy.resolve(PickyCursorVoiceStatePolicy.Inputs(
            machineState: machineProjection.voiceState,
            isCapturingVoiceInput: isCapturing,
            isFinalizingTranscript: isFinalizing,
            hasPendingAgentResponse: pendingAgentResponseStartedAt != nil,
            isCoordinatorSpeaking: interactionCoordinator.projection.isSpeaking,
            isWaitingForCursorResponse: isWaitingForCursorResponse
        ))
        voicePromptBubbleState = machineProjection.promptBubbleState
    }

    // Internal so tests can verify the production Combine bridge remains
    // synchronous without installing a global CGEvent tap.
    func bindShortcutTransitions() {
        shortcutTransitionCancellable = globalPushToTalkShortcutMonitor
            .shortcutTransitionPublisher
            .sink { [weak self] event in
                // GlobalPushToTalkShortcutMonitor publishes synchronously from
                // its main-run-loop event tap. Do not add a scheduler hop here:
                // point and live card geometry must be resolved in the same turn.
                switch event {
                case .pressed(let observation):
                    self?.handleShortcutTransition(.pressed, pressedScreenPoint: observation.screenPoint)
                case .released:
                    self?.handleShortcutTransition(.released)
                }
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
        quickInputPanelManager.onSubmit = { [weak self] text, recipient in
            self?.handleQuickInputSubmit(text: text, recipient: recipient)
        }
        quickInputPanelManager.onStartNewSession = { [weak self] in
            guard let self else { return L10n.t("error.directMessage.fallback") }
            return await self.resetMainAgentSession()
                ? nil
                : self.directMessageError ?? L10n.t("error.directMessage.fallback")
        }
        quickInputPanelManager.onVisibilityChange = { [weak self] isVisible in
            self?.isQuickInputPanelVisible = isVisible
            self?.isQuickInputScreenContextControlsVisible = isVisible
            if !isVisible {
                self?.resetScreenContextDisplayOverrides()
                self?.failedQuickInputInkCapture = nil
            }
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
        mainCancelPillPanelManager.onCancellationAttemptResolved = { [weak self] in
            self?.updateMainCancelPillPresentation()
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

    func updateMainCancelPillPresentation() {
        // Lingering chips (deferred clear scheduled after turn settle) are a
        // purely visual afterglow — they must not keep the cancel pill alive
        // for an already-finished turn.
        let hasLiveTurnActivities = mainActivityClearTask == nil && !mainLiveActivities.isEmpty
        let isMainTurnInFlight = PickyMainCancelPillPolicy.isMainTurnInFlight(
            hasPendingAgentResponse: pendingAgentResponseStartedAt != nil,
            voiceState: voiceState,
            isWaitingForCursorResponse: isWaitingForCursorResponse,
            hasLiveActivities: hasLiveTurnActivities,
            hasActiveFollowUpTurn: activeMainTurnFollowUpSessionID != nil
        )
        // Only the panels that use ESC as their own close/cancel key may
        // suppress the pill, and only while they are visibly key. Checking
        // `NSApp.keyWindow` broadly was wrong twice over: a submitted Quick
        // Input lingers hidden as key window, and AppKit can hand key status
        // to an unrelated visible Picky window (e.g. the HUD) that has no
        // claim on ESC at all.
        let escOwningPanelIsKey = quickInputPanelManager.visiblyOwnsKeyWindow
            || mainQuestionPanelManager.visiblyOwnsKeyWindow
        mainCancelPillPanelManager.update(
            isMainTurnInFlight: isMainTurnInFlight,
            isPickyPanelKeyWindow: escOwningPanelIsKey
        )
    }

    /// Defers clearing the cursor activity chips so they briefly linger beside the
    /// response bubble, then fade. Cancelled by a fresh activity or a hard reset.
    private func scheduleMainActivityClear() {
        guard !mainLiveActivities.isEmpty else { return }
        mainActivityClearTask?.cancel()
        mainActivityClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.mainActivityLingerDelay)
            guard !Task.isCancelled, let self else { return }
            // Animate the removal so the chips fade via their `.transition(.opacity)`
            // instead of cutting out. Only the presence changes here; chip layout is
            // unaffected, so this does not reintroduce the height-bounce the chips
            // otherwise guard against.
            withAnimation(.easeOut(duration: 0.25)) {
                self.mainLiveActivities = []
            }
            self.mainActivityClearTask = nil
        }
    }

    /// Clears chips now and cancels any pending deferred clear (hard reset paths:
    /// connection loss, new session).
    func clearMainActivitiesImmediately() {
        mainActivityClearTask?.cancel()
        mainActivityClearTask = nil
        mainLiveActivities = []
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
                let label = notification.userInfo?[PickyScreenContextTargetNotification.labelKey] as? String
                self?.applyScreenContextTarget(sessionID, label: label)
            }
    }

    private func applyScreenContextTarget(_ sessionID: String?, label: String? = nil) {
        let normalized = normalizedVoiceFollowUpSessionID(sessionID)
        let targetChanged = screenContextTargetSessionID != normalized
        screenContextTargetSessionID = normalized
        screenContextTargetLabel = normalized == nil
            ? nil
            : label ?? (targetChanged ? nil : screenContextTargetLabel)
        setLocalOverlayReason(.screenContextTarget, visible: normalized != nil)
    }

    private func quickInputRecipientProjection() -> QuickInputRecipientProjection {
        guard let sessionID = normalizedVoiceFollowUpSessionID(selectionStore.screenContextTargetSessionID) else {
            return .main
        }
        let label = screenContextTargetLabel?.trimmingCharacters(in: .whitespacesAndNewlines)
        return .pickle(sessionID: sessionID, label: label?.isEmpty == false ? label! : "Pickle")
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
            resetScreenContextDisplayOverrides()
            beginInkCapture(source: .text)
        }
        // Push the current transcript before creating/showing the hosting view
        // so the first Quick Input frame is already anchored at the last turn.
        quickInputPanelManager.updateRecentMessages(mainAgentMessages)
        quickInputPanelManager.presentPanel(
            near: event.mouseLocation,
            recipient: quickInputRecipientProjection()
        )
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

    private func handleQuickInputSubmit(
        text: String,
        recipient: QuickInputRecipientProjection
    ) {
        let displayOverrides = screenContextDisplayOverrides
        let inkCapture = finishInkCaptureForDeferredTextSubmission()
        let displaySelectionSnapshot = captureScreenContextDisplaySelectionSnapshot(
            inkCapture: inkCapture,
            displayOverrides: displayOverrides
        )
        // The context packet uses the snapshot above. Do not leave controls live
        // while the Quick Input submission is in flight, or the status UI could
        // imply a later choice changes an already-captured payload.
        isQuickInputScreenContextControlsVisible = false
        Task { @MainActor [weak self] in
            guard let self else { return }
            let success = await self.sendDirectMessage(
                text,
                source: .quickInput,
                inkCapture: inkCapture,
                displayOverrides: displayOverrides,
                displaySelectionSnapshot: displaySelectionSnapshot,
                quickInputRecipient: recipient
            )

            // The panel hides optimistically while the send is in flight. Do
            // not discard this local capture until the result is known: on a
            // failure the same marks must remain visible and accept additions.
            guard self.quickInputPanelManager.isSending else {
                // Stop/dismiss/cancellation won the race with this send.
                self.failedQuickInputInkCapture = nil
                return
            }
            self.failedQuickInputInkCapture = success ? nil : inkCapture
            self.quickInputPanelManager.panelDidFinishSending(
                success: success,
                errorMessage: success ? nil : self.directMessageError
            )
            if !success, let retainedCapture = self.failedQuickInputInkCapture {
                self.beginInkCapture(source: .text, priorCapture: retainedCapture)
            }
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
            handleShortcutTransition(.pressed, pressedScreenPoint: pointerLocationProvider())
        case .release:
            guard isPushToTalkShortcutHeld else { return }
            handleShortcutTransition(.released)
        }
    }

    // Internal so PickyCompanionManagerTests can exercise the production PTT
    // transition through context capture and coordinator effect dispatch.
    func handleShortcutTransition(
        _ transition: BuddyPushToTalkShortcut.ShortcutTransition,
        pressedScreenPoint: CGPoint? = nil
    ) {
        // Defensive: even though GlobalPushToTalkShortcutMonitor short-circuits
        // its callback while paused, swallowing transitions here too keeps any
        // already-queued event from slipping through and dismissing the panel.
        if activeShortcutCaptureCount > 0 { return }
        if isShortcutHandlingSuppressed { return }
        switch transition {
        case .pressed:
            isPushToTalkShortcutHeld = true
            guard !buddyDictationManager.isDictationInProgress,
                  !quickInputPanelManager.isSending else { return }
            // A draft and a voice turn must not share one display-choice map.
            // Dismissing an open draft makes PTT the sole owner of the controls.
            quickInputPanelManager.dismiss()
            resetScreenContextDisplayOverrides()
            voiceContextCapturePipeline.beginInput()
            interruptSpokenResponseForVoiceInput()
            pendingAgentResponseStartedAt = nil
            currentVoicePromptPreview = nil
            let armedTarget = normalizedVoiceFollowUpSessionID(selectionStore.screenContextTargetSessionID).map {
                PickyScreenContextTargetSnapshot(
                    sessionID: $0,
                    sticky: selectionStore.screenContextTargetSticky,
                    revision: selectionStore.screenContextTargetRevision
                )
            }
            let pressPoint = pressedScreenPoint ?? pointerLocationProvider()
            let pointerTargetSessionID = voiceTargetResolver.sessionID(at: pressPoint)
            let inputID = UUID()
            let targetSnapshot = PickyVoiceInputTargetPolicy.resolve(
                inputID: inputID,
                armedTarget: armedTarget,
                pointerSessionID: pointerTargetSessionID,
                armedDispatchMode: armedPickleDispatchMode
            )
            // Keep older snapshots until their own effect reaches a terminal
            // path. A queued effect may still need its captured steer/follow-up
            // semantics after this newer press becomes current.
            voiceInputTargetSnapshotsByInputID[inputID] = targetSnapshot
            let targetSessionID = targetSnapshot.sessionID
            interactionVoiceInputID = inputID
            reduceVoiceInteraction(.pttPressed(inputID: inputID, targetSessionID: targetSessionID))
            beginInkCapture(source: .voice)
            print("🎙️ Picky voice route — PTT pressed; screenContext=\(selectionStore.screenContextTargetSessionID ?? "<nil>") pointerTarget=\(pointerTargetSessionID ?? "<nil>") point=(\(Int(pressPoint.x)),\(Int(pressPoint.y))) prevTask=\(currentResponseTask != nil)")
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
                    inputID: inputID,
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
                let displayOverrides = screenContextDisplayOverrides
                finishInkCapture(inputID: interactionVoiceInputID)
                let inkCapture = pendingInkCaptures.consume(for: interactionVoiceInputID)
                let displaySelectionSnapshot = captureScreenContextDisplaySelectionSnapshot(
                    inkCapture: inkCapture,
                    displayOverrides: displayOverrides
                )
                let unusedInkCapture = voiceContextCapturePipeline.finishInput(
                    inputID: interactionVoiceInputID,
                    voiceFollowUpSessionID: voiceFollowUpSessionIDForCurrentUtterance,
                    inkCapture: inkCapture,
                    displayOverrides: displayOverrides,
                    displaySelectionSnapshot: displaySelectionSnapshot
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
            resetScreenContextDisplayOverrides()
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
            voiceInputTargetSnapshotsByInputID[inputID] = PickyVoiceInputTargetPolicy.resolve(
                inputID: inputID,
                armedTarget: nil,
                pointerSessionID: voiceFollowUpSessionID,
                armedDispatchMode: armedPickleDispatchMode
            )
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

    private func prepareArmedPickleVisualDslContext(
        _ context: PickyContextPacket,
        sessionID: String,
        isArmedTargetSnapshot: Bool = false
    ) -> Bool {
        guard (isArmedTargetSnapshot || selectionStore.screenContextTargetSessionID == sessionID),
              !context.screenshots.isEmpty else { return false }
        interactionCoordinator.accept(
            .agentAnnotationsClearedForUserInput,
            correlation: PickyInteractionCorrelation(contextID: context.id, sessionID: sessionID, source: .agent)
        )
        noteMainOverlayContext(context)
        return true
    }

    private func pickleFollowUpContext(
        _ context: PickyContextPacket,
        sessionID: String,
        preservesScreenContext: Bool = false,
        usesCurrentScreenContextTarget: Bool = true
    ) -> PickyContextPacket {
        let isScreenContextTargeted = preservesScreenContext
            || (usesCurrentScreenContextTarget && selectionStore.screenContextTargetSessionID == sessionID)
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
        // Normal completion never clears a sticky target. Hard failures use
        // the revision-aware snapshot overload with `includingSticky: true`.
        if selectionStore.screenContextTargetSticky { return }
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        applyScreenContextTarget(nil)
    }

    func clearScreenContextTargetIfCurrent(
        _ snapshot: PickyVoiceInputTargetSnapshot?,
        includingSticky: Bool = false
    ) {
        guard case .pickle(let sessionID, .armed(_, let sticky, let revision)) = snapshot?.target,
              (!sticky || includingSticky),
              selectionStore.screenContextTargetSessionID == sessionID,
              selectionStore.screenContextTargetRevision == revision
        else { return }
        selectionStore.setScreenContextTarget(sessionID: nil, sticky: false)
        applyScreenContextTarget(nil)
    }

    private func sendPickleMessageFromInput(
        targetSessionID: String,
        text: String,
        source: String,
        inkCapture: PickyInkCapture?,
        displayOverrides: PickyScreenContextDisplayOverrides,
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot?,
        dispatchMode: PickyArmedPickleDispatchMode
    ) async -> Bool {
        let dispatch = ArmedPickleDispatch(
            token: UUID(),
            generation: mainTurnGeneration,
            contextID: nil
        )
        activeArmedPickleDispatch = dispatch
        activeMainTurnFollowUpSessionID = targetSessionID
        do {
            guard let captureResult = try await voiceContextCaptureCoordinator.captureContext(
                transcript: text,
                source: source,
                inkCapture: inkCapture,
                displayOverrides: displayOverrides,
                displaySelectionSnapshot: displaySelectionSnapshot
            ) else {
                guard isCurrentArmedPickleDispatch(dispatch) else { return false }
                directMessageError = L10n.t("error.directMessage.contextEmpty")
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                finishArmedPickleDispatch(dispatch)
                return false
            }
            guard isCurrentArmedPickleDispatch(dispatch) else { return false }
            activeArmedPickleDispatch?.contextID = captureResult.contextPacket.id

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
                context = pickleFollowUpContext(
                    captureResult.contextPacket,
                    sessionID: targetSessionID,
                    preservesScreenContext: true
                )
            }
            let visualDslEnabled = prepareArmedPickleVisualDslContext(
                context,
                sessionID: targetSessionID,
                isArmedTargetSnapshot: true
            )
            guard isCurrentArmedPickleDispatch(dispatch) else { return false }
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
            guard isCurrentArmedPickleDispatch(dispatch) else { return false }
            if let rejection {
                directMessageError = L10n.t("error.directMessage.sendFailed", rejection.message)
                latestAgentSessionSummary = directMessageError
                clearScreenContextTargetIfCurrent(targetSessionID)
                finishArmedPickleDispatch(dispatch)
                return false
            }
            latestAgentSessionSummary = dispatchMode == .steer
                ? L10n.t("directMessage.steerDelivered")
                : L10n.t("directMessage.followUpDelivered")
            clearScreenContextTargetIfCurrent(targetSessionID)
            return true
        } catch {
            guard isCurrentArmedPickleDispatch(dispatch) else { return false }
            let message = error.localizedDescription
            directMessageError = L10n.t("error.directMessage.sendFailed", message)
            latestAgentSessionSummary = directMessageError
            clearScreenContextTargetIfCurrent(targetSessionID)
            finishArmedPickleDispatch(dispatch)
            return false
        }
    }

    @discardableResult
    func sendDirectMessage(
        _ text: String,
        source: PickyInteractionSource = .text,
        inkCapture: PickyInkCapture? = nil,
        displayOverrides: PickyScreenContextDisplayOverrides = [:],
        displaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot? = nil,
        quickInputRecipient: QuickInputRecipientProjection? = nil
    ) async -> Bool {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return false }

        // Text submissions can route either to the main agent or an armed
        // Pickle. Advance before context capture so no-screenshot armed paths
        // also invalidate a late cancellation from the previous turn.
        beginMainTurnGeneration()
        directMessageError = nil

        let effectiveDisplaySelectionSnapshot: PickyScreenContextDisplaySelectionSnapshot?
        if source == .quickInput {
            effectiveDisplaySelectionSnapshot = displaySelectionSnapshot
                ?? captureScreenContextDisplaySelectionSnapshot(
                    inkCapture: inkCapture,
                    displayOverrides: displayOverrides
                )
        } else {
            effectiveDisplaySelectionSnapshot = displaySelectionSnapshot
        }
        let recipient = quickInputRecipient ?? quickInputRecipientProjection()
        if source == .quickInput,
           case let .pickle(targetSessionID, _) = recipient {
            return await sendPickleMessageFromInput(
                targetSessionID: targetSessionID,
                text: trimmedText,
                source: "text-follow-up",
                inkCapture: inkCapture,
                displayOverrides: displayOverrides,
                displaySelectionSnapshot: effectiveDisplaySelectionSnapshot,
                dispatchMode: armedPickleDispatchMode
            )
        }

        activeMainTurnFollowUpSessionID = nil
        let inputID = UUID()
        if source == .quickInput {
            screenContextDisplayOverridesByTextInputID[inputID] = displayOverrides
            if let effectiveDisplaySelectionSnapshot {
                screenContextDisplaySelectionSnapshotsByTextInputID[inputID] = effectiveDisplaySelectionSnapshot
            }
        }
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
        activeVisualNarrationSegmentID = projection.state.activeVisualNarrationIdentity?.segmentId
        hasActivePointVisualNarration = projection.hasActivePointVisualNarration
        isProgressiveResponseVisible = projection.latestDisplayText != nil
            && (hasActiveVisualNarration || projection.state.streamedResponseText != nil)
        if isProgressiveResponseVisible, let latestDisplayText = projection.latestDisplayText {
            latestAgentSessionSummary = latestDisplayText
            if voicePromptBubbleState != .hidden {
                // Route the hide through the machine so the single-writer
                // presentation cannot resurrect the bubble on the next pass.
                reduceVoiceInteraction(.promptBubbleAutoHide)
            }
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
            if voicePromptBubbleState != .hidden {
                reduceVoiceInteraction(.promptBubbleAutoHide)
            }
        case .idle:
            break
        case .suppressedReply:
            clearPendingAgentResponseTiming()
        case .waitingForAgent:
            break
        }

        // Safety net: if the canonical projection is no longer speaking but the
        // voice machine still thinks the tracked interaction utterance plays,
        // interrupt that utterance so the cursor cannot stay `.responding`
        // forever. `.speechInterrupted` is speechID-guarded, so an unrelated
        // `speakSystemMessage` utterance is never clipped by this pass.
        if !projection.isSpeaking, let staleSpeechID = interactionSpeechID {
            if voiceInteractionState.phase == .speaking {
                reduceVoiceInteraction(.speechInterrupted(speechID: staleSpeechID))
            }
            interactionSpeechID = nil
            scheduleTransientHideIfNeeded()
        }
        applyCursorVoicePresentation()
    }

    private func clearPendingAgentResponseTiming() {
        deferredFinishAwaitingAgentResponseTask?.cancel()
        deferredFinishAwaitingAgentResponseTask = nil
        deferredFinishAwaitingAgentResponseSessionID = nil
        pendingAgentResponseStartedAt = nil
        activeMainTurnFollowUpSessionID = nil
    }

    func speechWatchdogTimeout(for utterance: String) -> TimeInterval {
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

    func logSpeech(_ message: String) {
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

    func interactionOwner(for contextID: String) -> PickyContextOwner? {
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

    func failDirectMessage(inputID: UUID, message: String) {
        directMessageError = L10n.t("error.directMessage.deliverFailed", message)
        latestAgentSessionSummary = directMessageError
        completeDirectMessage(inputID: inputID, success: false)
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
                guard !Task.isCancelled else {
                    voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
                    return
                }
                PickyAnalytics.trackUserMessageSent(transcript: transcript)
                interactionCoordinator.effectCompleted(
                    .agentSubmissionAccepted(contextID: context.id, sessionID: receipt.sessionID, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: receipt.sessionID, source: .agent)
                )
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice", contextID: context.id)
                finishVoiceSubmissionIfIdle(inputID: inputID)
            } catch is CancellationError {
                voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
                // User spoke again — response was interrupted.
            } catch {
                handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
            }
        }
    }

    private func runFollowUpPickleEffect(inputID: UUID, sessionID: String, transcript: String, context: PickyContextPacket) {
        currentResponseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
            if case .pickle(let snapshotSessionID, .armed(let dispatchMode, _, _)) = targetSnapshot?.target,
               snapshotSessionID == sessionID {
                let command: PickyCommandEnvelope
                let source: String
                switch dispatchMode {
                case .steer:
                    let visualDslEnabled = prepareArmedPickleVisualDslContext(
                        context,
                        sessionID: sessionID,
                        isArmedTargetSnapshot: true
                    )
                    command = PickyCommandEnvelope(
                        type: .steer,
                        context: context,
                        sessionId: sessionID,
                        text: transcript,
                        visualDslEnabled: visualDslEnabled
                    )
                    source = "voice-steer"
                case .followUp:
                    let followUpContext = pickleFollowUpContext(
                        context,
                        sessionID: sessionID,
                        preservesScreenContext: true,
                        usesCurrentScreenContextTarget: false
                    )
                    let visualDslEnabled = prepareArmedPickleVisualDslContext(
                        followUpContext,
                        sessionID: sessionID,
                        isArmedTargetSnapshot: true
                    )
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
                    guard !Task.isCancelled else {
                        voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
                        return
                    }
                    let receipt = PickyAgentSubmissionReceipt(sessionID: sessionID, message: "")
                    interactionCoordinator.effectCompleted(
                        .agentSubmissionAccepted(contextID: context.id, sessionID: sessionID, inputID: inputID),
                        correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: sessionID, source: .agent)
                    )
                    handleAgentSubmissionAccepted(receipt: receipt, source: source, contextID: context.id)
                    finishVoiceSubmissionIfIdle(inputID: inputID)
                } catch is CancellationError {
                    voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
                    // User spoke again — response was interrupted.
                } catch {
                    handleVoiceSubmissionFailure(error, inputID: inputID, contextID: context.id)
                }
                return
            }

            do {
                let followUpContext = self.pickleFollowUpContext(
                    context,
                    sessionID: sessionID,
                    usesCurrentScreenContextTarget: false
                )
                try await agentClient.send(PickyCommandEnvelope(type: .followUp, context: followUpContext, sessionId: sessionID, text: transcript))
                guard !Task.isCancelled else {
                    voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
                    return
                }
                let receipt = PickyAgentSubmissionReceipt(sessionID: sessionID, message: "")
                interactionCoordinator.effectCompleted(
                    .agentSubmissionAccepted(contextID: context.id, sessionID: sessionID, inputID: inputID),
                    correlation: PickyInteractionCorrelation(inputID: inputID, contextID: context.id, sessionID: sessionID, source: .agent)
                )
                handleAgentSubmissionAccepted(receipt: receipt, source: "voice-follow-up", contextID: context.id)
                finishVoiceSubmissionIfIdle(inputID: inputID)
            } catch is CancellationError {
                voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
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
        let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
        if completeVoiceInteractionIfCurrent(inputID: inputID) {
            finishAwaitingAgentResponse(visibleText: "I captured that, but the local agent client is not ready yet.", spokenText: "I captured that, but the local agent client is not ready yet.")
            clearScreenContextTargetIfCurrent(targetSnapshot)
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "voice-submission-failure")
        }
    }

    private func finishVoiceSubmissionIfIdle(inputID: UUID) {
        let targetSnapshot = voiceInputTargetSnapshotsByInputID[inputID]
        let completedCurrentInput = completeVoiceInteractionIfCurrent(inputID: inputID)
        print("🎙️ Picky voice route — responseTask end; cancelled=\(Task.isCancelled) selfBeforeReset=\(voiceFollowUpSessionIDForCurrentUtterance ?? "<nil>")")
        if completedCurrentInput {
            clearScreenContextTargetIfCurrent(targetSnapshot)
            setVoiceFollowUpSessionIDForCurrentUtterance(nil, caller: "responseTask-end")
        }
        if !Task.isCancelled, pendingAgentResponseStartedAt == nil {
            if voiceInteractionState.phase == .loading {
                reduceVoiceInteraction(.reset)
            } else {
                applyCursorVoicePresentation()
            }
            if voiceState == .idle {
                scheduleTransientHideIfNeeded()
            }
        }
    }

    @discardableResult
    func completeVoiceInteractionIfCurrent(inputID: UUID) -> Bool {
        voiceInputTargetSnapshotsByInputID.removeValue(forKey: inputID)
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

    @discardableResult
    /// Clear resident overlay, progressive, and visual-narration state when the daemon
    /// connection drops or reports a terminal protocol error mid-response. Reuses the
    /// local session-reset cleanup (annotations, progressive narration, active visual
    /// turn, queued speech, speaking output) but does NOT clear persisted messages or
    /// send a daemon command, so a later reconnect keeps the transcript intact.
    private func clearInteractionStateForConnectionLoss() {
        clearMainActivitiesImmediately()
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
            quickInputPanelManager.updateRecentMessages(mainAgentMessages)
            clearMainActivitiesImmediately()
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
        beginMainTurnGeneration()
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
                    await MainActor.run { self.handleAgentClientDisconnected() }
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

    /// Preserves the retryable cancellation projection while a cancellation
    /// command is awaiting its transport result. Once it resolves, its defer
    /// re-runs the current pill presentation and ordinary disconnect cleanup
    /// resumes for subsequent lifecycle events.
    func handleAgentClientDisconnected() {
        guard pendingMainTurnCancellationCommandIDs.isEmpty else { return }
        finishAwaitingAgentResponse(visibleText: "picky-agentd disconnected", spokenText: nil)
        clearInteractionStateForConnectionLoss()
    }

    func applyAgentEvent(_ event: PickyEvent) {
        switch event {
        case .sessionUpdated(let session), .sessionMetaUpdated(let session):
            handleSessionStatusTransition(session: session)
            updatePassiveAgentSummary(session.lastSummary ?? "\(session.title) · \(session.status.rawValue)")
        case .sessionResourcesReloaded, .sessionLogAppended, .toolActivityUpdated, .sessionTodoStateUpdated, .sessionSubagentRunsUpdated, .sessionArchivedAuthoritative, .pluginsReloaded,
             .packageUpdatesAvailable, .packageOperationProgress, .packageOperationCompleted:
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
            scheduleMainActivityClear()
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
            quickInputPanelManager.updateRecentMessages(mainAgentMessages)
            // Snapshot fires on session load/reset for the whole transcript,
            // so do not auto-dispatch deep links here — we would re-open
            // panels for stale replies the user already saw.
        case .mainMessageAppended(let message):
            mainAgentMessages = Array((mainAgentMessages + [message]).suffix(100))
            quickInputPanelManager.updateRecentMessages(mainAgentMessages)
            autoDispatchPickyDeepLinkIfPresent(in: message)
        case .mainActivityUpdated(let activity):
            guard let activity else {
                scheduleMainActivityClear()
                break
            }
            mainActivityClearTask?.cancel()
            mainActivityClearTask = nil
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
               pendingMainQuestionAnswerCommandIDs.contains(commandID)
                || pendingMainTurnCancellationCommandIDs.contains(commandID)
                || completedMainTurnCancellationCommandIDs.contains(commandID) {
                break
            }
            finishAwaitingAgentResponse(visibleText: error.message, spokenText: nil)
            clearInteractionStateForConnectionLoss()
        case .hello, .sessionSnapshot, .artifactUpdated, .slashCommandsSnapshot,
             .piOAuthStatus, .piOAuthUrlRequested, .piOAuthPromptRequested, .piAuthenticationReloaded,
             .autocompleteCapabilitiesSnapshot, .autocompleteSuggestionsSnapshot, .autocompleteCompletionApplied,
             .rewindTargetsSnapshot, .sessionDiffResult, .sessionRewound, .ack, .unknown,
             .sessionMessageAppended, .sessionMessagesImported, .sessionMessageReplaced, .sessionMessageRemoved, .sessionQueueUpdated, .sessionActivityUpdated, .terminalSessionSyncOutcome,
             .pickleHandoffRequested, .pickleBridgeRequested, .externalEntryRequested, .dockGroupsRequested, .pushToTalkControlRequested, .pickySettingsRequested:
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
        let doesSettleOwnArmedPickleDispatch = activeArmedPickleDispatch?.contextID == contextID
        if activeArmedPickleDispatch == nil || doesSettleOwnArmedPickleDispatch {
            activeMainTurnFollowUpSessionID = nil
            if doesSettleOwnArmedPickleDispatch {
                activeArmedPickleDispatch = nil
            }
        }
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
        if voiceInteractionState.phase == .loading {
            reduceVoiceInteraction(.reset)
        } else {
            applyCursorVoicePresentation()
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

    func beginMainTurnGeneration() {
        mainTurnGeneration &+= 1
        activeArmedPickleDispatch = nil
    }

    private func isCurrentArmedPickleDispatch(_ dispatch: ArmedPickleDispatch) -> Bool {
        activeArmedPickleDispatch?.token == dispatch.token
            && mainTurnGeneration == dispatch.generation
    }

    private func finishArmedPickleDispatch(_ dispatch: ArmedPickleDispatch) {
        guard isCurrentArmedPickleDispatch(dispatch) else { return }
        activeArmedPickleDispatch = nil
        activeMainTurnFollowUpSessionID = nil
    }

    private func updatePassiveAgentSummary(_ summary: String) {
        guard voiceState != .responding else { return }
        latestAgentSessionSummary = summary
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
