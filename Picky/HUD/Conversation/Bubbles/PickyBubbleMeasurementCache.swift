import AppKit

struct PickyBubbleMeasurementCacheKey: Hashable {
    let markdown: String
    private let effectiveWidthBitPattern: UInt64
    private let fontScaleBitPattern: UInt64
    let codeBlockMaxLines: Int

    init(
        markdown: String,
        effectiveWidth: CGFloat,
        fontScale: CGFloat,
        codeBlockMaxLines: Int
    ) {
        self.markdown = markdown
        effectiveWidthBitPattern = Double(effectiveWidth).bitPattern
        fontScaleBitPattern = Double(fontScale).bitPattern
        self.codeBlockMaxLines = codeBlockMaxLines
    }
}

struct PickyBubbleMeasurement: Equatable {
    let contentSize: NSSize
    let blockSizes: [NSSize]
}

@MainActor
final class PickyBubbleMeasurementCache {
    struct Resolution {
        let measurement: PickyBubbleMeasurement
        let wasCached: Bool
    }

    private final class KeyBox: NSObject {
        let key: PickyBubbleMeasurementCacheKey

        init(_ key: PickyBubbleMeasurementCacheKey) {
            self.key = key
        }

        override var hash: Int { key.hashValue }

        override func isEqual(_ object: Any?) -> Bool {
            guard let other = object as? KeyBox else { return false }
            return key == other.key
        }
    }

    private final class MeasurementBox {
        let value: PickyBubbleMeasurement

        init(_ value: PickyBubbleMeasurement) {
            self.value = value
        }
    }

    private let cache = NSCache<KeyBox, MeasurementBox>()

    init(countLimit: Int = 256, totalCostLimit: Int = 4 * 1_024 * 1_024) {
        cache.countLimit = max(1, countLimit)
        cache.totalCostLimit = max(1, totalCostLimit)
    }

    func resolve(
        key: PickyBubbleMeasurementCacheKey,
        compute: () -> PickyBubbleMeasurement
    ) -> Resolution {
        let boxedKey = KeyBox(key)
        if let cached = cache.object(forKey: boxedKey) {
            return Resolution(measurement: cached.value, wasCached: true)
        }

        let measurement = compute()
        let approximateCost = key.markdown.utf8.count + (measurement.blockSizes.count * MemoryLayout<NSSize>.stride)
        cache.setObject(MeasurementBox(measurement), forKey: boxedKey, cost: max(1, approximateCost))
        return Resolution(measurement: measurement, wasCached: false)
    }

    func removeAll() {
        cache.removeAllObjects()
    }
}
