import CoreGraphics
import Foundation

struct PickyAnnotationSceneIdentity: Equatable, Codable, Sendable {
    let contextID: String
    let generation: Int
    let token: UUID
}

enum PickyAnnotationScenePhase: String, Equatable, Codable, Sendable {
    case inactive
    case validating
    case visible
    case suspended

    var presentsAnnotations: Bool {
        self == .inactive || self == .visible
    }
}

enum PickyAnnotationSceneMismatchReason: String, Equatable, Codable, Sendable {
    case application
    case window
    case scroll
    case display
    case visual
}

enum PickyAnnotationSceneVisualObservation: Equatable, Sendable {
    case matching(PickyAnnotationSceneDifferenceMetrics)
    case mismatching(PickyAnnotationSceneDifferenceMetrics)
    case indeterminate(PickyAnnotationSceneDifferenceMetrics)
}

struct PickyAnnotationSceneDifferenceMetrics: Equatable, Sendable {
    let globalChangedFraction: Double
    let globalMeanDifference: Double
    let roiChangedFraction: Double?
    let roiMeanDifference: Double?
}

struct PickyAnnotationSceneFingerprint: Equatable, Sendable {
    let width: Int
    let height: Int
    let luminance: [UInt8]

    init?(width: Int, height: Int, luminance: [UInt8]) {
        guard width > 0, height > 0, luminance.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.luminance = luminance
    }
}

enum PickyAnnotationSceneVisualPolicy {
    /// Per-pixel luminance noise below this value is ignored. This absorbs JPEG,
    /// color-management, and subpixel rendering differences without hiding real UI changes.
    static let changedPixelThreshold = 18

    /// A strict threshold is used to prove restoration; a looser one is used to prove
    /// invalidation. Values in between are deliberately indeterminate to prevent flicker.
    static let matchingROIChangedFraction = 0.08
    static let matchingROIMeanDifference = 7.0
    /// Initial reveal allowance for transient highlight/color drift. Kept well below
    /// hard mismatch so localized content changes still block stale geometry.
    static let initialValidationROIChangedFraction = 0.20
    static let initialValidationROIMeanDifference = 12.0
    /// ROI invalidation is intentionally forgiving: a light scroll, cursor-adjacent
    /// hover repaint, or small content update should keep the drawing on screen.
    /// Only a substantial change to the pointed-at region (large occlusion, a real
    /// scroll that moves the target away) crosses these thresholds.
    static let mismatchingROIChangedFraction = 0.55
    static let mismatchingROIMeanDifference = 32.0
    static let matchingGlobalChangedFraction = 0.18
    static let matchingGlobalMeanDifference = 8.0
    static let mismatchingGlobalChangedFraction = 0.48
    static let mismatchingGlobalMeanDifference = 26.0

    static func compare(
        baseline: PickyAnnotationSceneFingerprint,
        current: PickyAnnotationSceneFingerprint,
        normalizedRegions: [CGRect]
    ) -> PickyAnnotationSceneVisualObservation {
        guard baseline.width == current.width,
              baseline.height == current.height,
              baseline.luminance.count == current.luminance.count else {
            let metrics = PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 1,
                globalMeanDifference: 255,
                roiChangedFraction: normalizedRegions.isEmpty ? nil : 1,
                roiMeanDifference: normalizedRegions.isEmpty ? nil : 255
            )
            return .mismatching(metrics)
        }

        let regionIndexes = pixelIndexes(
            normalizedRegions: normalizedRegions,
            width: baseline.width,
            height: baseline.height
        )
        let global = difference(
            baseline: baseline.luminance,
            current: current.luminance,
            indexes: nil
        )
        let roi = regionIndexes.isEmpty
            ? nil
            : difference(
                baseline: baseline.luminance,
                current: current.luminance,
                indexes: regionIndexes
            )
        let metrics = PickyAnnotationSceneDifferenceMetrics(
            globalChangedFraction: global.changedFraction,
            globalMeanDifference: global.meanDifference,
            roiChangedFraction: roi?.changedFraction,
            roiMeanDifference: roi?.meanDifference
        )

        let roiMismatches = roi.map {
            $0.changedFraction >= mismatchingROIChangedFraction
                || $0.meanDifference >= mismatchingROIMeanDifference
        } ?? false
        let globalMismatches = global.changedFraction >= mismatchingGlobalChangedFraction
            || global.meanDifference >= mismatchingGlobalMeanDifference
        if roiMismatches || globalMismatches {
            return .mismatching(metrics)
        }

        let roiMatches = roi.map {
            $0.changedFraction <= matchingROIChangedFraction
                && $0.meanDifference <= matchingROIMeanDifference
        } ?? true
        let globalMatches = global.changedFraction <= matchingGlobalChangedFraction
            && global.meanDifference <= matchingGlobalMeanDifference
        if roiMatches && globalMatches {
            return .matching(metrics)
        }
        return .indeterminate(metrics)
    }

    /// Initial reveal and narration-time restoration can tolerate bounded localized
    /// color/highlight drift when the desktop structure still matches globally.
    static func canValidateInitialScene(_ metrics: PickyAnnotationSceneDifferenceMetrics) -> Bool {
        guard let roiChangedFraction = metrics.roiChangedFraction,
              let roiMeanDifference = metrics.roiMeanDifference else { return false }
        let globalMatches = metrics.globalChangedFraction <= matchingGlobalChangedFraction
            && metrics.globalMeanDifference <= matchingGlobalMeanDifference
        let roiWithinInitialAllowance = roiChangedFraction <= initialValidationROIChangedFraction
            && roiMeanDifference <= initialValidationROIMeanDifference
        return globalMatches && roiWithinInitialAllowance
    }

    private static func difference(
        baseline: [UInt8],
        current: [UInt8],
        indexes: Set<Int>?
    ) -> (changedFraction: Double, meanDifference: Double) {
        let count = indexes?.count ?? baseline.count
        guard count > 0 else { return (0, 0) }
        var changed = 0
        var totalDifference = 0
        if let indexes {
            for index in indexes {
                let delta = abs(Int(baseline[index]) - Int(current[index]))
                totalDifference += delta
                if delta >= changedPixelThreshold { changed += 1 }
            }
        } else {
            for index in baseline.indices {
                let delta = abs(Int(baseline[index]) - Int(current[index]))
                totalDifference += delta
                if delta >= changedPixelThreshold { changed += 1 }
            }
        }
        return (
            changedFraction: Double(changed) / Double(count),
            meanDifference: Double(totalDifference) / Double(count)
        )
    }

    private static func pixelIndexes(
        normalizedRegions: [CGRect],
        width: Int,
        height: Int
    ) -> Set<Int> {
        guard !normalizedRegions.isEmpty else { return [] }
        var result: Set<Int> = []
        for rawRegion in normalizedRegions {
            let region = rawRegion.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, !region.isEmpty else { continue }
            let minX = max(0, min(width - 1, Int(floor(region.minX * CGFloat(width)))))
            let maxX = max(minX, min(width - 1, Int(ceil(region.maxX * CGFloat(width))) - 1))
            let minY = max(0, min(height - 1, Int(floor(region.minY * CGFloat(height)))))
            let maxY = max(minY, min(height - 1, Int(ceil(region.maxY * CGFloat(height))) - 1))
            for y in minY...maxY {
                for x in minX...maxX {
                    result.insert(y * width + x)
                }
            }
        }
        return result
    }
}

enum PickyAnnotationSceneStabilityDecision: Equatable, Sendable {
    case none
    case show
    case suspend
}

struct PickyAnnotationSceneStabilityTracker: Equatable, Sendable {
    static let requiredConsecutiveObservations = 2

    private(set) var consecutiveMatches = 0
    private(set) var consecutiveMismatches = 0

    mutating func observe(
        _ observation: PickyAnnotationSceneVisualObservation,
        phase: PickyAnnotationScenePhase,
        allowsTolerantRestoration: Bool = false
    ) -> PickyAnnotationSceneStabilityDecision {
        switch observation {
        case .matching:
            consecutiveMatches += 1
            consecutiveMismatches = 0
            guard phase == .validating || phase == .suspended,
                  consecutiveMatches >= Self.requiredConsecutiveObservations else {
                return .none
            }
            reset()
            return .show
        case .mismatching:
            consecutiveMismatches += 1
            consecutiveMatches = 0
            guard (phase == .visible || phase == .validating),
                  consecutiveMismatches >= Self.requiredConsecutiveObservations else {
                return .none
            }
            reset()
            return .suspend
        case .indeterminate(let metrics):
            let allowsInitialTolerance = phase == .validating
                || (phase == .suspended && allowsTolerantRestoration)
            guard allowsInitialTolerance,
                  PickyAnnotationSceneVisualPolicy.canValidateInitialScene(metrics) else {
                reset()
                return .none
            }
            consecutiveMatches += 1
            consecutiveMismatches = 0
            guard consecutiveMatches >= Self.requiredConsecutiveObservations else {
                return .none
            }
            reset()
            return .show
        }
    }

    mutating func reset() {
        consecutiveMatches = 0
        consecutiveMismatches = 0
    }
}

enum PickyAnnotationScenePollingPolicy {
    /// Initial validation is intentionally quick, while long-lived static annotations
    /// back off to 1.5-second captures to keep visual-change detection responsive
    /// without excessive ScreenCaptureKit wakeups.
    static func delay(
        phase: PickyAnnotationScenePhase,
        elapsed: TimeInterval,
        retry: Int,
        pendingVisualConfirmation: Bool = false
    ) -> TimeInterval? {
        switch phase {
        case .inactive:
            return nil
        case .validating:
            return 0.30
        case .visible:
            if pendingVisualConfirmation { return 0.30 }
            if elapsed < 5 { return 0.50 }
            if elapsed < 30 { return 1.0 }
            return 1.5
        case .suspended:
            if pendingVisualConfirmation { return 0.30 }
            let schedule: [TimeInterval] = [0.30, 0.60, 1.20, 2.40, 5.0]
            return schedule[min(max(retry, 0), schedule.count - 1)]
        }
    }
}
