import AppKit
import Testing
@testable import Picky

@MainActor
@Suite("Bubble measurement cache")
struct PickyBubbleMeasurementCacheTests {
    @Test func identicalContentAndExactWidthReuseMeasurement() {
        let cache = PickyBubbleMeasurementCache(countLimit: 8, totalCostLimit: 64 * 1_024)
        let key = PickyBubbleMeasurementCacheKey(
            markdown: "same markdown",
            effectiveWidth: 461,
            fontScale: 1,
            codeBlockMaxLines: 0
        )
        var computationCount = 0

        let first = cache.resolve(key: key) {
            computationCount += 1
            return Self.measurement(width: 461, height: 2_856)
        }
        let second = cache.resolve(key: key) {
            computationCount += 1
            return Self.measurement(width: 461, height: 999)
        }

        #expect(!first.wasCached)
        #expect(second.wasCached)
        #expect(second.measurement == first.measurement)
        #expect(computationCount == 1)
    }

    @Test func adjacentWidthsNeverShareMeasurement() {
        let cache = PickyBubbleMeasurementCache(countLimit: 8, totalCostLimit: 64 * 1_024)
        let firstKey = PickyBubbleMeasurementCacheKey(
            markdown: "wrap boundary content",
            effectiveWidth: 461,
            fontScale: 1,
            codeBlockMaxLines: 0
        )
        let adjacentKey = PickyBubbleMeasurementCacheKey(
            markdown: "wrap boundary content",
            effectiveWidth: 460.999,
            fontScale: 1,
            codeBlockMaxLines: 0
        )
        var computationCount = 0

        _ = cache.resolve(key: firstKey) {
            computationCount += 1
            return Self.measurement(width: 461, height: 100)
        }
        let adjacent = cache.resolve(key: adjacentKey) {
            computationCount += 1
            return Self.measurement(width: 460.999, height: 120)
        }

        #expect(!adjacent.wasCached)
        #expect(adjacent.measurement.contentSize.height == 120)
        #expect(computationCount == 2)
    }

    @Test func contentScaleAndPreviewPolicyAreIndependentKeys() {
        let cache = PickyBubbleMeasurementCache(countLimit: 8, totalCostLimit: 64 * 1_024)
        let keys = [
            PickyBubbleMeasurementCacheKey(markdown: "A", effectiveWidth: 461, fontScale: 1, codeBlockMaxLines: 4),
            PickyBubbleMeasurementCacheKey(markdown: "B", effectiveWidth: 461, fontScale: 1, codeBlockMaxLines: 4),
            PickyBubbleMeasurementCacheKey(markdown: "A", effectiveWidth: 461, fontScale: 1.1, codeBlockMaxLines: 4),
            PickyBubbleMeasurementCacheKey(markdown: "A", effectiveWidth: 461, fontScale: 1, codeBlockMaxLines: 0)
        ]
        var computationCount = 0

        for (index, key) in keys.enumerated() {
            let result = cache.resolve(key: key) {
                computationCount += 1
                return Self.measurement(width: 461, height: CGFloat(index + 1))
            }
            #expect(!result.wasCached)
        }

        #expect(computationCount == keys.count)
    }

    @Test func removedEntryFallsBackToCorrectRecomputation() {
        let cache = PickyBubbleMeasurementCache(countLimit: 8, totalCostLimit: 64 * 1_024)
        let key = PickyBubbleMeasurementCacheKey(
            markdown: "evictable",
            effectiveWidth: 461,
            fontScale: 1,
            codeBlockMaxLines: 0
        )
        var computationCount = 0

        _ = cache.resolve(key: key) {
            computationCount += 1
            return Self.measurement(width: 461, height: 100)
        }
        cache.removeAll()
        let recomputed = cache.resolve(key: key) {
            computationCount += 1
            return Self.measurement(width: 461, height: 120)
        }

        #expect(!recomputed.wasCached)
        #expect(recomputed.measurement.contentSize.height == 120)
        #expect(computationCount == 2)
    }

    @Test func separateAgentSurfacesKeepIdenticalPixelSizeForSameMarkdown() {
        let markdown = String(repeating: "A long response that wraps predictably at the card width. ", count: 40)
        let first = Self.configuredAgentSurface(markdown: markdown)
        let second = Self.configuredAgentSurface(markdown: markdown)

        let firstSize = first.measuredSize(forRootWidth: 600)
        let secondSize = second.measuredSize(forRootWidth: 600)

        #expect(secondSize == firstSize)
    }

    private static func measurement(width: CGFloat, height: CGFloat) -> PickyBubbleMeasurement {
        PickyBubbleMeasurement(
            contentSize: NSSize(width: width, height: height),
            blockSizes: [NSSize(width: width, height: height)]
        )
    }

    private static func configuredAgentSurface(markdown: String) -> PickyAgentBubbleSurfaceNSView {
        let surface = PickyAgentBubbleSurfaceNSView()
        surface.configure(
            markdown: markdown,
            maxBubbleWidth: 600,
            codeBlockMaxLines: 0,
            showsShortcutBadge: false,
            onOpenAsReport: nil,
            onCopyText: nil
        )
        return surface
    }
}
