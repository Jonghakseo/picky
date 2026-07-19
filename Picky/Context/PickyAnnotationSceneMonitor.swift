import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import OSLog
import ScreenCaptureKit

struct PickyAnnotationSceneWindowSignature: Equatable, Sendable {
    let ownerPID: pid_t
    let windowID: CGWindowID
    let frame: CGRect
}

struct PickyAnnotationSceneBaseline: Equatable, Sendable {
    let contextID: String
    let applicationPID: pid_t?
    let applicationBundleID: String?
    let window: PickyAnnotationSceneWindowSignature?

    @MainActor
    static func capture(from context: PickyContextPacket) -> Self {
        let pid = context.activeApp?.pid.map(pid_t.init)
        return Self(
            contextID: context.id,
            applicationPID: pid,
            applicationBundleID: context.activeApp?.bundleId,
            window: pid.flatMap(PickyAnnotationSceneSemanticProvider.currentWindowSignature(for:))
        )
    }
}

enum PickyAnnotationSceneMonitorOutput: Equatable, Sendable {
    case matched(PickyAnnotationSceneIdentity)
    case mismatched(PickyAnnotationSceneIdentity, PickyAnnotationSceneMismatchReason)
}

@MainActor
protocol PickyAnnotationSceneSnapshotCapturing: AnyObject {
    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint
    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint
    func reset()
}

@MainActor
final class PickyAnnotationSceneMonitor {
    typealias OutputHandler = @MainActor (PickyAnnotationSceneMonitorOutput) -> Void

    /// Do not leave visual narration hidden while an ambiguous initial fingerprint
    /// comparison retries indefinitely. The fail-safe outcome remains suspension.
    static let initialValidationTimeout: TimeInterval = 2

    private final class Target {
        let screenshot: PickyScreenshotContext
        var baselineFingerprint: PickyAnnotationSceneFingerprint?
        var normalizedRegionsByAnnotationID: [String: CGRect]

        var normalizedRegions: [CGRect] {
            normalizedRegionsByAnnotationID.keys.sorted().compactMap { normalizedRegionsByAnnotationID[$0] }
        }

        init(screenshot: PickyScreenshotContext, normalizedRegionsByAnnotationID: [String: CGRect]) {
            self.screenshot = screenshot
            self.normalizedRegionsByAnnotationID = normalizedRegionsByAnnotationID
        }
    }

    private struct VisualSample {
        let observation: PickyAnnotationSceneVisualObservation
        let captureMilliseconds: Double
        let comparisonMilliseconds: Double
    }

    private final class AccessibilityObserverContext {
        weak var monitor: PickyAnnotationSceneMonitor?
        let identity: PickyAnnotationSceneIdentity

        init(monitor: PickyAnnotationSceneMonitor, identity: PickyAnnotationSceneIdentity) {
            self.monitor = monitor
            self.identity = identity
        }
    }

    private final class Session {
        let identity: PickyAnnotationSceneIdentity
        let baseline: PickyAnnotationSceneBaseline
        let startedAt: Date
        let initialValidationDeadline: Date
        var phase: PickyAnnotationScenePhase = .validating
        var targets: [String: Target] = [:]
        var stability = PickyAnnotationSceneStabilityTracker()
        var retry = 0
        var sampleCount = 0
        var captureEpoch = 0
        var confirmationNotBefore: Date?
        var semanticBlock: PickyAnnotationSceneMismatchReason?
        var lastMismatchReason: PickyAnnotationSceneMismatchReason?
        var allowsTolerantRestoration: Bool

        init(
            identity: PickyAnnotationSceneIdentity,
            baseline: PickyAnnotationSceneBaseline,
            now: Date,
            allowsTolerantRestoration: Bool
        ) {
            self.identity = identity
            self.baseline = baseline
            self.startedAt = now
            self.initialValidationDeadline = now.addingTimeInterval(PickyAnnotationSceneMonitor.initialValidationTimeout)
            self.allowsTolerantRestoration = allowsTolerantRestoration
        }
    }

    var onOutput: OutputHandler?
    var onSampleScheduled: (@MainActor (TimeInterval) -> Void)?

    private let capturer: any PickyAnnotationSceneSnapshotCapturing
    private let now: () -> Date
    private let automaticallySchedulesSamples: Bool
    private var session: Session?
    private var pollingTask: Task<Void, Never>?
    private var samplingIdentity: PickyAnnotationSceneIdentity?
    private var capturerResetPending = false
    private var needsImmediateSample = false
    private var workspaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var accessibilityObserver: AXObserver?
    private var accessibilityObserverContext: AccessibilityObserverContext?
    private var accessibilityObservedApplication: AXUIElement?
    private var accessibilityObservedWindow: AXUIElement?

    init(
        capturer: (any PickyAnnotationSceneSnapshotCapturing)? = nil,
        now: @escaping () -> Date = Date.init,
        automaticallySchedulesSamples: Bool = true
    ) {
        self.capturer = capturer ?? PickyScreenCaptureAnnotationSceneCapturer()
        self.now = now
        self.automaticallySchedulesSamples = automaticallySchedulesSamples
    }

    func start(
        identity: PickyAnnotationSceneIdentity,
        baseline: PickyAnnotationSceneBaseline,
        allowsTolerantRestoration: Bool = false
    ) {
        stop(logReason: nil)
        session = Session(
            identity: identity,
            baseline: baseline,
            now: now(),
            allowsTolerantRestoration: allowsTolerantRestoration
        )
        if automaticallySchedulesSamples {
            installEventObservers(for: baseline, identity: identity)
        }
        PickyLog.notice(
            .annotationScene,
            prefix: "🖍️",
            message: "annotation scene monitor started context=\(baseline.contextID) generation=\(identity.generation)"
        )
        requestSample(after: 0)
    }

    func updateTarget(
        screenshot: PickyScreenshotContext,
        annotations: [PickyAgentAnnotation],
        mode: PickyAnnotationOverlayMode
    ) {
        guard let session else { return }
        if mode == .replace { session.targets = [:] }
        let key = screenshot.screenId ?? screenshot.id
        let regions = Self.normalizedRegions(for: annotations, screenshot: screenshot)
        if let target = session.targets[key] {
            target.normalizedRegionsByAnnotationID.merge(regions) { _, replacement in replacement }
        } else {
            session.targets[key] = Target(screenshot: screenshot, normalizedRegionsByAnnotationID: regions)
        }
        requestSample(after: 0)
    }

    func stop() {
        stop(logReason: "stopped")
    }

    func setAllowsTolerantRestoration(_ allowsTolerantRestoration: Bool) {
        guard let session,
              session.allowsTolerantRestoration != allowsTolerantRestoration else { return }
        session.allowsTolerantRestoration = allowsTolerantRestoration
        if session.phase == .suspended {
            session.stability.reset()
            session.confirmationNotBefore = nil
            if allowsTolerantRestoration {
                requestSample(after: 0)
            }
        }
    }

    /// Test hook and event-driven fast path. Production polling still goes through
    /// the same method, so token checks and metrics cannot diverge.
    func sampleNow() async {
        guard let session else { return }
        await performSample(identity: session.identity)
    }

    func suspendImmediately(reason: PickyAnnotationSceneMismatchReason) {
        guard let session else { return }
        if reason == .display {
            session.captureEpoch &+= 1
            for target in session.targets.values {
                target.baselineFingerprint = nil
            }
            resetCapturerWhenIdle()
        }
        transitionToSuspended(session, reason: reason)
        if reason == .application || reason == .window {
            session.semanticBlock = reason
        }
        requestSample(after: PickyAnnotationScenePollingPolicy.delay(phase: .suspended, elapsed: 0, retry: 0) ?? 0.3)
    }

    private func stop(logReason: String?) {
        let previous = session
        pollingTask?.cancel()
        pollingTask = nil
        needsImmediateSample = false
        removeEventObservers()
        session = nil
        resetCapturerWhenIdle()
        if let previous, let logReason {
            PickyLog.notice(
                .annotationScene,
                prefix: "🖍️",
                message: "annotation scene monitor \(logReason) context=\(previous.identity.contextID) samples=\(previous.sampleCount)"
            )
        }
    }

    private func resetCapturerWhenIdle() {
        guard samplingIdentity == nil else {
            capturerResetPending = true
            return
        }
        capturer.reset()
        capturerResetPending = false
    }

    private func requestSample(after delay: TimeInterval) {
        guard automaticallySchedulesSamples, let session else { return }
        if samplingIdentity != nil {
            needsImmediateSample = true
            return
        }
        let identity = session.identity
        let confirmationDelay = session.confirmationNotBefore.map {
            max(0, $0.timeIntervalSince(now()))
        } ?? 0
        let effectiveDelay = max(delay, confirmationDelay)
        pollingTask?.cancel()
        PickyLog.logger(.annotationScene).debug(
            "schedule context=\(identity.contextID, privacy: .public) phase=\(session.phase.rawValue, privacy: .public) delayMs=\(effectiveDelay * 1_000, format: .fixed(precision: 0))"
        )
        onSampleScheduled?(effectiveDelay)
        pollingTask = Task { @MainActor [weak self] in
            if effectiveDelay > 0 {
                try? await Task.sleep(for: .seconds(effectiveDelay))
            }
            guard !Task.isCancelled, let self else { return }
            await self.performSample(identity: identity)
        }
    }

    private func performSample(identity: PickyAnnotationSceneIdentity) async {
        guard let session, session.identity == identity, samplingIdentity == nil else { return }
        guard !session.targets.isEmpty else {
            scheduleNextSample(for: session)
            return
        }
        if suspendInitialValidationIfExpired(session) {
            scheduleNextSample(for: session)
            return
        }
        let captureEpoch = session.captureEpoch
        samplingIdentity = identity
        defer {
            if samplingIdentity == identity {
                samplingIdentity = nil
                if capturerResetPending {
                    capturer.reset()
                    capturerResetPending = false
                }
                if needsImmediateSample {
                    needsImmediateSample = false
                    requestSample(after: 0)
                } else if self.session?.identity == identity {
                    scheduleNextSample(for: session)
                } else if let currentSession = self.session {
                    scheduleNextSample(for: currentSession)
                }
            }
        }

        let sampleStartedAt = CFAbsoluteTimeGetCurrent()
        // Visual-only policy: annotations are tied to the pixels they were drawn over,
        // not to which app/window is focused. Semantic changes (app switch, window
        // move, scroll, display) never suspend on their own; only an actual change in
        // the captured region does. Working on another screen leaves this drawing alone.
        session.semanticBlock = nil

        do {
            let sample = try await PickyPerf.interval("annotation_scene_sample") {
                try await visualSample(for: session, identity: identity, captureEpoch: captureEpoch)
            }
            guard self.session?.identity == identity,
                  session.captureEpoch == captureEpoch,
                  !Task.isCancelled else { return }
            if suspendInitialValidationIfExpired(session) { return }

            let decision = PickyPerf.interval("annotation_scene_stability") {
                session.stability.observe(
                    sample.observation,
                    phase: session.phase,
                    allowsTolerantRestoration: session.allowsTolerantRestoration
                )
            }
            session.sampleCount += 1
            let metrics = sample.observation.metrics
            switch decision {
            case .none:
                session.retry = session.phase == .suspended ? session.retry + 1 : 0
            case .show:
                session.phase = .visible
                session.retry = 0
                session.semanticBlock = nil
                session.lastMismatchReason = nil
                onOutput?(.matched(identity))
                PickyLog.notice(
                    .annotationScene,
                    prefix: "🖍️",
                    message: "annotation scene visible context=\(identity.contextID) generation=\(identity.generation)"
                )
            case .suspend:
                transitionToSuspended(session, reason: .visual)
            }
            updateConfirmationDeadline(for: session)
            logSample(
                session: session,
                outcome: sample.observation.logName,
                captureMilliseconds: sample.captureMilliseconds,
                compareMilliseconds: sample.comparisonMilliseconds,
                metrics: metrics,
                totalStartedAt: sampleStartedAt
            )
        } catch {
            guard self.session?.identity == identity, !Task.isCancelled else { return }
            session.retry += 1
            PickyLog.noticeRateLimited(
                .annotationScene,
                key: "annotation-scene-capture-\(identity.contextID)",
                cooldown: 10,
                prefix: "⚠️",
                message: "annotation scene capture failed context=\(identity.contextID) error=\(error.localizedDescription)"
            )
        }
    }

    private func visualSample(
        for session: Session,
        identity: PickyAnnotationSceneIdentity,
        captureEpoch: Int
    ) async throws -> VisualSample {
        var observations: [PickyAnnotationSceneVisualObservation] = []
        var captureMilliseconds = 0.0
        var comparisonMilliseconds = 0.0
        for key in session.targets.keys.sorted() {
            guard let target = session.targets[key] else { continue }
            if target.baselineFingerprint == nil {
                let baselineStartedAt = CFAbsoluteTimeGetCurrent()
                let baselineFingerprint = try await capturer.baselineFingerprint(for: target.screenshot)
                captureMilliseconds += (CFAbsoluteTimeGetCurrent() - baselineStartedAt) * 1_000
                guard self.session?.identity == identity,
                      session.captureEpoch == captureEpoch,
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                target.baselineFingerprint = baselineFingerprint
            }
            guard let baselineFingerprint = target.baselineFingerprint else { continue }
            let captureStartedAt = CFAbsoluteTimeGetCurrent()
            let current = try await capturer.currentFingerprint(for: target.screenshot)
            captureMilliseconds += (CFAbsoluteTimeGetCurrent() - captureStartedAt) * 1_000
            guard self.session?.identity == identity,
                  session.captureEpoch == captureEpoch,
                  !Task.isCancelled else {
                throw CancellationError()
            }
            let comparisonStartedAt = CFAbsoluteTimeGetCurrent()
            let observation = PickyPerf.interval("annotation_scene_compare") {
                PickyAnnotationSceneVisualPolicy.compare(
                    baseline: baselineFingerprint,
                    current: current,
                    normalizedRegions: target.normalizedRegions
                )
            }
            comparisonMilliseconds += (CFAbsoluteTimeGetCurrent() - comparisonStartedAt) * 1_000
            observations.append(observation)
        }
        return VisualSample(
            observation: Self.aggregate(observations),
            captureMilliseconds: captureMilliseconds,
            comparisonMilliseconds: comparisonMilliseconds
        )
    }

    private func updateConfirmationDeadline(for session: Session) {
        guard Self.hasPendingVisualConfirmation(session) else {
            session.confirmationNotBefore = nil
            return
        }
        if session.confirmationNotBefore == nil {
            session.confirmationNotBefore = now().addingTimeInterval(0.30)
        }
    }

    private static func hasPendingVisualConfirmation(_ session: Session) -> Bool {
        switch session.phase {
        case .validating:
            session.stability.consecutiveMatches > 0
                || session.stability.consecutiveMismatches > 0
        case .suspended:
            session.stability.consecutiveMatches > 0
        case .visible:
            session.stability.consecutiveMismatches > 0
        case .inactive:
            false
        }
    }

    private func suspendInitialValidationIfExpired(_ session: Session) -> Bool {
        guard session.phase == .validating, now() >= session.initialValidationDeadline else { return false }
        transitionToSuspended(session, reason: .visual)
        return true
    }

    private func transitionToSuspended(_ session: Session, reason: PickyAnnotationSceneMismatchReason) {
        session.stability.reset()
        session.confirmationNotBefore = nil
        let alreadySuspendedForReason = session.phase == .suspended && session.lastMismatchReason == reason
        session.phase = .suspended
        session.lastMismatchReason = reason
        if !alreadySuspendedForReason {
            session.retry = 0
            onOutput?(.mismatched(session.identity, reason))
            PickyLog.notice(
                .annotationScene,
                prefix: "🖍️",
                message: "annotation scene suspended context=\(session.identity.contextID) reason=\(reason.rawValue)"
            )
        }
    }

    private func scheduleNextSample(for session: Session) {
        guard self.session === session else { return }
        switch session.semanticBlock {
        case .application, .window:
            // Notifications wake this path immediately. A slow semantic-only retry
            // prevents a missed Workspace/AX event from suspending annotations forever.
            requestSample(after: 5)
            return
        case .scroll, .display, .visual, .none:
            break
        }
        let elapsed = now().timeIntervalSince(session.startedAt)
        guard let delay = PickyAnnotationScenePollingPolicy.delay(
            phase: session.phase,
            elapsed: elapsed,
            retry: session.retry,
            pendingVisualConfirmation: Self.hasPendingVisualConfirmation(session)
        ) else { return }
        requestSample(after: delay)
    }

    private func logSample(
        session: Session,
        outcome: String,
        captureMilliseconds: Double,
        compareMilliseconds: Double,
        metrics: PickyAnnotationSceneDifferenceMetrics?,
        totalStartedAt: CFAbsoluteTime
    ) {
        let totalMilliseconds = (CFAbsoluteTimeGetCurrent() - totalStartedAt) * 1_000
        let globalChanged = metrics.map { String(format: "%.3f", $0.globalChangedFraction) } ?? "n/a"
        let roiChanged = metrics?.roiChangedFraction.map { String(format: "%.3f", $0) } ?? "n/a"
        PickyLog.logger(.annotationScene).debug(
            "sample context=\(session.identity.contextID, privacy: .public) phase=\(session.phase.rawValue, privacy: .public) outcome=\(outcome, privacy: .public) count=\(session.sampleCount) captureMs=\(captureMilliseconds, format: .fixed(precision: 2)) compareMs=\(compareMilliseconds, format: .fixed(precision: 2)) totalMs=\(totalMilliseconds, format: .fixed(precision: 2)) globalChanged=\(globalChanged, privacy: .public) roiChanged=\(roiChanged, privacy: .public)"
        )
    }

    private static func aggregate(
        _ observations: [PickyAnnotationSceneVisualObservation]
    ) -> PickyAnnotationSceneVisualObservation {
        guard let first = observations.first else {
            let metrics = PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 1,
                globalMeanDifference: 255,
                roiChangedFraction: nil,
                roiMeanDifference: nil
            )
            return .indeterminate(metrics)
        }
        if let mismatch = observations.first(where: { if case .mismatching = $0 { return true }; return false }) {
            return mismatch
        }
        if let indeterminate = observations.first(where: { if case .indeterminate = $0 { return true }; return false }) {
            return indeterminate
        }
        return first
    }

    private static func normalizedRegions(
        for annotations: [PickyAgentAnnotation],
        screenshot: PickyScreenshotContext
    ) -> [String: CGRect] {
        guard let boundsValue = screenshot.bounds else { return [:] }
        let bounds = CGRect(
            x: boundsValue.x,
            y: boundsValue.y,
            width: boundsValue.width,
            height: boundsValue.height
        )
        guard bounds.width > 0, bounds.height > 0 else { return [:] }
        return annotations.reduce(into: [:]) { result, annotation in
            let geometry: CGRect?
            switch annotation.shape {
            case .rect:
                geometry = annotation.rect
            case .line:
                if let start = annotation.point, let end = annotation.endPoint {
                    geometry = CGRect(
                        x: min(start.x, end.x),
                        y: min(start.y, end.y),
                        width: abs(end.x - start.x),
                        height: abs(end.y - start.y)
                    )
                } else {
                    geometry = nil
                }
            case .path:
                geometry = annotation.pathCommands.flatMap(PickyAnnotationPathGeometry.bounds)
            }
            guard var geometry else { return }
            geometry = geometry.insetBy(dx: -16, dy: -16)
            if geometry.width < 32 { geometry = geometry.insetBy(dx: -(32 - geometry.width) / 2, dy: 0) }
            if geometry.height < 32 { geometry = geometry.insetBy(dx: 0, dy: -(32 - geometry.height) / 2) }
            geometry = geometry.intersection(bounds)
            guard !geometry.isNull, !geometry.isEmpty else { return }
            result[annotation.id] = CGRect(
                x: (geometry.minX - bounds.minX) / bounds.width,
                y: (bounds.maxY - geometry.maxY) / bounds.height,
                width: geometry.width / bounds.width,
                height: geometry.height / bounds.height
            )
        }
    }

    private func installEventObservers(
        for baseline: PickyAnnotationSceneBaseline,
        identity: PickyAnnotationSceneIdentity
    ) {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.session?.identity == identity else { return }
                // Focus changes do not touch the drawn pixels; take a fresh visual
                // sample so a real change is still detected promptly.
                self.session?.semanticBlock = nil
                self.requestSample(after: 0)
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.session?.identity == identity else { return }
                self.refreshCaptureGeometryAfterDisplayChange()
            }
        }
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] _ in
            Task { @MainActor [weak self] in self?.handleScroll(identity: identity) }
        }
        localScrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor [weak self] in self?.handleScroll(identity: identity) }
            return event
        }
        installAccessibilityObserver(pid: baseline.applicationPID, identity: identity)
    }

    private func handleScroll(identity: PickyAnnotationSceneIdentity) {
        guard self.session?.identity == identity else { return }
        // Scrolling may or may not change the drawn region; let the visual sampler decide
        // instead of blindly suspending.
        self.session?.semanticBlock = nil
        requestSample(after: 0)
    }

    private func refreshCaptureGeometryAfterDisplayChange() {
        guard let session else { return }
        // A display reconfiguration can change capture geometry, so rebuild the baseline
        // at the new resolution rather than suspending. The drawing is cleared only if the
        // recaptured region actually differs.
        session.captureEpoch &+= 1
        for target in session.targets.values {
            target.baselineFingerprint = nil
        }
        resetCapturerWhenIdle()
        session.semanticBlock = nil
        requestSample(after: 0)
    }

    private func installAccessibilityObserver(
        pid: pid_t?,
        identity: PickyAnnotationSceneIdentity
    ) {
        guard let pid, AXIsProcessTrusted() else { return }
        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let context = Unmanaged<AccessibilityObserverContext>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            Task { @MainActor [weak context] in
                guard let context,
                      let monitor = context.monitor,
                      monitor.session?.identity == context.identity else { return }
                switch name {
                case kAXFocusedWindowChangedNotification as String:
                    monitor.handleAccessibilityWindowChange(
                        identity: context.identity,
                        refreshObservedWindow: true
                    )
                case kAXWindowMovedNotification as String,
                     kAXWindowResizedNotification as String:
                    monitor.handleAccessibilityWindowChange(
                        identity: context.identity,
                        refreshObservedWindow: false
                    )
                case kAXTitleChangedNotification as String:
                    monitor.requestSample(after: 0)
                default:
                    break
                }
            }
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let application = AXUIElementCreateApplication(pid)
        let context = AccessibilityObserverContext(monitor: self, identity: identity)
        let refcon = Unmanaged.passUnretained(context).toOpaque()
        _ = AXObserverAddNotification(observer, application, kAXFocusedWindowChangedNotification as CFString, refcon)
        accessibilityObserver = observer
        accessibilityObserverContext = context
        accessibilityObservedApplication = application
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        observeFocusedWindow(refcon: refcon)
    }

    private func observeFocusedWindow(refcon: UnsafeMutableRawPointer) {
        guard let observer = accessibilityObserver,
              let application = accessibilityObservedApplication else { return }
        if let oldWindow = accessibilityObservedWindow {
            _ = AXObserverRemoveNotification(observer, oldWindow, kAXWindowMovedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, oldWindow, kAXWindowResizedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, oldWindow, kAXTitleChangedNotification as CFString)
        }
        var focused: AnyObject?
        guard AXUIElementCopyAttributeValue(application, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused else {
            accessibilityObservedWindow = nil
            return
        }
        let window = focused as! AXUIElement
        accessibilityObservedWindow = window
        _ = AXObserverAddNotification(observer, window, kAXWindowMovedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, window, kAXWindowResizedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, window, kAXTitleChangedNotification as CFString, refcon)
    }

    private func handleAccessibilityWindowChange(
        identity: PickyAnnotationSceneIdentity,
        refreshObservedWindow: Bool
    ) {
        guard let session,
              session.identity == identity else { return }
        if refreshObservedWindow,
           let context = accessibilityObserverContext,
           context.identity == identity {
            observeFocusedWindow(refcon: Unmanaged.passUnretained(context).toOpaque())
        }
        // Window moves/resizes only matter if they change the captured pixels; re-sample
        // visually instead of suspending on the geometry change alone.
        session.semanticBlock = nil
        requestSample(after: 0)
    }

    private func removeEventObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        workspaceObserver = nil
        screenObserver = nil
        globalScrollMonitor = nil
        localScrollMonitor = nil
        if let observer = accessibilityObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        accessibilityObserver = nil
        accessibilityObserverContext = nil
        accessibilityObservedApplication = nil
        accessibilityObservedWindow = nil
    }
}

@MainActor
enum PickyAnnotationSceneSemanticProvider {
    static func currentWindowSignature(for pid: pid_t) -> PickyAnnotationSceneWindowSignature? {
        guard let windows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]],
        let window = windows.first(where: { info in
            (info[kCGWindowOwnerPID as String] as? pid_t) == pid
                && (info[kCGWindowLayer as String] as? Int) == 0
        }),
        let windowNumber = window[kCGWindowNumber as String] as? CGWindowID,
        let boundsDictionary = window[kCGWindowBounds as String] as? [String: CGFloat],
        let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        return PickyAnnotationSceneWindowSignature(ownerPID: pid, windowID: windowNumber, frame: frame)
    }
}

@MainActor
final class PickyScreenCaptureAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    private struct PreparedDisplay {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
    }

    private let maximumDimension: Int
    private var preparedDisplays: [String: PreparedDisplay] = [:]
    private var baselineFingerprints: [String: PickyAnnotationSceneFingerprint] = [:]

    init(maximumDimension: Int = CompanionScreenCaptureUtility.annotationSceneFingerprintMaximumDimension) {
        self.maximumDimension = maximumDimension
    }

    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        let key = screenshot.screenId ?? screenshot.id
        if let cached = baselineFingerprints[key] { return cached }
        let prepared = try await preparedDisplay(for: screenshot)
        let width = prepared.configuration.width
        let height = prepared.configuration.height
        if let stored = Self.storedBaselineFingerprint(for: screenshot, width: width, height: height) {
            baselineFingerprints[key] = stored
            return stored
        }
        let path = screenshot.path
        let fingerprint = try await Task.detached(priority: .utility) {
            try Self.fingerprintFromImage(atPath: path, width: width, height: height)
        }.value
        baselineFingerprints[key] = fingerprint
        return fingerprint
    }

    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        let prepared = try await preparedDisplay(for: screenshot)
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: prepared.filter,
            configuration: prepared.configuration
        )
        guard let fingerprint = PickyAnnotationSceneFingerprint.make(
            from: image,
            width: prepared.configuration.width,
            height: prepared.configuration.height
        ) else {
            throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed
        }
        return fingerprint
    }

    func reset() {
        preparedDisplays = [:]
        baselineFingerprints = [:]
    }

    private func preparedDisplay(for screenshot: PickyScreenshotContext) async throws -> PreparedDisplay {
        let key = screenshot.screenId ?? screenshot.id
        if let cached = preparedDisplays[key] { return cached }
        guard let boundsValue = screenshot.bounds else { throw PickyAnnotationSceneCaptureError.missingDisplayBounds }
        let bounds = CGRect(x: boundsValue.x, y: boundsValue.y, width: boundsValue.width, height: boundsValue.height)
        let displayID = NSScreen.screens.first(where: { Self.framesMatch($0.frame, bounds) })
            .flatMap { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID }
        guard let displayID else { throw PickyAnnotationSceneCaptureError.displayUnavailable }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw PickyAnnotationSceneCaptureError.displayUnavailable
        }
        let excludedIDs = CompanionScreenCaptureUtility.contextCaptureExcludedWindowIDs(in: NSApp.windows)
        let excludedWindows = content.windows.filter { excludedIDs.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excludedWindows)
        let size = maximumDimension == CompanionScreenCaptureUtility.annotationSceneFingerprintMaximumDimension
            ? CompanionScreenCaptureUtility.annotationSceneFingerprintPixelSize(
                displayWidth: display.width,
                displayHeight: display.height
            )
            : CompanionScreenCaptureUtility.capturePixelSize(
                displayWidth: display.width,
                displayHeight: display.height,
                maximumDimension: maximumDimension
            )
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.showsCursor = false
        configuration.capturesAudio = false
        let prepared = PreparedDisplay(filter: filter, configuration: configuration)
        preparedDisplays[key] = prepared
        return prepared
    }

    static func storedBaselineFingerprint(
        for screenshot: PickyScreenshotContext,
        width: Int,
        height: Int
    ) -> PickyAnnotationSceneFingerprint? {
        guard let fingerprint = screenshot.annotationSceneFingerprint,
              fingerprint.width == width,
              fingerprint.height == height else {
            return nil
        }
        return fingerprint
    }

    private nonisolated static func fingerprintFromImage(
        atPath path: String,
        width: Int,
        height: Int
    ) throws -> PickyAnnotationSceneFingerprint {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let fingerprint = PickyAnnotationSceneFingerprint.make(from: image, width: width, height: height) else {
            throw PickyAnnotationSceneCaptureError.baselineUnavailable
        }
        return fingerprint
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }
}

enum PickyAnnotationSceneCaptureError: LocalizedError {
    case missingDisplayBounds
    case displayUnavailable
    case baselineUnavailable
    case fingerprintCreationFailed

    var errorDescription: String? {
        switch self {
        case .missingDisplayBounds:
            "Annotation scene capture is missing display bounds."
        case .displayUnavailable:
            "Annotation scene display is unavailable."
        case .baselineUnavailable:
            "Annotation scene baseline screenshot is unavailable."
        case .fingerprintCreationFailed:
            "Annotation scene fingerprint creation failed."
        }
    }
}

private extension PickyAnnotationSceneVisualObservation {
    var metrics: PickyAnnotationSceneDifferenceMetrics {
        switch self {
        case .matching(let metrics), .mismatching(let metrics), .indeterminate(let metrics):
            metrics
        }
    }

    var logName: String {
        switch self {
        case .matching: "matching"
        case .mismatching: "mismatching"
        case .indeterminate: "indeterminate"
        }
    }
}
