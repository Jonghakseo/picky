import AppKit
import CoreGraphics
import Foundation
import ImageIO
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

    @Test func initialValidationSuspendsOnlyAfterTwoConsecutiveScreenTransitionScaleMismatches() {
        let roiOnlyMismatch = PickyAnnotationSceneVisualObservation.mismatching(
            PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 0.20,
                globalMeanDifference: 12,
                roiChangedFraction: 1,
                roiMeanDifference: 120
            )
        )
        var tracker = PickyAnnotationSceneStabilityTracker()
        #expect(tracker.observe(roiOnlyMismatch, phase: .validating) == .none)
        #expect(tracker.observe(roiOnlyMismatch, phase: .validating) == .none)

        let screenTransitionMismatch = PickyAnnotationSceneVisualObservation.mismatching(
            PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 0.70,
                globalMeanDifference: 40,
                roiChangedFraction: 1,
                roiMeanDifference: 120
            )
        )
        #expect(tracker.observe(screenTransitionMismatch, phase: .validating) == .none)
        #expect(tracker.observe(screenTransitionMismatch, phase: .validating) == .suspend)
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

    @Test func visualPolicyKeepsROILocalChangesBelowNarrationInvalidationThresholdIndeterminate() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in [44, 45, 46, 47, 54, 55, 56, 57] { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)],
            invalidationProfile: .lenient
        )

        guard case .indeterminate(let metrics) = observation else {
            Issue.record("Expected a 50% ROI repaint to remain below the narration invalidation threshold")
            return
        }
        #expect(metrics.roiChangedFraction == 0.5)
        #expect(metrics.roiMeanDifference == 9.5)
    }

    @Test func visualPolicyKeepsGlobalChangesBelowNarrationInvalidationThresholdIndeterminate() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in 0..<46 { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [],
            invalidationProfile: .lenient
        )

        guard case .indeterminate(let metrics) = observation else {
            Issue.record("Expected a 46% global repaint to remain below the narration invalidation threshold")
            return
        }
        #expect(metrics.globalChangedFraction == 0.46)
        #expect(metrics.globalMeanDifference == 8.74)
    }

    @Test func semanticProfileDetectsSmallHighResolutionROIChanges() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in 0..<10 { pixels[index] = 100 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [],
            invalidationProfile: .semantic
        )

        guard case .mismatching = observation else {
            Issue.record("Expected a semantic high-resolution comparison to reject a 10% ROI change")
            return
        }
    }

    @Test func visualPolicyInvalidatesROIFractionChangesAfterNarrationEnds() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in [44, 45, 46, 47, 54, 55, 56, 57] { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)],
            invalidationProfile: .strict
        )

        guard case .mismatching = observation else {
            Issue.record("Expected a 50% ROI repaint to invalidate after narration ends")
            return
        }
    }

    @Test func visualPolicyInvalidatesGlobalFractionChangesAfterNarrationEnds() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in 0..<46 { pixels[index] = 83 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [],
            invalidationProfile: .strict
        )

        guard case .mismatching = observation else {
            Issue.record("Expected a 46% global repaint to invalidate after narration ends")
            return
        }
    }

    @Test func visualPolicyInvalidatesROIMeanDifferenceAfterNarrationEnds() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in [44, 45, 54, 55] { pixels[index] = 164 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let lenient = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)],
            invalidationProfile: .lenient
        )
        let strict = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.4, width: 0.4, height: 0.4)],
            invalidationProfile: .strict
        )

        guard case .indeterminate = lenient else {
            Issue.record("Expected a 25-point ROI mean difference to remain tolerated during narration")
            return
        }
        guard case .mismatching = strict else {
            Issue.record("Expected a 25-point ROI mean difference to invalidate after narration ends")
            return
        }
    }

    @Test func visualPolicyInvalidatesGlobalMeanDifferenceAfterNarrationEnds() throws {
        let baseline = try #require(fingerprint(width: 10, height: 10))
        var pixels = baseline.luminance
        for index in 0..<12 { pixels[index] = 240 }
        let current = try #require(PickyAnnotationSceneFingerprint(width: 10, height: 10, luminance: pixels))

        let lenient = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [],
            invalidationProfile: .lenient
        )
        let strict = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [],
            invalidationProfile: .strict
        )

        guard case .indeterminate = lenient else {
            Issue.record("Expected a 21-point global mean difference to remain tolerated during narration")
            return
        }
        guard case .mismatching = strict else {
            Issue.record("Expected a 21-point global mean difference to invalidate after narration ends")
            return
        }
    }

    @Test func structuralRestoreMatchesWhenBannerOrVideoBandDrifts() throws {
        let baseline = try #require(structuredFingerprint(width: 12, height: 12))
        let width = baseline.width
        let height = baseline.height

        let centralBand = try #require(fingerprint(width: width, height: height) { pixels, _, _ in
            let bandHeight = max(1, height / 3)
            let bandWidth = max(1, width / 2)
            let bandX = (width - bandWidth) / 2
            let bandY = (height - bandHeight) / 2

            for y in bandY..<min(height, bandY + bandHeight) {
                let rowOffset = y * width
                for x in bandX..<min(width, bandX + bandWidth) {
                    let index = rowOffset + x
                    let boosted = Int(baseline.luminance[index]) + 30
                    pixels[index] = UInt8(min(255, boosted))
                }
            }
        })
        let current = withCenterRegion(baseline, replacedBy: centralBand)

        let annotationOnPeriphery = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.02, y: 0.02, width: 0.16, height: 0.2)]
        )

        guard case .matching = annotationOnPeriphery else {
            Issue.record("Expected banner-like center band movement to keep annotation restore matched")
            return
        }
    }

    @Test func structuralRestoreMatchesForVideoStyleCenterBandChurn() throws {
        let baseline = try #require(structuredFingerprint(width: 12, height: 12))
        let width = baseline.width
        let height = baseline.height

        let churnedCenter = try #require(fingerprint(width: width, height: height) { pixels, _, _ in
            let bandHeight = max(1, height / 3)
            let bandWidth = max(1, width / 2)
            let bandX = (width - bandWidth) / 2
            let bandY = (height - bandHeight) / 2

            for y in bandY..<min(height, bandY + bandHeight) {
                let rowOffset = y * width
                for x in bandX..<min(width, bandX + bandWidth) {
                    let index = rowOffset + x
                    let phase = ((x + y) & 1)
                    let boost = 34 + (phase % 2)
                    let boosted = Int(baseline.luminance[index]) + boost
                    pixels[index] = UInt8(min(255, boosted))
                }
            }
        })
        let current = withCenterRegion(baseline, replacedBy: churnedCenter)

        let annotationInStableChrome = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.02, y: 0.02, width: 0.16, height: 0.2)]
        )

        guard case .matching = annotationInStableChrome else {
            Issue.record("Expected a central video-band churn to keep restore eligible")
            return
        }
    }

    @Test func structuralRestoreRejectsStructureLossThatLuminanceWouldNotReject() throws {
        // Dense vertical texture (an edge at every column) versus a flat repaint at the same
        // mean. Per-pixel luminance change stays below the strict mismatch thresholds, so the
        // luminance policy alone would NOT reject this frame; only the structural gate catches
        // that the layout structure disappeared. This is the tone-similar regression the
        // feature exists to fix, isolated from the luminance mismatch path.
        let baseline = try #require(fingerprint(width: 12, height: 12) { pixels, width, height in
            for y in 0..<height {
                for x in 0..<width where x % 2 == 0 {
                    pixels[y * width + x] = 90
                }
            }
        })
        let flatRepaint = try #require(fingerprint(width: 12, height: 12, baseValue: 77))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: flatRepaint,
            normalizedRegions: []
        )

        guard case .mismatching(let metrics) = observation else {
            Issue.record("Expected structural analysis to reject a same-tone frame that lost its layout structure")
            return
        }
        // Prove the luminance policy alone would not have rejected this: both global metrics
        // sit below the strict luminance mismatch thresholds, so the structural gate drove it.
        #expect(metrics.globalChangedFraction == 0)
        #expect(metrics.globalMeanDifference == 13)
        #expect(metrics.globalChangedFraction < PickyAnnotationSceneInvalidationProfile.strict.mismatchingGlobalChangedFraction)
        #expect(metrics.globalMeanDifference < PickyAnnotationSceneInvalidationProfile.strict.mismatchingGlobalMeanDifference)
    }

    @Test func structuralRestoreRejectsNoisyCentralDriftUnderAnnotationAnchor() throws {
        let baseline = try #require(structuredFingerprint(width: 12, height: 12))
        var pixels = baseline.luminance
        let width = baseline.width
        let height = baseline.height
        let changeX = width / 2
        let changeY = height / 2
        // A meaningful content change under the anchor (beyond the bounded localized-drift
        // allowance, yet below a hard luminance mismatch) must reject structural restoration.
        for offsetX in -1...1 {
            let index = changeY * width + (changeX + offsetX)
            pixels[index] = UInt8(max(0, Int(pixels[index]) - 80))
        }
        let current = try #require(PickyAnnotationSceneFingerprint(width: width, height: height, luminance: pixels))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [CGRect(x: 0.4, y: 0.35, width: 0.2, height: 0.2)]
        )

        guard case .mismatching = observation else {
            Issue.record("Expected anchor-on-change to break structural restoration")
            return
        }
    }

    @Test func structuralRestoreKeepsUnchangedFlatRegionsStable() throws {
        let baseline = try #require(fingerprint(width: 12, height: 12, baseValue: 64))
        let current = try #require(fingerprint(width: 12, height: 12, baseValue: 64))

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: []
        )

        guard case .matching = observation else {
            Issue.record("Expected flat identical regions to stay matched")
            return
        }
    }

    @Test func structuralRestoreRespectsTwoConsecutiveTrackerGuardAcrossSingleNoisyFrame() throws {
        let baseline = try #require(structuredFingerprint(width: 12, height: 12))
        let noisyCurrent = sameMeanDifferentLayout(baseline)
        let stableObservation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: baseline,
            normalizedRegions: []
        )
        let noisyObservation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: noisyCurrent,
            normalizedRegions: []
        )

        guard case .matching = stableObservation else {
            Issue.record("Expected baseline-to-baseline comparison to remain matching")
            return
        }
        guard case .mismatching = noisyObservation else {
            Issue.record("Expected the noisy frame to be mismatching")
            return
        }

        var tracker = PickyAnnotationSceneStabilityTracker()
        #expect(tracker.observe(stableObservation, phase: .suspended) == .none)
        #expect(tracker.observe(noisyObservation, phase: .suspended) == .none)
        #expect(tracker.observe(stableObservation, phase: .suspended) == .none)
        #expect(tracker.observe(stableObservation, phase: .suspended) == .show)
    }

    @Test func structuralRestoreRejectsToneSimilarLayoutMoveAtProductionResolution() throws {
        // Production-sized fingerprint (real multi-pixel grid cells, not the degenerate 1px
        // cells of the small fixtures). A text-like block on a light page moves to a different,
        // non-overlapping location while keeping the same background tone and contrast. Global
        // luminance stays below the strict mismatch thresholds, so only the structural gate
        // rejects this tone-similar different layout.
        let width = 256
        let height = 144
        func drawTextBlock(_ pixels: inout [UInt8], _ w: Int, originX: Int, originY: Int) {
            for line in 0..<10 {
                let y = originY + line * 5
                guard y + 2 <= height else { break }
                for yy in y..<(y + 2) {
                    for x in originX..<min(width, originX + 80) {
                        pixels[yy * w + x] = 90
                    }
                }
            }
        }
        let baseline = try #require(fingerprint(width: width, height: height, baseValue: 220) { pixels, w, _ in
            drawTextBlock(&pixels, w, originX: 16, originY: 16)
        })
        let moved = try #require(fingerprint(width: width, height: height, baseValue: 220) { pixels, w, _ in
            drawTextBlock(&pixels, w, originX: 160, originY: 84)
        })

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: moved,
            normalizedRegions: []
        )

        guard case .mismatching(let metrics) = observation else {
            Issue.record("Expected a moved layout at production resolution to be rejected")
            return
        }
        #expect(metrics.globalChangedFraction < PickyAnnotationSceneInvalidationProfile.strict.mismatchingGlobalChangedFraction)
        #expect(metrics.globalMeanDifference < PickyAnnotationSceneInvalidationProfile.strict.mismatchingGlobalMeanDifference)
    }

    @Test func structuralRestoreMatchesBannerChurnAtProductionResolution() throws {
        // Stable window chrome (top bar + sidebar) at the periphery with churning center content,
        // at real cell sizes. The periphery structure persists, so the scene stays matched even
        // though the center band's structure changes (banner/video tolerance).
        let width = 256
        let height = 144
        func drawChrome(_ pixels: inout [UInt8], _ w: Int) {
            for y in 0..<18 where y < height { for x in 0..<width { pixels[y * w + x] = 120 } }
            for y in 18..<height { for x in 0..<48 { pixels[y * w + x] = 100 } }
        }
        let baseline = try #require(fingerprint(width: width, height: height, baseValue: 210) { pixels, w, _ in
            drawChrome(&pixels, w)
            for y in 52..<96 { for x in 104..<176 where (x / 8) % 2 == 0 { pixels[y * w + x] = 150 } }
        })
        let churned = try #require(fingerprint(width: width, height: height, baseValue: 210) { pixels, w, _ in
            drawChrome(&pixels, w)
            for y in 52..<96 { for x in 104..<176 where (y / 8) % 2 == 0 { pixels[y * w + x] = 150 } }
        })

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: churned,
            normalizedRegions: []
        )

        guard case .matching = observation else {
            Issue.record("Expected stable chrome with churning center content to keep matching")
            return
        }
    }

    @Test func structuralRestoreBreaksWhenOneOfSeveralAnchorsChangesBeyondDrift() throws {
        // Two annotations on one screen. Only the first anchor's content changes (beyond the
        // bounded drift allowance); the second is untouched. Per-region evaluation must break
        // the scene instead of averaging the change away across both regions.
        let width = 256
        let height = 144
        let regionA = CGRect(x: 0.08, y: 0.12, width: 0.24, height: 0.30)
        let regionB = CGRect(x: 0.68, y: 0.60, width: 0.24, height: 0.30)
        func drawAnchors(_ pixels: inout [UInt8], _ w: Int, changeA: Bool) {
            for y in 20..<58 { for x in 24..<80 where (x / 6) % 2 == 0 { pixels[y * w + x] = changeA ? 215 : 90 } }
            for y in 90..<128 { for x in 180..<236 where (x / 6) % 2 == 0 { pixels[y * w + x] = 90 } }
        }
        let baseline = try #require(fingerprint(width: width, height: height, baseValue: 220) { pixels, w, _ in
            drawAnchors(&pixels, w, changeA: false)
        })
        let current = try #require(fingerprint(width: width, height: height, baseValue: 220) { pixels, w, _ in
            drawAnchors(&pixels, w, changeA: true)
        })

        let observation = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: current,
            normalizedRegions: [regionA, regionB]
        )

        guard case .mismatching = observation else {
            Issue.record("Expected one changed anchor among several to break the scene without dilution")
            return
        }
    }

    @Test func structuralRestoreKeepsAnnotationWhenOnlyHeroBannerRotates() throws {
        // Two real captures of the same creatrip page where only the center hero-carousel banner
        // rotated (BIAS/MONSTA X -> K-Trekking). Chrome, nav, search box, and footer are identical.
        // The whole-frame tone shift is large (mean luminance difference ~30), which the coarse
        // global luminance mismatch alone would reject; the surrounding structure still identifies
        // the same screen, so the annotation is kept as long as its anchor is not on the banner.
        let baseline = try fixtureFingerprint("creatrip-banner-bias")
        let rotated = try fixtureFingerprint("creatrip-banner-trekking")

        // Anchored on the stable search box below the banner -> keep.
        let onSearchBox = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: rotated,
            normalizedRegions: [CGRect(x: 0.30, y: 0.72, width: 0.40, height: 0.16)]
        )
        guard case .matching = onSearchBox else {
            Issue.record("Expected a rotating hero banner over identical chrome to keep the annotation")
            return
        }

        // Anchored directly on the changed banner graphic -> break.
        let onBanner = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: rotated,
            normalizedRegions: [CGRect(x: 0.45, y: 0.30, width: 0.35, height: 0.22)]
        )
        guard case .mismatching = onBanner else {
            Issue.record("Expected an annotation anchored on the changed banner to break")
            return
        }
    }

    @Test func structuralRestoreKeepsAnnotationOnStableSidebarWhileVideoPlays() throws {
        // Two real captures of the same YouTube watch page while the video plays: the player fills
        // most of the screen and its content changes completely (news graphic -> on-scene
        // reporter), but the right related-videos sidebar and page chrome are identical. Because
        // the video dominates the frame, global structural persistence alone is ambiguous; the
        // annotation is kept only because its own anchor (the sidebar) is unchanged, and it breaks
        // when anchored on the video itself.
        let baseline = try fixtureFingerprint("youtube-news-graphic")
        let laterFrame = try fixtureFingerprint("youtube-news-interview")

        // Anchored on the unchanged related-videos sidebar -> keep.
        let onSidebar = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: laterFrame,
            normalizedRegions: [CGRect(x: 0.75, y: 0.20, width: 0.20, height: 0.35)]
        )
        guard case .matching = onSidebar else {
            Issue.record("Expected an annotation on the unchanged sidebar to survive video playback")
            return
        }

        // Anchored on the changing video player -> break.
        let onVideo = PickyAnnotationSceneVisualPolicy.compare(
            baseline: baseline,
            current: laterFrame,
            normalizedRegions: [CGRect(x: 0.15, y: 0.30, width: 0.35, height: 0.30)]
        )
        guard case .mismatching = onVideo else {
            Issue.record("Expected an annotation anchored on the changing video to break")
            return
        }
    }

    @Test func edgeMapForUniformFingerprintIsAllZeros() throws {
        let uniform = try #require(fingerprint(width: 16, height: 12))

        #expect(uniform.dilatedEdgeMask.allSatisfy { $0 == 0 })
    }

    @Test func edgeMapFromSingleVerticalLineContainsOnlyTheLineAndDilatedBand() throws {
        let width = 10
        let height = 10
        let lineX = 4
        var luminance = [UInt8](repeating: 64, count: width * height)
        for y in 0..<height {
            luminance[y * width + lineX] = 192
        }
        let fingerprint = try #require(PickyAnnotationSceneFingerprint(width: width, height: height, luminance: luminance))

        let expectedColumns: Set<Int> = [lineX - 2, lineX - 1, lineX, lineX + 1]
        for y in 0..<height {
            for x in 0..<width {
                let value = fingerprint.dilatedEdgeMask[y * width + x]
                if expectedColumns.contains(x) {
                    #expect(value == 1)
                } else {
                    #expect(value == 0)
                }
            }
        }
    }

    @Test func edgeMapIsDerivedFromLuminanceOnly() throws {
        let width = 10
        let height = 10
        var luminance = [UInt8](repeating: 64, count: width * height)
        for y in 0..<height {
            luminance[y * width + 5] = 220
        }
        let directlyBuilt = try #require(PickyAnnotationSceneFingerprint(width: width, height: height, luminance: luminance))

        // Simulate a persisted baseline that only stores luminance and rehydrates the edge mask.
        let rehydrated = try #require(PickyAnnotationSceneFingerprint(width: width, height: height, luminance: directlyBuilt.luminance))

        #expect(directlyBuilt.dilatedEdgeMask == rehydrated.dilatedEdgeMask)
    }

    @Test func edgeMapDilationAbsorbsOnePixelLineShift() throws {
        let width = 9
        let height = 9
        let baseLineX = 3
        let shiftedLineX = baseLineX + 1

        let baseLine = try #require(fingerprint(
            width: width,
            height: height,
            baseValue: 64,
            variant: { pixels, strideWidth, strideHeight in
                for y in 0..<strideHeight {
                    pixels[y * strideWidth + baseLineX] = 220
                }
            }
        ))
        let shiftedLine = try #require(fingerprint(
            width: width,
            height: height,
            baseValue: 64,
            variant: { pixels, strideWidth, strideHeight in
                for y in 0..<strideHeight {
                    pixels[y * strideWidth + shiftedLineX] = 220
                }
            }
        ))

        for y in 0..<height {
            let baseEdgeIndex = y * width + shiftedLineX
            #expect(baseLine.dilatedEdgeMask[baseEdgeIndex] == 1)
            #expect(shiftedLine.dilatedEdgeMask[baseEdgeIndex] == 1)
        }
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
            .agentAnnotationSceneMismatched(identity: identity, reason: .validationTimeout),
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

    @Test func semanticROIChangeSuspendsImmediatelyForApplicationSwitches() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let changedFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        ))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [],
                regionCurrent: [changedFingerprint]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000101")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)
        monitor.setNarrationActive(true)

        await monitor.verifyRegionsAfterSemanticSignalNow(identity: identity, reason: .application)

        #expect(outputs == [.mismatched(identity, .application)])
        monitor.stop()
    }

    @Test func semanticROIComparisonKeepsAnnotationsWhenScrollDoesNotMoveTheirAnchor() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [],
                regionCurrent: [baselineFingerprint]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000111")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [annotation()], mode: .append)

        await monitor.verifyRegionsAfterSemanticSignalNow(identity: identity, reason: .scroll)

        #expect(outputs.isEmpty)
        monitor.stop()
    }

    @Test func hidingTheBaselineApplicationHardClearsWithoutCapturing() {
        let monitor = PickyAnnotationSceneMonitor(automaticallySchedulesSamples: false)
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000112")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(
            identity: identity,
            baseline: PickyAnnotationSceneBaseline(
                contextID: "context",
                applicationPID: 101,
                applicationBundleID: "com.example.source",
                window: nil
            )
        )

        monitor.handleHiddenApplication(identity: identity, applicationPID: 101)

        #expect(outputs == [.mismatched(identity, .application)])
        monitor.stop()
    }

    @Test func monitorIgnoresPickyApplicationActivation() {
        let monitor = PickyAnnotationSceneMonitor(automaticallySchedulesSamples: false)
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000102")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(
            identity: identity,
            baseline: PickyAnnotationSceneBaseline(
                contextID: "context",
                applicationPID: 101,
                applicationBundleID: "com.example.source",
                window: nil
            )
        )

        monitor.handleActivatedApplication(
            identity: identity,
            applicationPID: ProcessInfo.processInfo.processIdentifier,
            applicationBundleID: "com.example.picky"
        )

        #expect(outputs.isEmpty)
        monitor.stop()
    }

    @Test func focusedWindowSignalsDoNotClearWithoutAChangedROI() {
        let monitor = PickyAnnotationSceneMonitor(automaticallySchedulesSamples: false)
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 1,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000103")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))

        monitor.handleFocusedWindowChange(identity: identity, focusedWindow: nil)

        #expect(outputs.isEmpty)
        monitor.stop()
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

    @Test func monitorUsesLenientInvalidationOnlyWhileNarrationIsActive() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        var changedPixels = baselineFingerprint.luminance
        for index in 0..<46 { changedPixels[index] = 83 }
        let changedFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: changedPixels
        ))
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [
                    baselineFingerprint, baselineFingerprint,
                    changedFingerprint, changedFingerprint,
                    changedFingerprint, changedFingerprint,
                ]
            ),
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 9,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000009")!
        )
        var outputs: [PickyAnnotationSceneMonitorOutput] = []
        monitor.onOutput = { outputs.append($0) }
        monitor.start(identity: identity, baseline: sceneBaseline(contextID: "context"))
        monitor.updateTarget(screenshot: screenshot(), annotations: [], mode: .append)

        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        monitor.setNarrationActive(true)
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity)])

        monitor.setNarrationActive(false)
        await monitor.sampleNow()
        await monitor.sampleNow()
        #expect(outputs == [.matched(identity), .mismatched(identity, .visual)])
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

    @Test func monitorFailsOpenWhenInitialValidationExpiresWithoutHardMismatch() async throws {
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
        #expect(outputs == [.matched(identity)])
        monitor.stop()
    }

    @Test func monitorKeepsInitialValidationSuspendedAfterAnObservedHardMismatch() async throws {
        let baselineFingerprint = try #require(fingerprint(width: 10, height: 10))
        let changedFingerprint = try #require(PickyAnnotationSceneFingerprint(
            width: 10,
            height: 10,
            luminance: [UInt8](repeating: 255, count: 100)
        ))
        var currentTime = Date(timeIntervalSinceReferenceDate: 0)
        let monitor = PickyAnnotationSceneMonitor(
            capturer: FakeAnnotationSceneCapturer(
                baseline: baselineFingerprint,
                current: [changedFingerprint]
            ),
            now: { currentTime },
            automaticallySchedulesSamples: false
        )
        let identity = PickyAnnotationSceneIdentity(
            contextID: "context",
            generation: 8,
            token: UUID(uuidString: "A0000000-0000-0000-0000-000000000008")!
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

    private func structuredFingerprint(
        width: Int,
        height: Int,
        draw: (_ pixels: inout [UInt8], _ width: Int, _ height: Int) -> Void = { pixels, width, height in
            let background = UInt8(64)
            let topBarHeight = max(1, height / 8)
            let sidebarWidth = max(1, width / 4)
            let dividerX = max(0, sidebarWidth - 1)

            for y in 0..<topBarHeight {
                for x in 0..<width {
                    pixels[y * width + x] = 106
                }
            }
            for y in topBarHeight..<height {
                for x in 0..<sidebarWidth {
                    pixels[y * width + x] = 84
                }
            }
            for y in 0..<height {
                pixels[y * width + dividerX] = 132
            }

            let blockWidth = max(1, (width - sidebarWidth) / 3)
            let blockHeight = max(1, (height - topBarHeight) / 3)
            let leftBlockX = sidebarWidth + 1
            let leftBlockY = topBarHeight + 1
            for y in leftBlockY..<min(height, leftBlockY + blockHeight) {
                for x in leftBlockX..<min(width, leftBlockX + blockWidth) {
                    pixels[y * width + x] = 118
                }
            }

            let rightBlockX = width - blockWidth - 1
            let rightBlockY = max(topBarHeight + 1, height - blockHeight - 1)
            for y in rightBlockY..<min(height, rightBlockY + blockHeight) {
                for x in rightBlockX..<width {
                    if x >= 0 { pixels[y * width + x] = 132 }
                }
            }

            for x in stride(from: sidebarWidth + 2, through: min(width - 1, sidebarWidth + blockWidth - 1), by: 2) {
                for y in leftBlockY..<height {
                    pixels[y * width + x] = 118
                }
            }

            for y in stride(from: leftBlockY + 1, to: min(height, leftBlockY + blockHeight + 1), by: 2) {
                for x in leftBlockX..<min(width, leftBlockX + blockWidth) {
                    pixels[y * width + x] = 104
                }
            }

            for x in 0..<width {
                let horizontalY = min(height - 1, topBarHeight + blockHeight)
                pixels[horizontalY * width + x] = background
            }

            for y in topBarHeight..<min(height, topBarHeight + 2) {
                for x in (sidebarWidth + 1)..<width {
                    pixels[y * width + x] = background
                }
            }

            for y in 0..<height {
                pixels[y * width + (width - 1)] = 84
            }
        }
    ) -> PickyAnnotationSceneFingerprint? {
        fingerprint(width: width, height: height, baseValue: 64, variant: draw)
    }

    private func withCenterRegion(
        _ baseline: PickyAnnotationSceneFingerprint,
        replacedBy replacement: PickyAnnotationSceneFingerprint
    ) -> PickyAnnotationSceneFingerprint {
        guard baseline.width == replacement.width,
              baseline.height == replacement.height else { return baseline }

        var luminance = baseline.luminance
        let width = baseline.width
        let height = baseline.height
        let bandHeight = max(1, height / 3)
        let bandWidth = max(1, width / 2)
        let bandX = (width - bandWidth) / 2
        let bandY = (height - bandHeight) / 2

        for y in bandY..<min(height, bandY + bandHeight) {
            let rowOffset = y * width
            for x in bandX..<min(width, bandX + bandWidth) {
                luminance[rowOffset + x] = replacement.luminance[rowOffset + x]
            }
        }

        return PickyAnnotationSceneFingerprint(
            width: width,
            height: height,
            luminance: luminance
        )!
    }

    private func sameMeanDifferentLayout(_ base: PickyAnnotationSceneFingerprint) -> PickyAnnotationSceneFingerprint {
        let width = base.width
        let height = base.height
        let pixelCount = width * height
        let totalLuminance = base.luminance.reduce(0) { $0 + Int($1) }
        let baseValue = totalLuminance / pixelCount
        let delta = min(30, max(1, min(baseValue, 255 - baseValue)))
        let highValue = UInt8(min(255, baseValue + delta))
        let lowValue = UInt8(max(0, baseValue - delta))

        var luminance = [UInt8](repeating: UInt8(baseValue), count: pixelCount)
        let blockHeight = max(1, height / 4)
        let blockWidth = max(1, width / 3)

        let leftBlockX = max(0, width / 5)
        let leftBlockY = height / 6
        let rightBlockX = max(0, width - width / 5 - blockWidth)
        let rightBlockY = max(0, height - height / 6 - blockHeight)

        for y in leftBlockY..<min(height, leftBlockY + blockHeight) {
            let offset = y * width
            for x in leftBlockX..<min(width, leftBlockX + blockWidth) {
                luminance[offset + x] = highValue
            }
        }
        for y in rightBlockY..<min(height, rightBlockY + blockHeight) {
            let offset = y * width
            for x in rightBlockX..<min(width, rightBlockX + blockWidth) {
                luminance[offset + x] = lowValue
            }
        }

        let dividerTop = max(0, height / 2 - 1)
        let dividerBottom = min(height - 1, dividerTop + 1)
        for y in dividerTop...dividerBottom {
            for x in width / 3..<(width / 3 + blockWidth / 2) {
                luminance[y * width + x] = highValue
            }
            for x in (width - width / 3 - blockWidth / 2) ..< (width - width / 3) {
                if x >= 0 {
                    luminance[y * width + x] = lowValue
                }
            }
        }

        return PickyAnnotationSceneFingerprint(width: width, height: height, luminance: luminance)!
    }

    /// Loads a real screenshot fixture from PickyTests/Fixtures and reduces it through the same
    /// resample + edge-mask pipeline the live capturer uses, at the annotation fingerprint size.
    private func fixtureFingerprint(_ name: String) throws -> PickyAnnotationSceneFingerprint {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(name)
            .appendingPathExtension("png")
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return try #require(PickyAnnotationSceneFingerprint.make(from: image, width: 256, height: 144))
    }

    private func fingerprint(width: Int, height: Int, baseValue: UInt8 = 64, variant: (
        _ pixels: inout [UInt8],
        _ width: Int,
        _ height: Int
    ) -> Void = { _, _, _ in }) -> PickyAnnotationSceneFingerprint? {
        var luminance = [UInt8](repeating: baseValue, count: width * height)
        variant(&luminance, width, height)
        return PickyAnnotationSceneFingerprint(
            width: width,
            height: height,
            luminance: luminance
        )
    }
}

@MainActor
private final class FakeAnnotationSceneCapturer: PickyAnnotationSceneSnapshotCapturing {
    let baseline: PickyAnnotationSceneFingerprint
    var current: [PickyAnnotationSceneFingerprint]
    let regionBaseline: PickyAnnotationSceneFingerprint
    var regionCurrent: [PickyAnnotationSceneFingerprint]

    init(
        baseline: PickyAnnotationSceneFingerprint,
        current: [PickyAnnotationSceneFingerprint],
        regionBaseline: PickyAnnotationSceneFingerprint? = nil,
        regionCurrent: [PickyAnnotationSceneFingerprint] = []
    ) {
        self.baseline = baseline
        self.current = current
        self.regionBaseline = regionBaseline ?? baseline
        self.regionCurrent = regionCurrent
    }

    func baselineFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        baseline
    }

    func currentFingerprint(for screenshot: PickyScreenshotContext) async throws -> PickyAnnotationSceneFingerprint {
        guard !current.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        return current.removeFirst()
    }

    func baselineRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        regionBaseline
    }

    func currentRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        guard !regionCurrent.isEmpty else { throw PickyAnnotationSceneCaptureError.fingerprintCreationFailed }
        return regionCurrent.removeFirst()
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

    func baselineRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
        fingerprint
    }

    func currentRegionFingerprint(
        for screenshot: PickyScreenshotContext,
        normalizedRegion: CGRect
    ) async throws -> PickyAnnotationSceneFingerprint {
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
