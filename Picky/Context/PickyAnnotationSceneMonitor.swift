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
    func baselineRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint
    func currentRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint
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
        var regionBaselineFingerprints: [String: PickyAnnotationSceneFingerprint] = [:]
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
        let invalidationProfile: PickyAnnotationSceneInvalidationProfile
        let captureMilliseconds: Double
        let comparisonMilliseconds: Double
        let stableFraction: Double?
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
        var hasObservedInitialHardMismatch = false
        var allowsTolerantRestoration: Bool
        var narrationActive = false

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
    private var workspaceHideObserver: NSObjectProtocol?
    private var activeSpaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var globalScrollMonitor: Any?
    private var localScrollMonitor: Any?
    private var accessibilityObserver: AXObserver?
    private var accessibilityObserverContext: AccessibilityObserverContext?
    private var accessibilityObservedApplication: AXUIElement?
    private var accessibilityObservedWindow: AXUIElement?
    private var semanticVerificationTask: Task<Void, Never>?

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
        PickyLog.noticeRateLimited(
            .annotationScene,
            key: "annotation-scene-transition-\(baseline.contextID)-validating",
            cooldown: 1,
            prefix: "🖍️",
            message: "annotation scene validating context=\(baseline.contextID) generation=\(identity.generation)"
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
            for (annotationID, region) in regions {
                if target.normalizedRegionsByAnnotationID[annotationID] != region {
                    target.regionBaselineFingerprints[annotationID] = nil
                }
                target.normalizedRegionsByAnnotationID[annotationID] = region
            }
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

    func setNarrationActive(_ narrationActive: Bool) {
        guard let session, session.narrationActive != narrationActive else { return }
        session.narrationActive = narrationActive
        // Do not combine confirmations collected under different invalidation profiles.
        session.stability.reset()
        session.confirmationNotBefore = nil
        requestSample(after: 0)
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
                target.regionBaselineFingerprints = [:]
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
        semanticVerificationTask?.cancel()
        semanticVerificationTask = nil
        needsImmediateSample = false
        removeEventObservers()
        session = nil
        resetCapturerWhenIdle()
        if let previous, let logReason {
            PickyLog.noticeRateLimited(
                .annotationScene,
                key: "annotation-scene-transition-\(previous.identity.contextID)-inactive",
                cooldown: 1,
                prefix: "🖍️",
                message: "annotation scene inactive context=\(previous.identity.contextID) reason=\(logReason) samples=\(previous.sampleCount)"
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
        // Annotations are tied to the pixels they were drawn over, not focus alone.
        // Low-resolution polling remains a gradual-change safety net; semantic signals
        // independently verify high-resolution ROIs and suspend only on an actual change.
        // Working on another screen therefore leaves this drawing alone.
        session.semanticBlock = nil

        do {
            let sample = try await PickyPerf.interval("annotation_scene_sample") {
                try await visualSample(for: session, identity: identity, captureEpoch: captureEpoch)
            }
            guard self.session?.identity == identity,
                  session.captureEpoch == captureEpoch,
                  !Task.isCancelled else { return }
            if suspendInitialValidationIfExpired(session) { return }

            if session.phase == .validating,
               case .mismatching(let metrics) = sample.observation,
               PickyAnnotationSceneVisualPolicy.isInitialHardMismatch(metrics) {
                session.hasObservedInitialHardMismatch = true
            }
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
                transitionToVisible(session)
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
                invalidationProfile: sample.invalidationProfile,
                stableFraction: sample.stableFraction,
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
        let invalidationProfile: PickyAnnotationSceneInvalidationProfile = session.narrationActive
            ? .lenient
            : .strict
        var observations: [PickyAnnotationSceneVisualObservation] = []
        var captureMilliseconds = 0.0
        var comparisonMilliseconds = 0.0
        var minStableFraction: Double?
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
            for annotationID in target.normalizedRegionsByAnnotationID.keys.sorted() {
                guard target.regionBaselineFingerprints[annotationID] == nil,
                      let region = target.normalizedRegionsByAnnotationID[annotationID] else { continue }
                let baselineStartedAt = CFAbsoluteTimeGetCurrent()
                let regionBaseline = try await capturer.baselineRegionFingerprint(
                    for: target.screenshot,
                    normalizedRegion: region
                )
                captureMilliseconds += (CFAbsoluteTimeGetCurrent() - baselineStartedAt) * 1_000
                guard self.session?.identity == identity,
                      session.captureEpoch == captureEpoch,
                      !Task.isCancelled else {
                    throw CancellationError()
                }
                target.regionBaselineFingerprints[annotationID] = regionBaseline
            }
            let captureStartedAt = CFAbsoluteTimeGetCurrent()
            let current = try await capturer.currentFingerprint(for: target.screenshot)
            captureMilliseconds += (CFAbsoluteTimeGetCurrent() - captureStartedAt) * 1_000
            guard self.session?.identity == identity,
                  session.captureEpoch == captureEpoch,
                  !Task.isCancelled else {
                throw CancellationError()
            }
            // The comparison is pure array math over Sendable fingerprints; run it off the main
            // actor so structural analysis never blocks UI during rapid screen-transition polling.
            let regions = target.normalizedRegions
            let comparisonStartedAt = CFAbsoluteTimeGetCurrent()
            let result = await Task.detached(priority: .utility) {
                PickyPerf.interval("annotation_scene_compare") {
                    PickyAnnotationSceneVisualPolicy.evaluate(
                        baseline: baselineFingerprint,
                        current: current,
                        normalizedRegions: regions,
                        invalidationProfile: invalidationProfile
                    )
                }
            }.value
            comparisonMilliseconds += (CFAbsoluteTimeGetCurrent() - comparisonStartedAt) * 1_000
            observations.append(result.observation)
            if let stableFraction = result.stableFraction {
                minStableFraction = Swift.min(minStableFraction ?? stableFraction, stableFraction)
            }
        }
        return VisualSample(
            observation: Self.aggregate(observations),
            invalidationProfile: invalidationProfile,
            captureMilliseconds: captureMilliseconds,
            comparisonMilliseconds: comparisonMilliseconds,
            stableFraction: minStableFraction
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
        if session.hasObservedInitialHardMismatch {
            transitionToSuspended(session, reason: .visual)
        } else {
            // Initial validation is fail-open: normal page animation and localized
            // content drift must not make annotations disappear before first reveal.
            session.stability.reset()
            session.confirmationNotBefore = nil
            transitionToVisible(session)
        }
        return true
    }

    private func transitionToVisible(_ session: Session) {
        session.phase = .visible
        session.retry = 0
        session.semanticBlock = nil
        session.lastMismatchReason = nil
        onOutput?(.matched(session.identity))
        PickyLog.noticeRateLimited(
            .annotationScene,
            key: "annotation-scene-transition-\(session.identity.contextID)-visible",
            cooldown: 1,
            prefix: "🖍️",
            message: "annotation scene visible context=\(session.identity.contextID) generation=\(session.identity.generation)"
        )
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
            PickyLog.noticeRateLimited(
                .annotationScene,
                key: "annotation-scene-transition-\(session.identity.contextID)-suspended-\(reason.rawValue)",
                cooldown: 1,
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
        case .scroll, .display, .visual, .validationTimeout, .none:
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
        invalidationProfile: PickyAnnotationSceneInvalidationProfile,
        stableFraction: Double?,
        totalStartedAt: CFAbsoluteTime
    ) {
        let totalMilliseconds = (CFAbsoluteTimeGetCurrent() - totalStartedAt) * 1_000
        let globalChanged = metrics.map { String(format: "%.3f", $0.globalChangedFraction) } ?? "n/a"
        let globalMean = metrics.map { String(format: "%.2f", $0.globalMeanDifference) } ?? "n/a"
        let roiChanged = metrics?.roiChangedFraction.map { String(format: "%.3f", $0) } ?? "n/a"
        let roiMean = metrics?.roiMeanDifference.map { String(format: "%.2f", $0) } ?? "n/a"
        let stable = stableFraction.map { String(format: "%.3f", $0) } ?? "n/a"
        let message = "sample context=\(session.identity.contextID) phase=\(session.phase.rawValue) profile=\(invalidationProfile.rawValue) outcome=\(outcome) count=\(session.sampleCount) captureMs=\(String(format: "%.2f", captureMilliseconds)) compareMs=\(String(format: "%.2f", compareMilliseconds)) totalMs=\(String(format: "%.2f", totalMilliseconds)) globalChanged=\(globalChanged) globalMean=\(globalMean) roiChanged=\(roiChanged) roiMean=\(roiMean) stableFraction=\(stable)"
        switch session.phase {
        case .validating, .suspended:
            PickyLog.noticeRateLimited(
                .annotationScene,
                key: "annotation-scene-sample-\(session.identity.contextID)-\(session.phase.rawValue)-\(outcome)",
                cooldown: 1,
                prefix: "🖍️",
                message: message
            )
        case .visible, .inactive:
            PickyLog.logger(.annotationScene).debug("\(message, privacy: .public)")
        }
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

    private func verifyRegionsAfterSemanticSignal(
        identity: PickyAnnotationSceneIdentity,
        reason: PickyAnnotationSceneMismatchReason,
        debounce: TimeInterval = 0
    ) {
        guard session?.identity == identity else { return }
        semanticVerificationTask?.cancel()
        semanticVerificationTask = Task { @MainActor [weak self] in
            if debounce > 0 {
                try? await Task.sleep(for: .seconds(debounce))
            }
            guard !Task.isCancelled, let self else { return }
            await self.performSemanticRegionVerification(identity: identity, reason: reason)
        }
    }

    /// Test hook for the same path used by workspace and accessibility notifications.
    func verifyRegionsAfterSemanticSignalNow(
        identity: PickyAnnotationSceneIdentity,
        reason: PickyAnnotationSceneMismatchReason
    ) async {
        await performSemanticRegionVerification(identity: identity, reason: reason)
    }

    private func performSemanticRegionVerification(
        identity: PickyAnnotationSceneIdentity,
        reason: PickyAnnotationSceneMismatchReason
    ) async {
        guard let session, session.identity == identity, !session.targets.isEmpty else { return }
        guard samplingIdentity == nil else {
            verifyRegionsAfterSemanticSignal(identity: identity, reason: reason, debounce: 0.05)
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
                }
            }
        }

        do {
            for key in session.targets.keys.sorted() {
                guard let target = session.targets[key] else { continue }
                for annotationID in target.normalizedRegionsByAnnotationID.keys.sorted() {
                    guard let region = target.normalizedRegionsByAnnotationID[annotationID] else { continue }
                    let baseline: PickyAnnotationSceneFingerprint
                    if let cached = target.regionBaselineFingerprints[annotationID] {
                        baseline = cached
                    } else {
                        baseline = try await capturer.baselineRegionFingerprint(
                            for: target.screenshot,
                            normalizedRegion: region
                        )
                        guard self.session?.identity == identity,
                              session.captureEpoch == captureEpoch,
                              !Task.isCancelled else { return }
                        target.regionBaselineFingerprints[annotationID] = baseline
                    }
                    let current = try await capturer.currentRegionFingerprint(
                        for: target.screenshot,
                        normalizedRegion: region
                    )
                    guard self.session?.identity == identity,
                          session.captureEpoch == captureEpoch,
                          !Task.isCancelled else { return }
                    let observation = PickyAnnotationSceneVisualPolicy.compare(
                        baseline: baseline,
                        current: current,
                        normalizedRegions: [],
                        invalidationProfile: .semantic
                    )
                    let metrics = observation.metrics
                    let changed = if case .mismatching = observation { true } else { false }
                    PickyLog.noticeRateLimited(
                        .annotationScene,
                        key: "annotation-scene-semantic-\(identity.contextID)-\(reason.rawValue)-\(annotationID)",
                        cooldown: 0.2,
                        prefix: "🖍️",
                        message: "semantic roi context=\(identity.contextID) reason=\(reason.rawValue) annotation=\(annotationID) changed=\(changed) changedFraction=\(String(format: "%.3f", metrics.globalChangedFraction)) meanDifference=\(String(format: "%.2f", metrics.globalMeanDifference)) decision=\(changed ? "clear" : "keep")"
                    )
                    if changed {
                        suspendImmediately(reason: reason)
                        return
                    }
                }
            }
        } catch {
            guard self.session?.identity == identity, !Task.isCancelled else { return }
            PickyLog.noticeRateLimited(
                .annotationScene,
                key: "annotation-scene-semantic-capture-\(identity.contextID)-\(reason.rawValue)",
                cooldown: 10,
                prefix: "⚠️",
                message: "annotation scene semantic ROI capture failed context=\(identity.contextID) reason=\(reason.rawValue) error=\(error.localizedDescription)"
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
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.handleActivatedApplication(
                    identity: identity,
                    applicationPID: application?.processIdentifier,
                    applicationBundleID: application?.bundleIdentifier
                )
            }
        }
        workspaceHideObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            Task { @MainActor [weak self] in
                self?.handleHiddenApplication(identity: identity, applicationPID: application?.processIdentifier)
            }
        }
        activeSpaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.verifyRegionsAfterSemanticSignal(identity: identity, reason: .window)
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

    func handleActivatedApplication(
        identity: PickyAnnotationSceneIdentity,
        applicationPID: pid_t?,
        applicationBundleID: String?
    ) {
        guard let session, session.identity == identity else { return }
        guard let applicationPID else {
            session.semanticBlock = nil
            requestSample(after: 0)
            return
        }
        guard !isPickyApplication(pid: applicationPID, bundleID: applicationBundleID),
              let baselinePID = session.baseline.applicationPID,
              applicationPID != baselinePID else {
            session.semanticBlock = nil
            requestSample(after: 0)
            return
        }
        verifyRegionsAfterSemanticSignal(identity: identity, reason: .application)
    }

    func handleHiddenApplication(
        identity: PickyAnnotationSceneIdentity,
        applicationPID: pid_t?
    ) {
        guard let session,
              session.identity == identity,
              let baselinePID = session.baseline.applicationPID,
              applicationPID == baselinePID,
              baselinePID != ProcessInfo.processInfo.processIdentifier else { return }
        suspendImmediately(reason: .application)
    }

    private func isPickyApplication(pid: pid_t, bundleID: String?) -> Bool {
        if pid == ProcessInfo.processInfo.processIdentifier { return true }
        return bundleID == Bundle.main.bundleIdentifier
    }

    private func handleScroll(identity: PickyAnnotationSceneIdentity) {
        guard self.session?.identity == identity else { return }
        // Momentum scrolling emits many events; inspect the final settled ROI once.
        verifyRegionsAfterSemanticSignal(identity: identity, reason: .scroll, debounce: 0.20)
    }

    private func refreshCaptureGeometryAfterDisplayChange() {
        guard let session else { return }
        // A display reconfiguration can change capture geometry, so rebuild the baseline
        // at the new resolution rather than suspending. The drawing is cleared only if the
        // recaptured region actually differs.
        session.captureEpoch &+= 1
        for target in session.targets.values {
            target.baselineFingerprint = nil
            target.regionBaselineFingerprints = [:]
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
                case kAXTitleChangedNotification as String,
                     kAXLayoutChangedNotification as String,
                     kAXValueChangedNotification as String:
                    monitor.verifyRegionsAfterSemanticSignal(identity: context.identity, reason: .window)
                case kAXWindowMiniaturizedNotification as String,
                     kAXUIElementDestroyedNotification as String:
                    monitor.suspendImmediately(reason: .window)
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
        _ = AXObserverAddNotification(observer, application, kAXLayoutChangedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, application, kAXValueChangedNotification as CFString, refcon)
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
            _ = AXObserverRemoveNotification(observer, oldWindow, kAXWindowMiniaturizedNotification as CFString)
            _ = AXObserverRemoveNotification(observer, oldWindow, kAXUIElementDestroyedNotification as CFString)
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
        _ = AXObserverAddNotification(observer, window, kAXWindowMiniaturizedNotification as CFString, refcon)
        _ = AXObserverAddNotification(observer, window, kAXUIElementDestroyedNotification as CFString, refcon)
    }

    private func handleAccessibilityWindowChange(
        identity: PickyAnnotationSceneIdentity,
        refreshObservedWindow: Bool
    ) {
        guard let session, session.identity == identity else { return }
        if refreshObservedWindow,
           let context = accessibilityObserverContext,
           context.identity == identity {
            observeFocusedWindow(refcon: Unmanaged.passUnretained(context).toOpaque())
        }
        // Window geometry and focus are only hints; the high-resolution ROI decides
        // whether the annotation's anchor actually changed.
        verifyRegionsAfterSemanticSignal(identity: identity, reason: .window)
    }

    func handleFocusedWindowChange(
        identity: PickyAnnotationSceneIdentity,
        focusedWindow _: PickyAnnotationSceneWindowSignature?
    ) {
        guard let session, session.identity == identity else { return }
        guard session.baseline.applicationPID != ProcessInfo.processInfo.processIdentifier else { return }
        verifyRegionsAfterSemanticSignal(identity: identity, reason: .window)
    }

    private func removeEventObservers() {
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let workspaceHideObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceHideObserver)
        }
        if let activeSpaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activeSpaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
        if let globalScrollMonitor { NSEvent.removeMonitor(globalScrollMonitor) }
        if let localScrollMonitor { NSEvent.removeMonitor(localScrollMonitor) }
        workspaceObserver = nil
        workspaceHideObserver = nil
        activeSpaceObserver = nil
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
        }) else {
            return nil
        }
        return windowSignature(from: window, ownerPID: pid)
    }

    static func windowSignature(
        for pid: pid_t,
        accessibilityWindow: AXUIElement
    ) -> PickyAnnotationSceneWindowSignature? {
        guard let accessibilityFrame = accessibilityFrame(for: accessibilityWindow),
              let windows = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements],
                kCGNullWindowID
              ) as? [[String: Any]] else {
            return nil
        }
        let matches = windows.compactMap { window -> PickyAnnotationSceneWindowSignature? in
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let signature = windowSignature(from: window, ownerPID: pid),
                  framesMatch(signature.frame, accessibilityFrame) else {
                return nil
            }
            return signature
        }
        // Overlapping or transient windows can share geometry. Do not make a semantic
        // decision unless AX and CG identify one focused window unambiguously.
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func accessibilityFrame(for window: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition,
              let rawSize else {
            return nil
        }
        let positionValue = rawPosition as! AXValue
        let sizeValue = rawSize as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func windowSignature(
        from window: [String: Any],
        ownerPID: pid_t
    ) -> PickyAnnotationSceneWindowSignature? {
        guard let windowNumber = window[kCGWindowNumber as String] as? CGWindowID,
              let boundsDictionary = window[kCGWindowBounds as String] as? [String: CGFloat],
              let frame = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else {
            return nil
        }
        return PickyAnnotationSceneWindowSignature(ownerPID: ownerPID, windowID: windowNumber, frame: frame)
    }
}

@MainActor
final class PickyScreenCaptureAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    private struct PreparedDisplay {
        let filter: SCContentFilter
        let configuration: SCStreamConfiguration
        let nativePixelSize: CGSize
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
        return try await fingerprint(
            contentFilter: prepared.filter,
            configuration: prepared.configuration
        )
    }

    func baselineRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        let path = screenshot.path
        return try await Task.detached(priority: .utility) {
            try Self.regionFingerprintFromImage(atPath: path, normalizedRegion: normalizedRegion)
        }.value
    }

    func currentRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        let prepared = try await preparedDisplay(for: screenshot)
        let configuration = try regionConfiguration(
            for: screenshot,
            normalizedRegion: normalizedRegion,
            prepared: prepared
        )
        return try await fingerprint(contentFilter: prepared.filter, configuration: configuration)
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

        let content = try await PickySystemPermissionGateway.shared.screenShareableContent()
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
        let prepared = PreparedDisplay(
            filter: filter,
            configuration: configuration,
            nativePixelSize: CGSize(width: display.width, height: display.height)
        )
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

    /// The captured CGImage is immutable and only read; boxing lets the resample + edge-mask
    /// derivation run off the main actor without a data race.
    private struct CapturedImage: @unchecked Sendable {
        let image: CGImage
    }

    private func fingerprint(
        contentFilter: SCContentFilter,
        configuration: SCStreamConfiguration
    ) async throws -> PickyAnnotationSceneFingerprint {
        let image = try await PickySystemPermissionGateway.shared.captureScreenshot(
            contentFilter: contentFilter,
            configuration: configuration
        )
        let captured = CapturedImage(image: image)
        let width = configuration.width
        let height = configuration.height
        let made = await Task.detached(priority: .utility) {
            PickyAnnotationSceneFingerprint.make(from: captured.image, width: width, height: height)
        }.value
        guard let made else {
            throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed
        }
        return made
    }

    private func regionConfiguration(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect,
        prepared: PreparedDisplay
    ) throws -> SCStreamConfiguration {
        guard let boundsValue = screenshot.bounds else { throw PickyAnnotationSceneCaptureError.missingDisplayBounds }
        let region = normalizedRegion.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, !region.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = CGRect(
            x: region.minX * boundsValue.width,
            y: region.minY * boundsValue.height,
            width: region.width * boundsValue.width,
            height: region.height * boundsValue.height
        )
        configuration.width = max(1, Int((region.width * prepared.nativePixelSize.width).rounded()))
        configuration.height = max(1, Int((region.height * prepared.nativePixelSize.height).rounded()))
        configuration.showsCursor = false
        configuration.capturesAudio = false
        return configuration
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

    private nonisolated static func regionFingerprintFromImage(
        atPath path: String,
        normalizedRegion: CGRect
    ) throws -> PickyAnnotationSceneFingerprint {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw PickyAnnotationSceneCaptureError.baselineUnavailable
        }
        let region = normalizedRegion.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let crop = CGRect(
            x: floor(region.minX * CGFloat(image.width)),
            y: floor(region.minY * CGFloat(image.height)),
            width: ceil(region.width * CGFloat(image.width)),
            height: ceil(region.height * CGFloat(image.height))
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard !crop.isNull,
              !crop.isEmpty,
              let croppedImage = image.cropping(to: crop),
              let fingerprint = PickyAnnotationSceneFingerprint.make(
                from: croppedImage,
                width: croppedImage.width,
                height: croppedImage.height
              ) else {
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
