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
    case validationTimeout
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
    let dilatedEdgeMask: [UInt8]

    init?(width: Int, height: Int, luminance: [UInt8]) {
        guard width > 0, height > 0, luminance.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.luminance = luminance
        self.dilatedEdgeMask = Self.computeDilatedEdgeMask(
            luminance: luminance,
            width: width,
            height: height
        )
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height && lhs.luminance == rhs.luminance
    }

    /// Produces the common single-resample luminance representation used for both
    /// capture-time baselines and live annotation-scene samples.
    static func make(from image: CGImage, width: Int, height: Int) -> Self? {
        var luminance = [UInt8](repeating: 0, count: width * height)
        guard width > 0,
              height > 0,
              let colorSpace = CGColorSpace(name: CGColorSpace.linearGray) else {
            return nil
        }
        let drew = luminance.withUnsafeMutableBytes { buffer -> Bool in
            guard let address = buffer.baseAddress,
                  let context = CGContext(
                    data: address,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                  ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return Self(width: width, height: height, luminance: luminance)
    }

    private static func computeDilatedEdgeMask(
        luminance: [UInt8],
        width: Int,
        height: Int
    ) -> [UInt8] {
        let pixelCount = luminance.count
        guard pixelCount > 0 else { return [] }

        var edgeMask = [UInt8](repeating: 0, count: pixelCount)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let index = rowStart + x
                let current = Int(luminance[index])
                var gradientMagnitude = 0
                if x + 1 < width {
                    gradientMagnitude += abs(current - Int(luminance[index + 1]))
                }
                if y + 1 < height {
                    gradientMagnitude += abs(current - Int(luminance[index + width]))
                }
                edgeMask[index] = gradientMagnitude >= PickyAnnotationSceneVisualPolicy.edgeThreshold ? 1 : 0
            }
        }

        var dilatedEdgeMask = [UInt8](repeating: 0, count: pixelCount)
        for y in 0..<height {
            let rowStart = y * width
            for x in 0..<width {
                let index = rowStart + x
                var isEdge = edgeMask[index] == 1
                if !isEdge {
                    if x > 0 && edgeMask[index - 1] == 1 {
                        isEdge = true
                    } else if x + 1 < width && edgeMask[index + 1] == 1 {
                        isEdge = true
                    } else if y > 0 && edgeMask[index - width] == 1 {
                        isEdge = true
                    } else if y + 1 < height && edgeMask[index + width] == 1 {
                        isEdge = true
                    }
                }
                dilatedEdgeMask[index] = isEdge ? 1 : 0
            }
        }
        return dilatedEdgeMask
    }
}

enum PickyAnnotationSceneInvalidationProfile: String, Equatable, Sendable {
    /// TTS can cause bounded animation and highlight drift while annotations are visible.
    case lenient
    /// Once TTS ends, return to prompt invalidation of stale annotation geometry.
    case strict

    /// A semantic signal (such as a scroll or app switch) permits a sensitive
    /// high-resolution comparison. It deliberately does not inherit narration-time
    /// tolerance because it runs only when an external event may have moved the anchor.
    case semantic

    var mismatchingROIChangedFraction: Double {
        switch self {
        case .lenient: 0.53
        case .strict: 0.38
        case .semantic: 0.08
        }
    }

    var mismatchingROIMeanDifference: Double {
        switch self {
        case .lenient: 31.0
        case .strict: 22.0
        case .semantic: 7.0
        }
    }

    var mismatchingGlobalChangedFraction: Double {
        switch self {
        case .lenient: 0.47
        case .strict: 0.40
        case .semantic: 0.08
        }
    }

    var mismatchingGlobalMeanDifference: Double {
        switch self {
        case .lenient: 25.0
        case .strict: 20.0
        case .semantic: 7.0
        }
    }
}

enum PickyAnnotationSceneVisualPolicy {
    /// Per-pixel luminance noise below this value is ignored. This absorbs JPEG,
    /// color-management, and subpixel rendering differences without hiding real UI changes.
    static let changedPixelThreshold = 18

    /// Gradient magnitude threshold used to mark a luminance pixel as an edge.
    static let edgeThreshold = 24

    // MARK: - Structural restoration tuning
    static let gridSize = 12
    /// Minimum edge overlap (intersection over union of a cell's edge pixels) for the cell's
    /// structure to count as unchanged. Edge-free cells are neutral, so flat background never
    /// dilutes the edge evidence the way raw pixel matching would.
    static let minCellEdgeCorrespondence = 0.5
    /// A cell needs at least this fraction of its pixels on an edge (min 1 pixel) before it is
    /// judged structural; sparser cells stay neutral to resist single-pixel noise.
    static let minCellEdgeCoverage = 0.03
    /// The non-anchor grid must carry at least this weighted fraction of structural cells before
    /// the structural verdict is trusted; flatter frames defer to the luminance decision.
    static let minStructuralCoverage = 0.10
    static let restoreFloor = 0.35
    static let breakFloor = 0.20
    static let peripheralEdgeWeightBoost = 0.60

    /// A strict threshold is used to prove restoration; a looser one is used to prove
    /// invalidation. Values in between are deliberately indeterminate to prevent flicker.
    static let matchingROIChangedFraction = 0.08
    static let matchingROIMeanDifference = 7.0
    /// Initial reveal allowance for transient highlight/color drift. Kept well below
    /// hard mismatch so localized content changes still block stale geometry.
    static let initialValidationROIChangedFraction = 0.20
    static let initialValidationROIMeanDifference = 12.0
    static let matchingGlobalChangedFraction = 0.18
    static let matchingGlobalMeanDifference = 8.0
    /// Initial validation fails closed only for a near-full-screen transition.
    /// ROI-only changes are intentionally ignored here so carousel, video, and
    /// other self-updating content can reveal annotations. Workspace, window,
    /// and scroll observers still schedule visual confirmation independently.
    static let initialHardMismatchGlobalChangedFraction = 0.70
    static let initialHardMismatchGlobalMeanDifference = 40.0

    static func isInitialHardMismatch(_ metrics: PickyAnnotationSceneDifferenceMetrics) -> Bool {
        metrics.globalChangedFraction >= initialHardMismatchGlobalChangedFraction
            || metrics.globalMeanDifference >= initialHardMismatchGlobalMeanDifference
    }

    static func compare(
        baseline: PickyAnnotationSceneFingerprint,
        current: PickyAnnotationSceneFingerprint,
        normalizedRegions: [CGRect],
        invalidationProfile: PickyAnnotationSceneInvalidationProfile = .strict
    ) -> PickyAnnotationSceneVisualObservation {
        evaluate(
            baseline: baseline,
            current: current,
            normalizedRegions: normalizedRegions,
            invalidationProfile: invalidationProfile
        ).observation
    }

    /// Single-pass evaluation returning the observation plus, on the `.strict` restoration path,
    /// the structural stable fraction for logging. It is pure array math over `Sendable` inputs
    /// and is deliberately safe to run off the main actor. Structural analysis runs only on the
    /// `.strict` path (once), so narration/semantic samples stay cheap.
    static func evaluate(
        baseline: PickyAnnotationSceneFingerprint,
        current: PickyAnnotationSceneFingerprint,
        normalizedRegions: [CGRect],
        invalidationProfile: PickyAnnotationSceneInvalidationProfile = .strict
    ) -> (observation: PickyAnnotationSceneVisualObservation, stableFraction: Double?) {
        guard baseline.width == current.width,
              baseline.height == current.height,
              baseline.luminance.count == current.luminance.count else {
            let metrics = PickyAnnotationSceneDifferenceMetrics(
                globalChangedFraction: 1,
                globalMeanDifference: 255,
                roiChangedFraction: normalizedRegions.isEmpty ? nil : 1,
                roiMeanDifference: normalizedRegions.isEmpty ? nil : 255
            )
            return (.mismatching(metrics), nil)
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
            $0.changedFraction >= invalidationProfile.mismatchingROIChangedFraction
                || $0.meanDifference >= invalidationProfile.mismatchingROIMeanDifference
        } ?? false
        let globalMismatches = global.changedFraction >= invalidationProfile.mismatchingGlobalChangedFraction
            || global.meanDifference >= invalidationProfile.mismatchingGlobalMeanDifference
        if roiMismatches || globalMismatches {
            return (.mismatching(metrics), nil)
        }

        let roiMatches = roi.map {
            $0.changedFraction <= matchingROIChangedFraction
                && $0.meanDifference <= matchingROIMeanDifference
        } ?? true
        let globalMatches = global.changedFraction <= matchingGlobalChangedFraction
            && global.meanDifference <= matchingGlobalMeanDifference

        // Structural persistence gates only the visual restoration polling path (.strict).
        // Narration (.lenient) keeps its bounded-drift tolerance and scroll/app (.semantic)
        // stays luminance-only, both by design, so they skip structural analysis entirely.
        if invalidationProfile != .strict {
            let observation: PickyAnnotationSceneVisualObservation = (roiMatches && globalMatches)
                ? .matching(metrics)
                : .indeterminate(metrics)
            return (observation, nil)
        }

        let structural = structuralAnalysis(
            baseline: baseline,
            current: current,
            normalizedRegions: normalizedRegions
        )
        let luminanceMatches = roiMatches && globalMatches
        let observation: PickyAnnotationSceneVisualObservation
        if structural.anchorBroke {
            // A moved anchor whose luminance drift exceeds the bounded allowance breaks outright.
            observation = .mismatching(metrics)
        } else if !structural.hasEvidence {
            // Too little distributed structure to judge a layout change: defer to luminance.
            observation = luminanceMatches ? .matching(metrics) : .indeterminate(metrics)
        } else if structural.stableFraction >= restoreFloor && structural.anchorStructurallyStable {
            observation = .matching(metrics)
        } else if structural.stableFraction < breakFloor {
            observation = .mismatching(metrics)
        } else {
            observation = .indeterminate(metrics)
        }
        return (observation, structural.stableFraction)
    }

    private static func structuralAnalysis(
        baseline: PickyAnnotationSceneFingerprint,
        current: PickyAnnotationSceneFingerprint,
        normalizedRegions: [CGRect]
    ) -> (stableFraction: Double, anchorStructurallyStable: Bool, anchorBroke: Bool, hasEvidence: Bool) {
        let gridColumns = min(gridSize, baseline.width)
        let gridRows = min(gridSize, baseline.height)

        guard baseline.width == current.width,
              baseline.height == current.height,
              gridColumns > 0,
              gridRows > 0 else {
            return (0, false, true, true)
        }

        let anchorCells = annotationCells(
            normalizedRegions: normalizedRegions,
            columns: gridColumns,
            rows: gridRows
        )
        // The anchor is judged per-region below, so keep the global structural verdict to the
        // non-anchor grid; that lets a bounded local anchor drift stay separate from a broad
        // layout change.
        var weightedStableOutside = 0.0
        var weightedStructuralOutside = 0.0
        var weightedTotalOutside = 0.0
        var unstableStructuralCells: Set<Int> = []

        for row in 0..<gridRows {
            let rowStartIndex = rowStart(y: row, rows: gridRows, height: baseline.height)
            let rowEndIndex = rowStart(y: row + 1, rows: gridRows, height: baseline.height)
            for column in 0..<gridColumns {
                let cellIndex = row * gridColumns + column
                let columnStartIndex = columnStart(x: column, columns: gridColumns, width: baseline.width)
                let columnEndIndex = columnStart(x: column + 1, columns: gridColumns, width: baseline.width)

                var edgeUnion = 0
                var edgeIntersection = 0
                var totalPixels = 0
                for y in rowStartIndex..<rowEndIndex {
                    let rowOffset = y * baseline.width
                    for x in columnStartIndex..<columnEndIndex {
                        let index = rowOffset + x
                        let baselineEdge = baseline.dilatedEdgeMask[index] != 0
                        let currentEdge = current.dilatedEdgeMask[index] != 0
                        if baselineEdge || currentEdge { edgeUnion += 1 }
                        if baselineEdge && currentEdge { edgeIntersection += 1 }
                        totalPixels += 1
                    }
                }

                let weight = structuralCellWeight(row: row, column: column, rows: gridRows, columns: gridColumns)
                let isAnchorCell = anchorCells.contains(cellIndex)
                if !isAnchorCell { weightedTotalOutside += weight }

                let minEdgePixels = max(1, Int(Double(totalPixels) * minCellEdgeCoverage))
                guard edgeUnion >= minEdgePixels else { continue } // neutral (flat) cell

                let correspondence = Double(edgeIntersection) / Double(edgeUnion)
                let structurallyStable = correspondence >= minCellEdgeCorrespondence
                if !structurallyStable { unstableStructuralCells.insert(cellIndex) }
                if isAnchorCell { continue }
                weightedStructuralOutside += weight
                if structurallyStable { weightedStableOutside += weight }
            }
        }

        let stableFraction = weightedStructuralOutside > 0
            ? (weightedStableOutside / weightedStructuralOutside)
            : 1.0
        let hasEvidence = weightedTotalOutside > 0
            && (weightedStructuralOutside / weightedTotalOutside) >= minStructuralCoverage

        var anchorStructurallyStable = true
        var anchorBroke = false
        for region in normalizedRegions {
            let cells = annotationCells(normalizedRegions: [region], columns: gridColumns, rows: gridRows)
            guard !cells.isDisjoint(with: unstableStructuralCells) else { continue }
            anchorStructurallyStable = false
            let drift = regionLuminanceDrift(baseline: baseline, current: current, region: region)
            let withinAllowance = drift.changedFraction <= initialValidationROIChangedFraction
                && drift.meanDifference <= initialValidationROIMeanDifference
            if !withinAllowance { anchorBroke = true }
        }

        return (stableFraction, anchorStructurallyStable, anchorBroke, hasEvidence)
    }

    private static func regionLuminanceDrift(
        baseline: PickyAnnotationSceneFingerprint,
        current: PickyAnnotationSceneFingerprint,
        region: CGRect
    ) -> (changedFraction: Double, meanDifference: Double) {
        let indexes = pixelIndexes(
            normalizedRegions: [region],
            width: baseline.width,
            height: baseline.height
        )
        guard !indexes.isEmpty else { return (0, 0) }
        return difference(baseline: baseline.luminance, current: current.luminance, indexes: indexes)
    }

    private static func structuralCellWeight(
        row: Int,
        column: Int,
        rows: Int,
        columns: Int
    ) -> Double {
        guard columns > 1, rows > 1 else { return 1 }
        let maxXDistance = Double(columns - 1) / 2
        let maxYDistance = Double(rows - 1) / 2
        guard maxXDistance > 0, maxYDistance > 0 else { return 1 }

        let distanceFromEdgeX = abs(Double(column) - maxXDistance) / maxXDistance
        let distanceFromEdgeY = abs(Double(row) - maxYDistance) / maxYDistance
        let peripheral = max(distanceFromEdgeX, distanceFromEdgeY)
        return 1 + (peripheral * peripheralEdgeWeightBoost)
    }

    private static func rowStart(y: Int, rows: Int, height: Int) -> Int {
        Int((Double(y) / Double(rows)) * Double(height))
    }

    private static func columnStart(x: Int, columns: Int, width: Int) -> Int {
        Int((Double(x) / Double(columns)) * Double(width))
    }

    private static func annotationCells(
        normalizedRegions: [CGRect],
        columns: Int,
        rows: Int
    ) -> Set<Int> {
        guard !normalizedRegions.isEmpty,
              columns > 0,
              rows > 0 else { return [] }
        var result: Set<Int> = []
        for rawRegion in normalizedRegions {
            let region = rawRegion.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            guard !region.isNull, !region.isEmpty else { continue }

            let minColumn = max(
                0,
                min(columns - 1, Int(floor(region.minX * CGFloat(columns))))
            )
            let maxColumn = max(
                minColumn,
                min(columns - 1, Int(ceil(region.maxX * CGFloat(columns))) - 1)
            )
            let minRow = max(
                0,
                min(rows - 1, Int(floor(region.minY * CGFloat(rows))))
            )
            let maxRow = max(
                minRow,
                min(rows - 1, Int(ceil(region.maxY * CGFloat(rows))) - 1)
            )

            for row in minRow...maxRow {
                for column in minColumn...maxColumn {
                    result.insert(row * columns + column)
                }
            }
        }
        return result
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
        case .mismatching(let metrics):
            if phase == .validating,
               !PickyAnnotationSceneVisualPolicy.isInitialHardMismatch(metrics) {
                reset()
                return .none
            }
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
