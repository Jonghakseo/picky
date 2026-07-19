import CoreGraphics
import ImageIO
import SwiftUI

struct PickyScreenshotSampleColor: Equatable, Sendable {
    let red: Double
    let green: Double
    let blue: Double

    var relativeLuminance: Double {
        func linearize(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linearize(red) + 0.7152 * linearize(green) + 0.0722 * linearize(blue)
    }

    func contrastRatio(with other: Self) -> Double {
        let lighter = max(relativeLuminance, other.relativeLuminance)
        let darker = min(relativeLuminance, other.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }
}

/// Small, app-local color map derived from the exact screenshot sent as context.
/// It is deliberately excluded from the app-agentd payload and retained only long
/// enough to choose a readable annotation palette when the matching overlay arrives.
struct PickyScreenshotColorSampleGrid: Equatable, Sendable {
    let width: Int
    let height: Int
    let pixels: [PickyScreenshotSampleColor]

    init?(width: Int, height: Int, pixels: [PickyScreenshotSampleColor]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    static func make(from imageData: Data, maximumDimension: Int = 64) -> Self? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return make(from: image, maximumDimension: maximumDimension)
    }

    static func make(from image: CGImage, maximumDimension: Int = 64) -> Self? {
        let scale = min(1, Double(maximumDimension) / Double(max(image.width, image.height)))
        let targetWidth = max(1, Int((Double(image.width) * scale).rounded()))
        let targetHeight = max(1, Int((Double(image.height) * scale).rounded()))
        let bytesPerRow = targetWidth * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * targetHeight)
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }

        let drewImage = bytes.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: targetWidth,
                    height: targetHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else {
                return false
            }
            context.interpolationQuality = .medium
            // CGImage provider rows and screenshot coordinates both use a top-left
            // row order here; drawing without a vertical transform preserves it.
            context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
            return true
        }
        guard drewImage else { return nil }

        let pixels = stride(from: 0, to: bytes.count, by: 4).map { offset in
            let alpha = max(Double(bytes[offset + 3]) / 255, 1 / 255)
            return PickyScreenshotSampleColor(
                red: min(1, Double(bytes[offset]) / 255 / alpha),
                green: min(1, Double(bytes[offset + 1]) / 255 / alpha),
                blue: min(1, Double(bytes[offset + 2]) / 255 / alpha)
            )
        }
        return Self(width: targetWidth, height: targetHeight, pixels: pixels)
    }

    func samples(
        nearScreenshotPoints points: [CGPoint],
        screenshotSize: CGSize,
        neighborRadius: Int = 1
    ) -> [PickyScreenshotSampleColor] {
        guard screenshotSize.width > 0, screenshotSize.height > 0 else { return [] }
        var result: [PickyScreenshotSampleColor] = []
        result.reserveCapacity(points.count * (neighborRadius * 2 + 1) * (neighborRadius * 2 + 1))

        for point in points {
            let normalizedX = min(max(point.x / screenshotSize.width, 0), 1)
            let normalizedY = min(max(point.y / screenshotSize.height, 0), 1)
            let centerX = Int((normalizedX * CGFloat(width - 1)).rounded())
            let centerY = Int((normalizedY * CGFloat(height - 1)).rounded())
            for y in max(0, centerY - neighborRadius)...min(height - 1, centerY + neighborRadius) {
                for x in max(0, centerX - neighborRadius)...min(width - 1, centerX + neighborRadius) {
                    result.append(pixels[y * width + x])
                }
            }
        }
        return result
    }
}

enum PickyAnnotationPaletteRole: String, Codable, Equatable, CaseIterable, Sendable {
    case signalYellow
    case actionBlue

    var sampleColor: PickyScreenshotSampleColor {
        switch self {
        case .signalYellow: .init(red: 1.00, green: 0.84, blue: 0.04)
        case .actionBlue: .init(red: 37.0 / 255.0, green: 99.0 / 255.0, blue: 235.0 / 255.0)
        }
    }

    var color: Color {
        if self == .actionBlue { return DS.Colors.accent }
        let sample = sampleColor
        return Color(red: sample.red, green: sample.green, blue: sample.blue)
    }
}

enum PickyAnnotationKeylineTone: String, Codable, Equatable, Sendable {
    case light
    case dark

    var sampleColor: PickyScreenshotSampleColor {
        switch self {
        case .light: .init(red: 1, green: 1, blue: 1)
        case .dark: .init(red: 0.04, green: 0.05, blue: 0.05)
        }
    }

    var color: Color {
        switch self {
        case .light: .white
        case .dark: Color(red: 0.04, green: 0.05, blue: 0.05)
        }
    }
}

struct PickyAnnotationVisualStyle: Equatable, Codable, Sendable {
    let palette: PickyAnnotationPaletteRole
    let keyline: PickyAnnotationKeylineTone

    static let fallback = Self(palette: .actionBlue, keyline: .light)
}

enum PickyAnnotationPaletteResolver {
    /// Keep Picky Action Blue unless the sampled stroke area fails the 3:1
    /// non-text contrast target. The keyline remains a second safety layer.
    static let blueContrastThreshold = 3.0

    static func basePalette(
        for annotations: [PickyAnnotationOverlayAnnotation],
        screenshotSize: CGSize,
        sampleGrid: PickyScreenshotColorSampleGrid?
    ) -> PickyAnnotationPaletteRole? {
        guard let sampleGrid else { return nil }
        let samples = annotations.flatMap { annotation in
            sampleGrid.samples(
                nearScreenshotPoints: samplePoints(for: annotation),
                screenshotSize: screenshotSize
            )
        }
        return samples.isEmpty ? nil : preferredPalette(for: samples)
    }

    static func styles(
        for annotations: [PickyAnnotationOverlayAnnotation],
        screenshotSize: CGSize,
        sampleGrid: PickyScreenshotColorSampleGrid?,
        preferredBasePalette: PickyAnnotationPaletteRole? = nil
    ) -> [String: PickyAnnotationVisualStyle] {
        guard let sampleGrid else { return fallbackStyles(for: annotations) }

        let localSamples = annotations.reduce(into: [String: [PickyScreenshotSampleColor]]()) { result, annotation in
            let points = samplePoints(for: annotation)
            result[annotation.id] = sampleGrid.samples(
                nearScreenshotPoints: points,
                screenshotSize: screenshotSize
            )
        }
        let allSamples = annotations.flatMap { localSamples[$0.id] ?? [] }
        guard !allSamples.isEmpty else { return fallbackStyles(for: annotations) }

        let requestPalette = preferredBasePalette ?? preferredPalette(for: allSamples)
        return annotations.reduce(into: [String: PickyAnnotationVisualStyle]()) { result, annotation in
            let samples = localSamples[annotation.id] ?? []
            guard !samples.isEmpty else {
                result[annotation.id] = .fallback
                return
            }
            let blueScore = robustContrastScore(palette: .actionBlue, samples: samples)
            let requestScore = robustContrastScore(palette: requestPalette, samples: samples)
            let localPalette: PickyAnnotationPaletteRole
            if blueScore >= blueContrastThreshold {
                localPalette = .actionBlue
            } else if requestScore >= blueContrastThreshold {
                localPalette = requestPalette
            } else {
                localPalette = .signalYellow
            }
            result[annotation.id] = PickyAnnotationVisualStyle(
                palette: localPalette,
                keyline: bestKeyline(for: samples, palette: localPalette)
            )
        }
    }

    private static func fallbackStyles(
        for annotations: [PickyAnnotationOverlayAnnotation]
    ) -> [String: PickyAnnotationVisualStyle] {
        annotations.reduce(into: [:]) { $0[$1.id] = .fallback }
    }

    private static func samplePoints(for annotation: PickyAnnotationOverlayAnnotation) -> [CGPoint] {
        switch annotation.shape {
        case .rect:
            guard let x = annotation.x, let y = annotation.y,
                  let width = annotation.w, let height = annotation.h else { return [] }
            let steps = 12
            return (0...steps).flatMap { index -> [CGPoint] in
                let progress = CGFloat(index) / CGFloat(steps)
                let horizontalX = CGFloat(x) + CGFloat(width) * progress
                let verticalY = CGFloat(y) + CGFloat(height) * progress
                return [
                    CGPoint(x: horizontalX, y: CGFloat(y)),
                    CGPoint(x: horizontalX, y: CGFloat(y + height)),
                    CGPoint(x: CGFloat(x), y: verticalY),
                    CGPoint(x: CGFloat(x + width), y: verticalY),
                ]
            }
        case .line:
            guard let x1 = annotation.x1, let y1 = annotation.y1,
                  let x2 = annotation.x2, let y2 = annotation.y2 else { return [] }
            return (0...24).map { index in
                let progress = CGFloat(index) / 24
                return CGPoint(
                    x: CGFloat(x1) + CGFloat(x2 - x1) * progress,
                    y: CGFloat(y1) + CGFloat(y2 - y1) * progress
                )
            }
        case .path:
            return pathSamplePoints(annotation.commands ?? [])
        }
    }

    private static func pathSamplePoints(_ commands: [PickyAnnotationPathCommand]) -> [CGPoint] {
        var points: [CGPoint] = []
        var current: CGPoint?
        for command in commands {
            let destination = CGPoint(x: CGFloat(command.x), y: CGFloat(command.y))
            switch command.type {
            case .move:
                current = destination
                points.append(destination)
            case .line:
                guard let start = current else { continue }
                for index in 1...8 {
                    let progress = CGFloat(index) / 8
                    points.append(CGPoint(
                        x: start.x + (destination.x - start.x) * progress,
                        y: start.y + (destination.y - start.y) * progress
                    ))
                }
                current = destination
            case .cubic:
                guard let start = current,
                      let c1x = command.c1x, let c1y = command.c1y,
                      let c2x = command.c2x, let c2y = command.c2y else { continue }
                let control1 = CGPoint(x: CGFloat(c1x), y: CGFloat(c1y))
                let control2 = CGPoint(x: CGFloat(c2x), y: CGFloat(c2y))
                for index in 1...16 {
                    let progress = CGFloat(index) / 16
                    let inverse = 1 - progress
                    points.append(CGPoint(
                        x: start.x * inverse * inverse * inverse
                            + control1.x * 3 * inverse * inverse * progress
                            + control2.x * 3 * inverse * progress * progress
                            + destination.x * progress * progress * progress,
                        y: start.y * inverse * inverse * inverse
                            + control1.y * 3 * inverse * inverse * progress
                            + control2.y * 3 * inverse * progress * progress
                            + destination.y * progress * progress * progress
                    ))
                }
                current = destination
            }
        }
        return points
    }

    private static func preferredPalette(for samples: [PickyScreenshotSampleColor]) -> PickyAnnotationPaletteRole {
        if robustContrastScore(palette: .actionBlue, samples: samples) >= blueContrastThreshold {
            return .actionBlue
        }
        return .signalYellow
    }

    private static func bestKeyline(
        for samples: [PickyScreenshotSampleColor],
        palette: PickyAnnotationPaletteRole
    ) -> PickyAnnotationKeylineTone {
        [.light, .dark].reduce(.light) { best, candidate in
            keylineScore(candidate, samples: samples, palette: palette) > keylineScore(best, samples: samples, palette: palette)
                ? candidate
                : best
        }
    }

    private static func keylineScore(
        _ tone: PickyAnnotationKeylineTone,
        samples: [PickyScreenshotSampleColor],
        palette: PickyAnnotationPaletteRole
    ) -> Double {
        min(
            robustContrastScore(color: tone.sampleColor, samples: samples),
            tone.sampleColor.contrastRatio(with: palette.sampleColor)
        )
    }

    private static func robustContrastScore(
        palette: PickyAnnotationPaletteRole,
        samples: [PickyScreenshotSampleColor]
    ) -> Double {
        robustContrastScore(color: palette.sampleColor, samples: samples)
    }

    private static func robustContrastScore(
        color: PickyScreenshotSampleColor,
        samples: [PickyScreenshotSampleColor]
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.map { color.contrastRatio(with: $0) }.sorted()
        let percentileIndex = Int((Double(sorted.count - 1) * 0.10).rounded(.down))
        return sorted[percentileIndex]
    }
}
