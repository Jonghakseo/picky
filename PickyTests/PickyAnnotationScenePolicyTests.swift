import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyAnnotationScenePolicyTests {
    @Test func restorationRequiresTwoConsecutiveMatchesAgainstTheOriginalContext() throws {
        var tracker = PickyAnnotationSceneStabilityTracker()
        let matching = PickyAnnotationSceneVisualObservation.matching(.zero)

        #expect(tracker.observe(matching, phase: .suspended) == .none)
        #expect(tracker.observe(matching, phase: .suspended) == .show)
    }

    @Test func visibleSceneRequiresTwoConsecutiveMismatchesBeforeSuspending() throws {
        var tracker = PickyAnnotationSceneStabilityTracker()
        let mismatching = PickyAnnotationSceneVisualObservation.mismatching(.changed)

        #expect(tracker.observe(mismatching, phase: .visible) == .none)
        #expect(tracker.observe(mismatching, phase: .visible) == .suspend)
    }

    @Test func initialValidationSuspendsAfterTwoHardMismatches() {
        var tracker = PickyAnnotationSceneStabilityTracker()
        let mismatching = PickyAnnotationSceneVisualObservation.mismatching(.changed)

        #expect(tracker.observe(mismatching, phase: .validating) == .none)
        #expect(tracker.observe(mismatching, phase: .validating) == .suspend)
    }

    @Test func initialValidationAcceptsStableLocalizedDriftButRestorationRemainsStrictByDefault() {
        let transientHighlightDrift = PickyAnnotationSceneVisualObservation.indeterminate(
            PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 0.02,
                globalMeanDifference: 1.2,
                roiChangedFraction: 0.125,
                roiMeanDifference: 7.5
            )
        )
        var validating = PickyAnnotationSceneStabilityTracker()

        #expect(validating.observe(transientHighlightDrift, phase: .validating) == .none)
        #expect(validating.observe(transientHighlightDrift, phase: .validating) == .show)

        var restoring = PickyAnnotationSceneStabilityTracker()
        #expect(restoring.observe(transientHighlightDrift, phase: .suspended) == .none)
        #expect(restoring.observe(transientHighlightDrift, phase: .suspended) == .none)

        let largerLocalizedChange = PickyAnnotationSceneVisualObservation.indeterminate(
            PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 0.02,
                globalMeanDifference: 1.2,
                roiChangedFraction: 0.18,
                roiMeanDifference: 12
            )
        )
        var tolerantValidation = PickyAnnotationSceneStabilityTracker()
        #expect(tolerantValidation.observe(largerLocalizedChange, phase: .validating) == .none)
        #expect(tolerantValidation.observe(largerLocalizedChange, phase: .validating) == .show)
    }

    @Test func suspendedRestorationUsesInitialToleranceWhileNarrationAllowsRecovery() {
        let transientHighlightDrift = PickyAnnotationSceneVisualObservation.indeterminate(
            PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 0.02,
                globalMeanDifference: 1.2,
                roiChangedFraction: 0.125,
                roiMeanDifference: 7.5
            )
        )
        var restoring = PickyAnnotationSceneStabilityTracker()

        #expect(restoring.observe(
            transientHighlightDrift,
            phase: .suspended,
            allowsTolerantRestoration: true
        ) == .none)
        #expect(restoring.observe(
            transientHighlightDrift,
            phase: .suspended,
            allowsTolerantRestoration: true
        ) == .show)
    }

    @Test func indeterminateFrameBreaksAConsecutiveSequence() throws {
        var tracker = PickyAnnotationSceneStabilityTracker()
        let matching = PickyAnnotationSceneVisualObservation.matching(.zero)
        let indeterminate = PickyAnnotationSceneVisualObservation.indeterminate(.ambiguous)

        #expect(tracker.observe(matching, phase: .validating) == .none)
        #expect(tracker.observe(indeterminate, phase: .validating) == .none)
        #expect(tracker.observe(matching, phase: .validating) == .none)
        #expect(tracker.observe(matching, phase: .validating) == .show)
    }

    @Test func visualPolicyIgnoresSmallChangesOutsideAnnotationRegions() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        pixels[0] = 255
        pixels[1] = 255
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3)]
        )

        guard case .matching(let metrics) = observation else {
            Issue.record("Expected unrelated corner changes to keep the annotation scene matching")
            return
        }
        #expect(metrics.globalChangedFraction == 0.02)
        #expect(metrics.roiChangedFraction == 0)
    }

    @Test func visualPolicyKeepsROILocalChangesBelowRelaxedInvalidationThresholdIndeterminate() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in [44, 45, 46, 47, 54, 55, 56, 57] { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)]
        )

        guard case .indeterminate(let metrics) = observation else {
            Issue.record("Expected a 50% ROI repaint to remain below the relaxed invalidation threshold")
            return
        }
        #expect(metrics.roiChangedFraction == 0.5)
        #expect(metrics.roiMeanDifference == 9.5)
    }

    @Test func visualPolicyKeepsGlobalChangesBelowRelaxedInvalidationThresholdIndeterminate() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in 0..<47 { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: []
        )

        guard case .indeterminate(let metrics) = observation else {
            Issue.record("Expected a 47% global repaint to remain below the relaxed invalidation threshold")
            return
        }
        #expect(metrics.globalChangedFraction == 0.47)
        #expect(metrics.globalMeanDifference == 8.93)
    }

    @Test func visualPolicyRejectsChangesInsideAnAnnotationRegion() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for y in 4...7 {
            for x in 4...7 {
                pixels[y * 10 + x] = 255
            }
        }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)]
        )

        guard case .mismatching(let metrics) = observation else {
            Issue.record("Expected an annotation-region change to invalidate the scene")
            return
        }
        #expect(metrics.roiChangedFraction == 1)
    }

    @Test func visualPolicyRejectsLargeGlobalSceneChangesWithoutRegions() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        let current = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        ))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: []
        )

        guard case .mismatching(let metrics) = observation else {
            Issue.record("Expected a full-screen change to invalidate the scene")
            return
        }
        #expect(metrics.globalChangedFraction == 1)
    }

    @Test func pollingBacksOffAfterTheInitialVisibleWindow() {
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .validating, elapsed: 0, retry: 0) == 0.30)
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .visible, elapsed: 2, retry: 0) == 0.50)
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .visible, elapsed: 10, retry: 0) == 1.0)
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .visible, elapsed: 60, retry: 0) == 1.5)
        #expect(PickyAnnotationScenePollingPolicy.delay(
            phase: .visible,
            elapsed: 60,
            retry: 0,
            pendingVisualConfirmation: true
        ) == 0.30)
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .suspended, elapsed: 0, retry: 3) == 2.40)
        #expect(PickyAnnotationScenePollingPolicy.delay(
            phase: .suspended,
            elapsed: 60,
            retry: 99,
            pendingVisualConfirmation: true
        ) == 0.30)
        #expect(PickyAnnotationScenePollingPolicy.delay(phase: .suspended, elapsed: 0, retry: 99) == 5.0)
    }

    @Test func sceneIdentityEventsRoundTripThroughTheInteractionJournalCodec() throws {
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 7,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
        )
        let events: [PickyInteractionEvent] = [
            .agentAnnotationScenePrepared(identity: identity),
            .agentAnnotationSceneMatched(identity: identity),
            .agentAnnotationSceneMismatched(identity: identity, reason: .window),
        ]
        for event in events {
            let data = try JSONEncoder().encode(event)
            #expect(try JSONDecoder().decode(PickyInteractionEvent.self, from: data) == event)
        }
    }

    @Test func monitorPrefersOnlyDimensionMatchedStoredBaselineFingerprint() throws {
        let stored = try #require(PickyAnnotationSceneFingerprint(
            width: 256,
            height: 128,
            luminance: [UInt8](repeating: 64, count: 256 * 128)
        ))
        let screenshot = PickyScreenshotContext(
            id: "shot-1",
            label: "screen",
            path: "/tmp/fallback.jpg",
            screenId: "screen1",
            bounds: PickyCGRect(x: 0, y: 0, width: 100, height: 50),
            annotationSceneFingerprint: stored
        )

        #expect(PickyScreenCaptureAnnotationSceneCapturer.storedBaselineFingerprint(
            for: screenshot,
            width: 256,
            height: 128
        ) == stored)
        #expect(PickyScreenCaptureAnnotationSceneCapturer.storedBaselineFingerprint(
            for: screenshot,
            width: 255,
            height: 128
        ) == nil)
    }

    @Test func monitorValidatesSuspendsAndResumesWithoutDiscardingItsIdentity() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let changedFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        ))
        let capturer = FakeAnnotationSceneCapturer(
            baseline: baselineFingerprint,
            current: [
                baselineFingerprint, baselineFingerprint,
                changedFingerprint, changedFingerprint,
                baselineFingerprint, baselineFingerprint,
            ]
        )
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 4,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000004")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(
            identity: identity,
            baseline: PickyAnnotationSceneBaseline(
                contextID: "context",
                applicationPID: nil,
                applicationBundleID: nil,
                window: nil
            )
        )
        monitor.updateTarget(
            screenshot: screenshot(),
            annotations: [annotation()],
            mode: .append
        )

        await monitor.sampleNow()
        #expect(outputs.isEmpty)
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity), .mismatched(identity, .visual)])

        await monitor.sampleNow()
        #expect(outputs.count == 2)
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity), .mismatched(identity, .visual), .matched(identity)])
        monitor.stop()
    }

    @Test func monitorAllowsInitialLocalizedDriftButRequiresStrictRestoration() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        var driftPixels = baselineFingerprint.luminance
        for index in [44, 45, 54, 55] { driftPixels[index] = 124 }
        let highlightDrift = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: driftPixels
        ))
        let capturer = FakeAnnotationSceneCapturer(
            baseline: baselineFingerprint,
            current: [
                highlightDrift, highlightDrift,
                highlightDrift, highlightDrift,
                baselineFingerprint, baselineFingerprint,
            ]
        )
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 5,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000005")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        monitor.suspendImmediately(reason: .scroll)
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity), .mismatched(identity, .scroll)])

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [
            .matched(identity),
            .mismatched(identity, .scroll),
            .matched(identity),
        ])
        monitor.stop()
    }

    @Test func monitorRestoresLocalizedDriftWhileNarrationAllowsRecovery() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        var driftPixels = baselineFingerprint.luminance
        for index in [44, 45, 54, 55] { driftPixels[index] = 124 }
        let highlightDrift = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: driftPixels
        ))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [
                    highlightDrift, highlightDrift,
                    highlightDrift, highlightDrift,
                ]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 6,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(
            identity: identity,
            baseline: sceneBaseline(contextID: "context"),
            allowsTolerantRestoration: true
        )
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        monitor.suspendImmediately(reason: .scroll)
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [
            .matched(identity),
            .mismatched(identity, .scroll),
            .matched(identity),
        ])
        monitor.stop()
    }

    @Test func monitorReturnsToStrictRestorationWhenNarrationRecoveryEnds() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        var driftPixels = baselineFingerprint.luminance
        for index in [44, 45, 54, 55] { driftPixels[index] = 124 }
        let highlightDrift = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: driftPixels
        ))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [
                    highlightDrift, highlightDrift,
                    highlightDrift, highlightDrift,
                ]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 7,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(
            identity: identity,
            baseline: sceneBaseline(contextID: "context"),
            allowsTolerantRestoration: true
        )
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        monitor.suspendImmediately(reason: .scroll)
        monitor.setAllowsTolerantRestoration(false)
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [
            .matched(identity),
            .mismatched(identity, .scroll),
        ])
        monitor.stop()
    }

    @Test func monitorSuspendsAnInitialHardMismatchInsteadOfValidatingForever() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let changedFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        ))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [changedFingerprint, changedFingerprint]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 6,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000006")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.sampleNow()
        #expect(outputs.isEmpty)
        await monitor.sampleNow()
        #expect(outputs == [.mismatched(identity, .visual)])
        monitor.stop()
    }

    @Test func monitorSuspendsInitialValidationAtTwoSecondsWhenObservationsRemainIndeterminate() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let indeterminateFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 79, count: 100)
        ))
        var currentTime = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [indeterminateFingerprint, indeterminateFingerprint]
            ),
            now: { currentTime },
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 7,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000007")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.sampleNow()
        #expect(outputs.isEmpty)

        currentTime = currentTime.addingTimeInterval(2)
        await monitor.sampleNow()
        #expect(outputs == [.mismatched(identity, .visual)])
        monitor.stop()
    }

    @Test func replacingAContextSerializesCanceledAndNewSceneSamples() async throws {
        let referenceFingerprint = try #require(fingerprint(width: 10, height: 10))
        let capturer = SuspendingAnnotationSceneCapturer(fingerprint: referenceFingerprint)
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            automaticallySchedulesSamples: false
        )
        let firstIdentity = PickyAnnotationSceneIdentity(
            contextID: "first",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000021")!
        )
        let secondIdentity = PickyAnnotationSceneIdentity(
            contextID: "second",
            generation: 2,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000022")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: firstIdentity, baseline: sceneBaseline(contextID: "first"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        let firstSample = Task { await monitor.sampleNow() }
        while capturer.baselineCallCount == 0 { await Task.yield() }

        monitor.start(identity: secondIdentity, baseline: sceneBaseline(contextID: "second"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)
        let overlappingSample = Task { await monitor.sampleNow() }
        for _ in 0..<5 { await Task.yield() }

        #expect(capturer.maximumConcurrentCaptures == 1)
        #expect(capturer.resetDuringCaptureCount == 0)

        capturer.resumeFirstBaseline()
        await firstSample.value
        await overlappingSample.value
        #expect(capturer.resetCount >= 2)
        #expect(outputs.isEmpty)

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(secondIdentity)])
        monitor.stop()
    }

    @Test func displayInvalidationRejectsAnInFlightFrameAndCanResume() async throws {
        let referenceFingerprint = try #require(fingerprint(width: 10, height: 10))
        let capturer = SuspendingAnnotationSceneCapturer(fingerprint: referenceFingerprint)
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000023")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        let staleSample = Task { await monitor.sampleNow() }
        while capturer.baselineCallCount == 0 { await Task.yield() }
        monitor.suspendImmediately(reason: .display)
        capturer.resumeFirstBaseline()
        await staleSample.value

        #expect(outputs == [.mismatched(identity, .display)])
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.mismatched(identity, .display), .matched(identity)])
        monitor.stop()
    }

    @Test func staleDisplayObserverTaskCannotSuspendAReplacementSession() async throws {
        let referenceFingerprint = try #require(fingerprint(width: 10, height: 10))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(baseline: referenceFingerprint, current: []),
            automaticallySchedulesSamples: true
        )
        let firstIdentity = PickyAnnotationSceneIdentity(
            contextID: "first",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000024")!
        )
        let secondIdentity = PickyAnnotationSceneIdentity(
            contextID: "second",
            generation: 2,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000025")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: firstIdentity, baseline: sceneBaseline(contextID: "first"))

        NotificationCenter.default.post(
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
        monitor.start(identity: secondIdentity, baseline: sceneBaseline(contextID: "second"))
        for _ in 0..<5 { await Task.yield() }

        #expect(outputs.isEmpty)
        monitor.stop()
    }

    @Test func wakeupsCannotCollapseTheVisualConfirmationInterval() async throws {
        let referenceFingerprint = try #require(fingerprint(width: 10, height: 10))
        let capturer = SuspendingAnnotationSceneCapturer(fingerprint: referenceFingerprint)
        let monitor = PickyAnnotationSceneMonitor(
            capturer: capturer,
            automaticallySchedulesSamples: true
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000026")!
        )
        var scheduledDelays: [TimeInterval] = []
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onSampleScheduled = { scheduledDelays.append($0) }
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        while capturer.baselineCallCount == 0 { await Task.yield() }
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)
        capturer.resumeFirstBaseline()
        for _ in 0..<100 where scheduledDelays.last.map({ $0 < 0.29 }) ?? true {
            await Task.yield()
        }

        #expect(scheduledDelays.last.map { $0 >= 0.29 } == true)
        let scheduleCount = scheduledDelays.count
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)
        #expect(scheduledDelays.count == scheduleCount + 1)
        #expect(scheduledDelays.last.map { $0 > 0.20 } == true)
        #expect(outputs.isEmpty)
        monitor.stop()
    }

    private func sceneBaseline(contextID: String) -> PickyAnnotationSceneBaseline {
        PickyAnnotationSceneBaseline(
            contextID: contextID,
            applicationPID: nil,
            applicationBundleID: nil,
            window: nil
        )
    }

    private func screenshot() -> PickyScreenshotContext {
        PickyScreenshotContext(
            id: "shot-1",
            label: "screen",
            path: "/tmp/not-read-by-fake.jpg",
            screenId: "screen1",
            bounds: PickyCGRect(x: 0, y: 0, width: 100, height: 100),
            screenshotWidthInPixels: 100,
            screenshotHeightInPixels: 100
        )
    }

    private func annotation() -> PickyAgentAnnotation {
        PickyAgentAnnotation(
            id: "rect",
            shape: .rect,
            displayFrame: CGRect(x: 0, y: 0, width: 100, height: 100),
            rect: CGRect(x: 40, y: 40, width: 20, height: 20),
            label: nil
        )
    }

    private func fingerprint(width: Int, height: Int) -> PickyAnnotationSceneFingerprint? {
        PickyAnnotationSceneFingerprint(
            width: width,
            height: height,
            luminance: [UInt8](repeating: 64, count: width * height)
        )
    }
}

@MainActor
private final class FakeAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    let baseline: PickyAnnotationSceneFingerprint
    var current: [PickyAnnotationSceneFingerprint]

    init(baseline: PickyAnnotationSceneFingerprint, current: [PickyAnnotationSceneFingerprint]) {
        self.baseline = baseline
        self.current = current
    }

    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        baseline
    }

    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        guard !current.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        return current.removeFirst()
    }

    func reset() {}
}

@MainActor
private final class SuspendingAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    let fingerprint: PickyAnnotationSceneFingerprint
    private var firstBaselineContinuation: CheckedContinuation<PickyAnnotationSceneFingerprint, Never>?
    private(set) var baselineCallCount = 0
    private(set) var resetCount = 0
    private(set) var resetDuringCaptureCount = 0
    private(set) var maximumConcurrentCaptures = 0
    private var concurrentCaptures = 0

    init(fingerprint: PickyAnnotationSceneFingerprint) {
        self.fingerprint = fingerprint
    }

    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        baselineCallCount += 1
        beginCapture()
        defer { endCapture() }
        if baselineCallCount == 1 {
            return await withCheckedContinuation { continuation in
                firstBaselineContinuation = continuation
            }
        }
        return fingerprint
    }

    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        beginCapture()
        defer { endCapture() }
        return fingerprint
    }

    func reset() {
        resetCount += 1
        if concurrentCaptures > 0 {
            resetDuringCaptureCount += 1
        }
    }

    func resumeFirstBaseline() {
        firstBaselineContinuation?.resume(returning: fingerprint)
        firstBaselineContinuation = nil
    }

    private func beginCapture() {
        concurrentCaptures += 1
        maximumConcurrentCaptures = max(maximumConcurrentCaptures, concurrentCaptures)
    }

    private func endCapture() {
        concurrentCaptures -= 1
    }
}

private extension PickyAnnotationSceneDifferenceMetrics {
    static let zero = Self(
        globalChangedFraction: 0,
        globalMeanDifference: 0,
        roiChangedFraction: 0,
        roiMeanDifference: 0
    )
    static let changed = Self(
        globalChangedFraction: 1,
        globalMeanDifference: 255,
        roiChangedFraction: 1,
        roiMeanDifference: 255
    )
    static let ambiguous = Self(
        globalChangedFraction: 0.25,
        globalMeanDifference: 10,
        roiChangedFraction: 0.12,
        roiMeanDifference: 9
    )
}
