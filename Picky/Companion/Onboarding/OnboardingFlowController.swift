//
//  OnboardingFlowController.swift
//  Picky
//
//  Drives the guided onboarding flow as a sequence of cursor-bubble beats.
//  Each beat owns the text shown in the Picky cursor's speech bubble plus
//  the rule that advances to the next beat — either a timed dwell so the user
//  has time to read, or an interactive gate (the user draws on screen, opens
//  the demo Pickle, or long-presses it to archive). A persistent Skip panel
//  in the top-right corner lets the user bail at any beat; ESC does the same.
//
//  No real LLM/daemon traffic flows during onboarding. The flow installs a
//  submission interceptor on CompanionManager that swallows whatever the user
//  actually submits and returns a synthetic receipt, then a scripted scenario
//  emits Pickle events into the real HUD dock via the router.
//

import AppKit
import Combine
import Foundation

@MainActor
final class OnboardingFlowController {
    /// Beats are sequential. Each one runs `enterBeat(_:)` which sets the
    /// bubble copy and schedules the next transition. The transition is either
    /// a timed dwell (`scheduleDwell(after:then:)`) or a gate that waits for a
    /// real user gesture (ink draw, dock open, dock archive). The enum has no
    /// associated values so debugging printouts and tests stay readable.
    enum Beat: Equatable {
        case preWelcome
        case introducing
        case showingCapabilities
        case openingPatchNotes
        case explainingTriggers
        case explainingDelegation
        case explainingPickle
        case inviteDrawing
        case delegatingToPickle
        case pickleRunning
        case pickleCompleted
        case awaitingPickleOpen
        case openedPickle
        case inviteClose
        case awaitingPickleClose
        case inviteArchive
        case awaitingArchive
        case outro
        case done
    }

    private let activator: PickyOnboardingActivator
    private weak var companionManager: CompanionManager?
    private weak var hudRouter: PickyAgentClientRouter?
    private weak var hudViewModel: PickySessionListViewModel?
    private let demoURL: URL?

    private(set) var beat: Beat = .preWelcome

    private var skipPanelController: OnboardingSkipPanelController?
    private var highlightViewer: OnboardingHighlightViewerPanelController?
    /// Speech surface for the onboarding bubbles. Default implementation routes
    /// through `NSSpeechSynthesizer`; tests and the future recorded-audio path
    /// inject their own player. The controller owns generation tracking and
    /// dwell gating — the player just has to start playback and report when it
    /// ends.
    private let narrationPlayer: OnboardingNarrationPlayer
    private var lastSpokenBubbleText: String?

    /// Dwell gating: each beat's advance is held until BOTH the reading timer
    /// has elapsed AND the most recent TTS utterance has finished (plus a
    /// small buffer so the bubble doesn't disappear the instant the voice
    /// stops). `speechGeneration` is incremented per setBubble that kicks off
    /// a new utterance so stale delegate callbacks from a prior beat can't
    /// satisfy the current beat's gate.
    private struct PendingDwell {
        let generation: Int
        var timerElapsed: Bool
        var speechSatisfied: Bool
        let completion: () -> Void
    }
    private var pendingDwell: PendingDwell?
    private var speechGeneration: Int = 0
    private var speechHasUnfinishedUtterance: Bool = false
    private var speechSafetyTask: Task<Void, Never>?
    private let postSpeechBufferSeconds: TimeInterval = 0.7
    /// Hard ceiling on how long we'll wait for a delegate callback before
    /// faking speechFinished. Covers the edge case where no compatible voice
    /// is installed and the synthesizer silently no-ops.
    private let speechSafetyTimeoutSeconds: TimeInterval = 30

    private var didCrossInkThresholdInSession = false
    private var capturedInkStrokes: [PickyInkOverlayStroke] = []
    private var scenarioStubClient: OnboardingAgentClient?
    private var scenarioEventTask: Task<Void, Never>?
    private var dwellTask: Task<Void, Never>?
    private var inkCancellable: AnyCancellable?
    private var openCancellable: AnyCancellable?
    private var closeCancellable: AnyCancellable?
    private var archiveCancellable: AnyCancellable?
    private var escMonitorGlobal: Any?
    private var escMonitorLocal: Any?
    /// Active hold-to-skip task. Non-nil while the user is currently pressing
    /// ESC; bumped to nil on keyUp, on a fresh keyDown, or when the hold
    /// completes and we actually skip.
    private var skipHoldTask: Task<Void, Never>?
    /// Sentinel used to ignore stale hold completions if the user lets go and
    /// re-presses ESC before the previous task finished cancelling.
    private var skipHoldGeneration: Int = 0
    /// How long ESC must be held continuously before the skip fires. Matched
    /// by the visual progress fill on every skip panel.
    private let skipHoldDuration: TimeInterval = 2.0
    private var demoSessionId: String?
    private var didInterceptSubmission = false
    private var didStartScenario = false
    private var didArchiveDemoSession = false
    private var hasOpenedDemoSession = false

    init(
        activator: PickyOnboardingActivator,
        companionManager: CompanionManager,
        hudRouter: PickyAgentClientRouter? = nil,
        hudViewModel: PickySessionListViewModel? = nil,
        demoURL: URL? = URL(string: "https://pi.dev/news/releases/0.73.1"),
        narrationPlayer: OnboardingNarrationPlayer? = nil
    ) {
        self.activator = activator
        self.companionManager = companionManager
        self.hudRouter = hudRouter
        self.hudViewModel = hudViewModel
        self.demoURL = demoURL
        // Default-construct here rather than in the parameter list because
        // SystemSpeechNarrationPlayer is @MainActor isolated and Swift
        // evaluates default expressions in the caller's context, which the
        // compiler cannot prove is on the main actor.
        self.narrationPlayer = narrationPlayer ?? SystemSpeechNarrationPlayer()
    }

    func start() {
        guard beat == .preWelcome, companionManager?.onboardingBubbleText == nil else { return }
        showCursorForOnboarding()
        // Block the real shortcut handlers for the entire flow. The narration
        // says "I'll drive" — a stray PTT or quick-input double-tap shouldn't
        // pop the real dictation pipeline or quick-input pill underneath the
        // demo. The submission interceptor is a safety net for anything that
        // slips through some other path.
        companionManager?.isShortcutHandlingSuppressed = true
        installSubmissionInterceptor()
        installEscKeyMonitor()
        presentSkipPanel()
        enter(.preWelcome)
    }

    func teardownForTesting() { teardown() }

    // MARK: - Beat orchestration

    private func enter(_ next: Beat) {
        beat = next
        switch next {
        case .preWelcome:
            speak(.preWelcome) { [weak self] in self?.enter(.introducing) }
        case .introducing:
            speak(.introducing) { [weak self] in self?.enter(.showingCapabilities) }
        case .showingCapabilities:
            speak(.showingCapabilities) { [weak self] in self?.enter(.openingPatchNotes) }
        case .openingPatchNotes:
            if let demoURL { NSWorkspace.shared.open(demoURL) }
            speak(.openingPatchNotes) { [weak self] in self?.enter(.explainingTriggers) }
        case .explainingTriggers:
            speak(.explainingTriggers) { [weak self] in self?.enter(.explainingDelegation) }
        case .explainingDelegation:
            speak(.explainingDelegation) { [weak self] in self?.enter(.explainingPickle) }
        case .explainingPickle:
            speak(.explainingPickle) { [weak self] in self?.enter(.inviteDrawing) }
        case .inviteDrawing:
            // Combined with the prior awaitingDraw beat: bubble explains the
            // gesture, ink mode is armed immediately, and we wait for the user
            // to actually draw before advancing. No separate dwell beat.
            setBubble(.inviteDrawing)
            companionManager?.beginOnboardingInkCapture()
            beginAwaitingDraw()
        case .delegatingToPickle:
            // Snapshot the strokes for the highlight viewer before we kill ink
            // mode. Cancelling brings the cursor back to normal pointer.
            capturedInkStrokes = companionManager?.inkOverlayState.strokes ?? []
            companionManager?.cancelOnboardingInkCapture()
            startScenario()
            presentHighlightViewerIfAvailable()
            speak(.delegatingToPickle) { [weak self] in self?.enter(.pickleRunning) }
        case .pickleRunning:
            setBubble(.pickleRunning)
            // Scenario events advance us to pickleCompleted once status flips to completed.
        case .pickleCompleted:
            setBubble(.pickleCompleted)
            highlightViewer?.dismiss()
            beginAwaitingPickleOpen()
        case .awaitingPickleOpen:
            setBubble(.awaitingPickleOpen)
        case .openedPickle:
            speak(.openedPickle) { [weak self] in self?.enter(.inviteClose) }
        case .inviteClose:
            setBubble(.inviteClose)
            beginAwaitingPickleClose()
        case .awaitingPickleClose:
            // Bubble copy lives on the previous beat; this is a pure gate so
            // we don't change it here.
            break
        case .inviteArchive:
            // Explain the gesture, then transition to a follow-up prompt that
            // explicitly asks the user to perform it. The archive observer is
            // armed during inviteArchive so a quick user can short-circuit
            // straight to outro without ever hitting awaitingArchive.
            beginAwaitingArchive()
            speak(.inviteArchive) { [weak self] in self?.enter(.awaitingArchive) }
        case .awaitingArchive:
            setBubble(.awaitingArchive)
        case .outro:
            speak(.outro) { [weak self] in self?.finish() }
        case .done:
            break
        }
    }

    /// Convenience for the common 'show + speak + advance after dwell' pattern.
    /// Beats with custom mid-beat work (opening a URL, snapshotting strokes,
    /// kicking off the scenario) call `setBubble` and `scheduleReadingDwell`
    /// directly so the side effects stay visible at the call site.
    private func speak(_ key: OnboardingNarrationKey, then advance: @escaping () -> Void) {
        let text = setBubble(key)
        scheduleReadingDwell(for: text, then: advance)
    }

    /// Updates the bubble copy and asks the narration player to speak the
    /// matching line. Returns the resolved bubble text so callers that need
    /// to gate on reading time (`scheduleReadingDwell`) don't have to look
    /// the L10n value up a second time.
    @discardableResult
    private func setBubble(_ key: OnboardingNarrationKey) -> String {
        let text = L10n.t(key.l10nKey)
        companionManager?.onboardingBubbleText = text

        // Speak the same line. Markdown markers (the `**bold**` we add for the
        // amber highlight) are stripped first so the synthesiser doesn't read
        // the asterisks aloud, and parenthetical hints (keyboard shortcuts like
        // `(Control+Option)` or `(⌘T)`) are removed too — those are visual
        // aids meant for the eye, not the ear. Skip if the same line is
        // already speaking — some beats re-enter (e.g. the 'Try the long-press'
        // fallback) and we don't want a stutter.
        let spoken = Self.spokenText(for: text)
        if spoken == lastSpokenBubbleText { return text }
        lastSpokenBubbleText = spoken

        narrationPlayer.stop()
        speechGeneration += 1
        speechHasUnfinishedUtterance = true
        let myGen = speechGeneration

        let started = narrationPlayer.speak(
            key: key,
            text: spoken,
            locale: LocaleManager.shared.effectiveLocale
        ) { [weak self] _ in
            self?.handleNarrationFinished(generation: myGen)
        }
        if !started {
            // No compatible voice / audio device blocked: synthesise a finish
            // immediately so the dwell gate doesn't sit waiting on a callback
            // that will never fire.
            Task { @MainActor [weak self] in
                self?.markSpeechSatisfied(generation: myGen)
            }
            return text
        }

        // Safety net: if the player never reports finish for any other reason
        // (system audio glitch, voice download stall, malformed audio asset)
        // synthesise a finish so the flow can't get stuck waiting forever.
        speechSafetyTask?.cancel()
        speechSafetyTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((self?.speechSafetyTimeoutSeconds ?? 30) * 1_000_000_000))
            guard let self else { return }
            guard self.speechGeneration == myGen, self.speechHasUnfinishedUtterance else { return }
            self.markSpeechSatisfied(generation: myGen)
        }
        return text
    }

    /// Convert a raw bubble string (with markdown and visual asides like
    /// `(Control+Option)` or `(⌘T)`) into the version we hand to the
    /// narration player. Onboarding TTS never speaks parenthetical shortcut
    /// hints aloud because the user can already see them on screen — reading
    /// 'open paren control plus option close paren' is just noise. We strip
    /// both ASCII and full-width parenthetical groups along with whatever
    /// whitespace immediately precedes them, then collapse any double spaces
    /// the removal might have left behind.
    static func spokenText(for text: String) -> String {
        var stripped = PickyBubbleMarkdown.displayString(for: text)
        let patterns = [#"\s*\([^)]*\)"#, #"\s*（[^）]*）"#]
        for pattern in patterns {
            stripped = stripped.replacingOccurrences(
                of: pattern,
                with: "",
                options: .regularExpression
            )
        }
        // Collapse stray double spaces left behind when a parenthetical sat
        // mid-sentence with whitespace on both sides.
        stripped = stripped.replacingOccurrences(
            of: #"[ \t]{2,}"#,
            with: " ",
            options: .regularExpression
        )
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Called by the narration player when an utterance ends (naturally or via
    /// `stop()`). Waits a small tail buffer before satisfying the gate so the
    /// bubble doesn't disappear the instant the voice stops, and bails out if
    /// a newer beat has already started its own utterance.
    private func handleNarrationFinished(generation: Int) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(self.postSpeechBufferSeconds * 1_000_000_000))
            guard self.speechGeneration == generation else { return }
            self.markSpeechSatisfied(generation: generation)
        }
    }

    private func scheduleDwell(seconds: Double, then advance: @escaping () -> Void) {
        // Plain dwell (no TTS gating) used by non-reading transitions. Still
        // routed through pendingDwell so a single advance path stays
        // consistent and teardown only has one thing to clear.
        let myGen = speechGeneration
        pendingDwell = PendingDwell(
            generation: myGen,
            timerElapsed: false,
            speechSatisfied: true,
            completion: advance
        )
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.markTimerElapsed(generation: myGen)
        }
    }

    /// Schedules an advance that waits for BOTH the reading-time minimum AND
    /// the TTS utterance (plus a small buffer) to finish. If no utterance was
    /// kicked off for the current beat (e.g. the same bubble text was already
    /// spoken in the prior beat and got deduplicated), the speech gate starts
    /// already satisfied and the dwell behaves like the timer-only variant.
    private func scheduleReadingDwell(for text: String, then advance: @escaping () -> Void) {
        let myGen = speechGeneration
        let speechAlreadySatisfied = !speechHasUnfinishedUtterance
        pendingDwell = PendingDwell(
            generation: myGen,
            timerElapsed: false,
            speechSatisfied: speechAlreadySatisfied,
            completion: advance
        )
        let seconds = readingDwellSeconds(for: text)
        dwellTask?.cancel()
        dwellTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            if Task.isCancelled { return }
            self?.markTimerElapsed(generation: myGen)
        }
    }

    /// Minimum on-screen time for a bubble. The actual advance is also gated
    /// on TTS finishing + a buffer (so users always hear the full line) —
    /// this is just the floor that keeps copy visible for at least a beat
    /// even when a synthesised voice is unusually fast.
    private func readingDwellSeconds(for text: String) -> Double {
        let wordCount = text
            .split(whereSeparator: { $0.isWhitespace || $0 == "—" })
            .count
        let perWordSeconds = 0.32
        let floor = 2.5
        let tailBuffer = 0.8
        return max(floor, Double(wordCount) * perWordSeconds + tailBuffer)
    }

    private func markTimerElapsed(generation: Int) {
        guard var pending = pendingDwell, pending.generation == generation else { return }
        pending.timerElapsed = true
        pendingDwell = pending
        tryAdvanceDwell()
    }

    private func markSpeechSatisfied(generation: Int) {
        speechHasUnfinishedUtterance = false
        guard var pending = pendingDwell, pending.generation == generation else { return }
        pending.speechSatisfied = true
        pendingDwell = pending
        tryAdvanceDwell()
    }

    private func tryAdvanceDwell() {
        guard let pending = pendingDwell, pending.timerElapsed, pending.speechSatisfied else { return }
        let comp = pending.completion
        pendingDwell = nil
        comp()
    }

    // MARK: - Gates

    private func beginAwaitingDraw() {
        guard let companionManager else { return }
        // Two-phase gate: track threshold-crossing in a flag so a stale
        // 'didCrossThreshold == true' state inherited from before subscription
        // can't trigger the advance, and require at least one real stroke. Once
        // we've seen real drawing, debounce 1.0s of state silence so the user
        // gets to finish their circle before we cancel ink mode and move on.
        didCrossInkThresholdInSession = false
        inkCancellable = companionManager.$inkOverlayState
            .receive(on: DispatchQueue.main)
            .handleEvents(receiveOutput: { [weak self] state in
                guard let self else { return }
                if state.didCrossThreshold && !state.strokes.isEmpty {
                    self.didCrossInkThresholdInSession = true
                }
            })
            .filter { [weak self] _ in self?.didCrossInkThresholdInSession == true }
            .debounce(for: .milliseconds(500), scheduler: DispatchQueue.main)
            .first()
            .sink { [weak self] _ in
                self?.inkCancellable = nil
                self?.enter(.delegatingToPickle)
            }
    }

    /// Captures the user's screen and renders their ink strokes on top in a
    /// floating viewer panel so they see exactly what the Pickle is reading.
    /// Bails silently if the user didn't actually draw anything.
    private func presentHighlightViewerIfAvailable() {
        guard !capturedInkStrokes.isEmpty else { return }
        let strokes = capturedInkStrokes
        // Find which display the user actually drew on by looking up the
        // screen that contains the first stroke point. The cursor may have
        // moved to a different screen by the time the async capture runs, so
        // we must match on the strokes themselves, not on `isCursorScreen`.
        let referencePoint = strokes.first?.points.first
        let drawnScreenFrame = referencePoint
            .flatMap { point in NSScreen.screens.first(where: { $0.frame.contains(point) })?.frame }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let captures = (try? await CompanionScreenCaptureUtility.captureAllScreensAsJPEG()) ?? []
            let target: CompanionScreenCapture? = {
                if let drawnFrame = drawnScreenFrame,
                   let match = captures.first(where: { abs($0.displayFrame.origin.x - drawnFrame.origin.x) < 1 && abs($0.displayFrame.origin.y - drawnFrame.origin.y) < 1 }) {
                    return match
                }
                return captures.first(where: { $0.isCursorScreen }) ?? captures.first
            }()
            guard let target else { return }
            let viewer = OnboardingHighlightViewerPanelController()
            viewer.present(
                screenshotJPEG: target.imageData,
                strokes: strokes,
                capturedDisplayFrame: target.displayFrame,
                // The viewer is also explicitly dismissed in pickleCompleted,
                // so this fallback only matters if the scenario stalls.
                // Sized large enough to outlast a slow Korean TTS read +
                // the full scenario timeline (~20s with locale-matching voice).
                dwellSeconds: 30.0
            )
            self.highlightViewer = viewer
        }
    }

    private func beginAwaitingPickleOpen() {
        guard let hudViewModel, let demoSessionId else { return }
        openCancellable = hudViewModel.$lastOpenedSessionToken
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                guard hudViewModel.lastOpenedSessionID == demoSessionId else { return }
                if self.hasOpenedDemoSession { return }
                self.hasOpenedDemoSession = true
                self.openCancellable = nil
                self.enter(.openedPickle)
            }
    }

    private func beginAwaitingPickleClose() {
        guard let hudViewModel, let demoSessionId else { return }
        closeCancellable = hudViewModel.$lastClosedSessionToken
            .receive(on: DispatchQueue.main)
            .dropFirst()
            .sink { [weak self] _ in
                guard let self else { return }
                guard hudViewModel.lastClosedSessionID == demoSessionId else { return }
                self.closeCancellable = nil
                self.enter(.inviteArchive)
            }
    }

    private func beginAwaitingArchive() {
        guard let hudViewModel, let demoSessionId else { return }
        archiveCancellable = hudViewModel.$archivedSessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] cards in
                guard let self else { return }
                if cards.contains(where: { $0.id == demoSessionId }) {
                    self.didArchiveDemoSession = true
                    self.archiveCancellable = nil
                    self.enter(.outro)
                }
            }
    }

    // MARK: - Submission interceptor + scenario playback

    private func installSubmissionInterceptor() {
        companionManager?.submissionInterceptor = { [weak self] submission in
            await MainActor.run { self?.handleInterceptedSubmission(submission) }
        }
    }

    private func handleInterceptedSubmission(_ submission: PickyAgentSubmission) -> PickyAgentSubmissionReceipt? {
        // The user may still trigger a real shortcut during the demo. We don't
        // want their submission to reach the daemon. Swallow it and return a
        // synthetic receipt pointing at the demo Pickle (if one exists yet) so
        // CompanionManager's downstream bookkeeping has something to anchor on.
        let sessionId = demoSessionId ?? "onboarding-stash-\(UUID().uuidString.prefix(6))"
        didInterceptSubmission = true
        return PickyAgentSubmissionReceipt(sessionID: sessionId, message: "Captured (onboarding demo)")
    }

    private func startScenario() {
        if didStartScenario { return }
        didStartScenario = true
        let scenario = OnboardingScenario.piReleaseSummary()
        demoSessionId = scenario.sessionId

        let stub = OnboardingAgentClient(scenarioFactory: { scenario })
        scenarioStubClient = stub
        scenarioEventTask?.cancel()
        scenarioEventTask = Task { @MainActor [weak self] in
            await stub.connect()
            for await event in stub.events {
                if Task.isCancelled { return }
                self?.forwardScenarioEvent(event)
            }
        }
        Task { @MainActor [stub] in
            _ = try? await stub.submit(
                PickyAgentSubmission(
                    transcript: scenario.sessionTitle,
                    context: Self.placeholderContextPacket(prompt: scenario.sessionTitle)
                )
            )
        }
    }

    private func forwardScenarioEvent(_ event: PickyClientEvent) {
        hudRouter?.injectScriptedEvent(event)
        guard case let .protocolEvent(envelope) = event else { return }
        if case let .sessionUpdated(session) = envelope.event, session.status == .completed {
            // Advance independent of dwell timer so the bubble doesn't sit on
            // 'pickleRunning' once the dock card is already done.
            dwellTask?.cancel()
            if beat == .pickleRunning || beat == .delegatingToPickle {
                enter(.pickleCompleted)
            }
        }
    }

    // MARK: - Exit paths

    func skip() {
        activator.markOnboardingComplete()
        teardown()
    }

    private func finish() {
        activator.markOnboardingComplete()
        teardown()
    }

    private func teardown() {
        dwellTask?.cancel()
        dwellTask = nil
        speechSafetyTask?.cancel()
        speechSafetyTask = nil
        pendingDwell = nil
        speechHasUnfinishedUtterance = false
        narrationPlayer.stop()
        lastSpokenBubbleText = nil
        scenarioEventTask?.cancel()
        scenarioEventTask = nil
        scenarioStubClient?.disconnect()
        scenarioStubClient = nil
        inkCancellable = nil
        openCancellable = nil
        closeCancellable = nil
        archiveCancellable = nil
        removeEscKeyMonitor()
        archiveDemoSessionIfStillVisible()
        companionManager?.cancelOnboardingInkCapture()
        companionManager?.submissionInterceptor = nil
        companionManager?.isShortcutHandlingSuppressed = false
        companionManager?.onboardingBubbleText = nil
        companionManager?.setOnboardingOverlayVisibility(false)
        skipPanelController?.dismiss()
        skipPanelController = nil
        highlightViewer?.dismiss()
        highlightViewer = nil
        capturedInkStrokes = []
        didCrossInkThresholdInSession = false
        beat = .done
    }

    /// Purge the scripted demo session from the HUD entirely (active list,
    /// archive, unread / done-flash flags). The session is client-side only
    /// — the daemon never saw it — so archiving via the daemon command path
    /// would fail and leaving it in the archive list is misleading because
    /// clicking would dead-end. Called from teardown so both finish() and
    /// skip() leave the dock the way they found it.
    private func archiveDemoSessionIfStillVisible() {
        if didArchiveDemoSession { return }
        didArchiveDemoSession = true
        guard let demoSessionId, let hudViewModel else { return }
        hudViewModel.removeOnboardingDemoSession(sessionID: demoSessionId)
    }

    // MARK: - Wiring helpers

    private func showCursorForOnboarding() {
        companionManager?.setOnboardingOverlayVisibility(true)
    }

    private func presentSkipPanel() {
        let controller = OnboardingSkipPanelController(onSkip: { [weak self] in
            Task { @MainActor in self?.skip() }
        })
        controller.present()
        skipPanelController = controller
    }

    private func installEscKeyMonitor() {
        // Watch BOTH keyDown and keyUp — a tap should never fire skip, only a
        // sustained hold. The global monitor covers the (common) case where
        // another app is frontmost during the demo; the local monitor covers
        // events that hit our own windows and would otherwise be consumed.
        let mask: NSEvent.EventTypeMask = [.keyDown, .keyUp]
        escMonitorGlobal = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            guard event.keyCode == 53 else { return }
            Task { @MainActor in self?.handleEscEvent(event) }
        }
        escMonitorLocal = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in self?.handleEscEvent(event) }
                return nil
            }
            return event
        }
    }

    private func removeEscKeyMonitor() {
        if let escMonitorGlobal { NSEvent.removeMonitor(escMonitorGlobal) }
        if let escMonitorLocal { NSEvent.removeMonitor(escMonitorLocal) }
        escMonitorGlobal = nil
        escMonitorLocal = nil
        cancelSkipHold()
    }

    private func handleEscEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            // Ignore autorepeat — we already started the hold task on the first
            // press and re-arming it on every repeat would just reset progress.
            if event.isARepeat { return }
            beginSkipHold()
        } else if event.type == .keyUp {
            cancelSkipHold()
        }
    }

    private func beginSkipHold() {
        skipHoldTask?.cancel()
        skipHoldGeneration &+= 1
        let myGen = skipHoldGeneration
        let duration = skipHoldDuration
        skipPanelController?.startHoldFeedback(duration: duration)
        skipHoldTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard let self else { return }
            if Task.isCancelled { return }
            // A newer press (or a release) bumped the generation — ignore.
            guard self.skipHoldGeneration == myGen else { return }
            self.skipHoldTask = nil
            self.skip()
        }
    }

    private func cancelSkipHold() {
        if skipHoldTask == nil { return }
        skipHoldTask?.cancel()
        skipHoldTask = nil
        skipHoldGeneration &+= 1
        skipPanelController?.cancelHoldFeedback()
    }

    private static func placeholderContextPacket(prompt: String) -> PickyContextPacket {
        PickyContextPacket(
            id: "ctx-onboarding-\(UUID().uuidString.prefix(6))",
            source: "onboarding-demo",
            capturedAt: Date(),
            transcript: prompt,
            selectedText: nil,
            cwd: nil,
            activeApp: nil,
            activeWindow: nil,
            browser: nil,
            screenshots: [],
            warnings: []
        )
    }
}

