//
//  PickyAgentAnnotationOverlayView.swift
//  Picky
//
//  Read-only AI guidance layer. User ink remains in PickyInkOverlayView.
//

import AppKit
import SwiftUI

struct PickyAgentAnnotationOverlayView: View {
    let screenFrame: CGRect
    let annotations: [PickyAgentAnnotation]

    private var annotationsForScreen: [PickyAgentAnnotation] {
        annotations.filter {
            PickyOverlayGeometry.targetBelongsToScreen(
                screenLocation: $0.displayFrame.center,
                displayFrame: $0.displayFrame,
                screenFrame: screenFrame
            )
        }
    }

    private var spotlightedAnnotations: [PickyAgentAnnotation] {
        annotationsForScreen.filter(\.spotlight)
    }

    /// Semantic layers are intentionally fixed: agents cannot control stacking.
    private var outlineShapes: [PickyAgentAnnotation] {
        [.rect, .line, .path].flatMap { shape in
            annotationsForScreen.filter { $0.shape == shape }
        }
    }

    private var accessibilitySummary: String {
        let labelTexts = annotationsForScreen.compactMap(\.label)
        guard !labelTexts.isEmpty else { return "Screen guidance is visible." }
        return "Screen guidance: \(labelTexts.joined(separator: ", "))."
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            spotlightMask
            ForEach(outlineShapes) { annotation in
                shape(annotation)
                if let label = annotation.label {
                    let labelSize = annotationLabelSize(label)
                    if let anchor = PickyAnnotationLabelGeometry.outlineAnchor(
                        for: annotation,
                        screenFrame: screenFrame,
                        labelSize: labelSize
                    ) {
                        annotationLabel(label, size: labelSize)
                            .position(x: anchor.x, y: anchor.y)
                    }
                }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(.isStaticText)
    }

    @ViewBuilder
    private func shape(_ annotation: PickyAgentAnnotation) -> some View {
        switch annotation.shape {
        case .rect:
            if let rect = localRect(annotation.rect) {
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.rectanglePaths(id: annotation.id, rect: rect),
                    visualStyle: annotation.visualStyle
                )
            }
        case .line:
            if let start = localPoint(annotation.point), let end = localPoint(annotation.endPoint) {
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.linePaths(id: annotation.id, start: start, end: end),
                    visualStyle: annotation.visualStyle
                )
            }
        case .path:
            if let commands = localPathCommands(annotation.pathCommands) {
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.pathPaths(id: annotation.id, commands: commands),
                    visualStyle: annotation.visualStyle
                )
            }
        }
    }

    @ViewBuilder
    private var spotlightMask: some View {
        if !spotlightedAnnotations.isEmpty {
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(PickyAgentAnnotationOverlayStyle.dimmingColor)
                )
                // destinationOut makes overlapping holes a union, so every
                // spotlighted region remains fully clear while dimming draws once.
                context.blendMode = .destinationOut
                for hole in PickyAnnotationSpotlightMaskGeometry.holes(for: spotlightedAnnotations, screenFrame: screenFrame) {
                    switch hole {
                    case .roundedRect(let bounds, let cornerRadius):
                        context.fill(Path(roundedRect: bounds, cornerRadius: cornerRadius), with: .color(.black))
                    case .rect(let bounds):
                        context.fill(Path(bounds), with: .color(.black))
                    }
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height)
        }
    }

    private func annotationLabel(_ label: String, size: CGSize) -> some View {
        let textWidth = max(1, size.width - DS.Spacing.sm * 2)
        return Text(label)
            .font(PickyHUDTypography.metaSemibold)
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: textWidth, alignment: .leading)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(
                DS.Colors.surface1,
                in: RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
            )
    }

    private func annotationLabelSize(_ label: String) -> CGSize {
        let font = NSFont.systemFont(ofSize: PickyHUDTypography.Size.meta, weight: .semibold)
        let textSize = (label as NSString).size(withAttributes: [.font: font])
        return PickyAnnotationLabelGeometry.boundedLabelSize(
            measuredSize: CGSize(
                width: ceil(textSize.width) + DS.Spacing.sm * 2,
                height: ceil(textSize.height) + DS.Spacing.xs * 2
            ),
            screenSize: screenFrame.size
        )
    }

    private func localPoint(_ point: CGPoint?) -> CGPoint? {
        guard let point else { return nil }
        return PickyOverlayGeometry.swiftUICoordinates(for: point, in: screenFrame)
    }

    private func localRect(_ rect: CGRect?) -> CGRect? {
        guard let rect else { return nil }
        let topLeft = PickyOverlayGeometry.swiftUICoordinates(for: CGPoint(x: rect.minX, y: rect.maxY), in: screenFrame)
        return CGRect(origin: topLeft, size: rect.size)
    }

    private func localPathCommands(
        _ commands: [PickyAgentAnnotationPathCommand]?
    ) -> [PickyAgentAnnotationPathCommand]? {
        guard let commands else { return nil }
        return commands.compactMap { command in
            switch command {
            case .move(let point):
                return localPoint(point).map(PickyAgentAnnotationPathCommand.move)
            case .line(let point):
                return localPoint(point).map(PickyAgentAnnotationPathCommand.line)
            case .cubic(to: let destination, control1: let control1, control2: let control2):
                guard let localDestination = localPoint(destination),
                      let localControl1 = localPoint(control1),
                      let localControl2 = localPoint(control2) else { return nil }
                return .cubic(to: localDestination, control1: localControl1, control2: localControl2)
            }
        }
    }
}

/// Boundary-safe text-chip anchors for outline annotations. Candidate positions keep
/// labels clear of the stroke; the final clamp guarantees the full measured chip stays
/// inside its display even for large font scales, long strings, and CJK text.
enum PickyAnnotationLabelGeometry {
    static let maximumLabelWidth: CGFloat = 240
    private static let labelGap: CGFloat = DS.Spacing.sm

    static func outlineAnchor(
        for annotation: PickyAgentAnnotation,
        screenFrame: CGRect,
        labelSize: CGSize
    ) -> CGPoint? {
        let screenSize = screenFrame.size
        let halfWidth = labelSize.width / 2
        let halfHeight = labelSize.height / 2
        let candidates: [CGPoint]

        switch annotation.shape {
        case .rect:
            guard let rect = annotation.rect else { return nil }
            let localRect = localRect(rect, in: screenFrame)
            candidates = [
                CGPoint(x: localRect.minX + halfWidth, y: localRect.minY - labelGap - halfHeight),
                CGPoint(x: localRect.maxX - halfWidth, y: localRect.maxY + labelGap + halfHeight),
                CGPoint(x: localRect.maxX + labelGap + halfWidth, y: localRect.minY + halfHeight),
                CGPoint(x: localRect.minX - labelGap - halfWidth, y: localRect.minY + halfHeight),
            ]
        case .line:
            guard let start = annotation.point, let end = annotation.endPoint else { return nil }
            let localStart = PickyOverlayGeometry.swiftUICoordinates(for: start, in: screenFrame)
            let localEnd = PickyOverlayGeometry.swiftUICoordinates(for: end, in: screenFrame)
            let leftPoint = localStart.x <= localEnd.x ? localStart : localEnd
            let rightPoint = localStart.x <= localEnd.x ? localEnd : localStart
            let midpoint = CGPoint(x: (localStart.x + localEnd.x) / 2, y: (localStart.y + localEnd.y) / 2)
            candidates = [
                CGPoint(x: leftPoint.x - labelGap - halfWidth, y: leftPoint.y),
                CGPoint(x: rightPoint.x + labelGap + halfWidth, y: rightPoint.y),
                CGPoint(x: midpoint.x, y: midpoint.y - labelGap - halfHeight),
                CGPoint(x: midpoint.x, y: midpoint.y + labelGap + halfHeight),
            ]
        case .path:
            guard let commands = annotation.pathCommands,
                  let pathBounds = PickyAnnotationPathGeometry.bounds(for: commands) else { return nil }
            let localBounds = localRect(pathBounds, in: screenFrame)
            candidates = [
                CGPoint(x: localBounds.maxX + labelGap + halfWidth, y: localBounds.midY),
                CGPoint(x: localBounds.minX - labelGap - halfWidth, y: localBounds.midY),
                CGPoint(x: localBounds.midX, y: localBounds.minY - labelGap - halfHeight),
                CGPoint(x: localBounds.midX, y: localBounds.maxY + labelGap + halfHeight),
            ]
        }

        return candidates.first(where: { fits($0, screenSize: screenSize, labelSize: labelSize) })
            ?? clampedAnchor(preferred: candidates[0], screenSize: screenSize, labelSize: labelSize)
    }

    static func boundedLabelSize(measuredSize: CGSize, screenSize: CGSize) -> CGSize {
        CGSize(
            width: min(measuredSize.width, maximumLabelWidth, max(1, screenSize.width - labelGap * 2)),
            height: min(measuredSize.height, max(1, screenSize.height - labelGap * 2))
        )
    }

    static func clampedAnchor(preferred: CGPoint, screenSize: CGSize, labelSize: CGSize) -> CGPoint {
        let halfWidth = min(labelSize.width / 2, screenSize.width / 2)
        let halfHeight = min(labelSize.height / 2, screenSize.height / 2)
        return CGPoint(
            x: min(max(preferred.x, halfWidth), max(halfWidth, screenSize.width - halfWidth)),
            y: min(max(preferred.y, halfHeight), max(halfHeight, screenSize.height - halfHeight))
        )
    }

    private static func fits(_ center: CGPoint, screenSize: CGSize, labelSize: CGSize) -> Bool {
        center.x - labelSize.width / 2 >= 0
            && center.x + labelSize.width / 2 <= screenSize.width
            && center.y - labelSize.height / 2 >= 0
            && center.y + labelSize.height / 2 <= screenSize.height
    }

    private static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        let topLeft = PickyOverlayGeometry.swiftUICoordinates(
            for: CGPoint(x: rect.minX, y: rect.maxY),
            in: screenFrame
        )
        return CGRect(origin: topLeft, size: rect.size)
    }
}

/// Component-level values for the non-interactive, transient annotation surface.
/// They preserve the semantic DS mappings while keeping its dimmer as an
/// explicit overlay-specific exception.
private enum PickyAgentAnnotationOverlayStyle {
    static let dimmingOpacity = 0.38
    static let dimmingColor = Color.black.opacity(dimmingOpacity)
    static let roughStrokeLineWidth: CGFloat = 1.5
}

private struct PickyRoughStrokeView: View {
    let paths: [PickyRoughPath]
    let visualStyle: PickyAnnotationVisualStyle

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawProgress: CGFloat = 0

    private var effectiveDrawProgress: CGFloat { reduceMotion ? 1 : drawProgress }

    var body: some View {
        ZStack {
            ForEach(Array(paths.enumerated()), id: \.offset) { index, roughPath in
                PickySequentialRoughPath(
                    roughPath: roughPath,
                    index: index,
                    count: paths.count,
                    progress: effectiveDrawProgress
                )
                .stroke(
                    visualStyle.palette.color,
                    style: StrokeStyle(
                        lineWidth: PickyAgentAnnotationOverlayStyle.roughStrokeLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
        .onAppear {
            guard !reduceMotion else {
                drawProgress = 1
                return
            }
            withAnimation(.easeInOut(duration: DS.Animation.slow)) {
                drawProgress = 1
            }
        }
    }
}

private struct PickySequentialRoughPath: Shape {
    let roughPath: PickyRoughPath
    let index: Int
    let count: Int
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in _: CGRect) -> Path {
        guard count > 0 else { return Path() }
        let localProgress = min(max(progress * CGFloat(count) - CGFloat(index), 0), 1)
        return roughPath.path.trimmedPath(from: 0, to: localProgress)
    }
}

enum PickyAnnotationSpotlightMaskGeometry {
    enum Hole: Equatable {
        case roundedRect(CGRect, cornerRadius: CGFloat)
        case rect(CGRect)
    }

    static let dimmingOpacity = PickyAgentAnnotationOverlayStyle.dimmingOpacity
    static let rectPadding: CGFloat = DS.Spacing.sm
    static let linePadding: CGFloat = DS.Spacing.md
    static let rectCornerRadius: CGFloat = DS.CornerRadius.small

    static func holes(for annotations: [PickyAgentAnnotation], screenFrame: CGRect) -> [Hole] {
        annotations.compactMap { annotation in
            guard annotation.spotlight else { return nil }
            switch annotation.shape {
            case .rect:
                guard let rect = annotation.rect else { return nil }
                let localRect = localRect(rect, in: screenFrame).insetBy(dx: -rectPadding, dy: -rectPadding)
                return .roundedRect(localRect, cornerRadius: min(rectCornerRadius, min(localRect.width, localRect.height) / 2))
            case .line:
                guard let start = annotation.point, let end = annotation.endPoint else { return nil }
                let localStart = PickyOverlayGeometry.swiftUICoordinates(for: start, in: screenFrame)
                let localEnd = PickyOverlayGeometry.swiftUICoordinates(for: end, in: screenFrame)
                return .rect(CGRect(
                    x: min(localStart.x, localEnd.x) - linePadding,
                    y: min(localStart.y, localEnd.y) - linePadding,
                    width: abs(localEnd.x - localStart.x) + linePadding * 2,
                    height: abs(localEnd.y - localStart.y) + linePadding * 2
                ))
            case .path:
                return nil
            }
        }
    }

    private static func localRect(_ rect: CGRect, in screenFrame: CGRect) -> CGRect {
        let topLeft = PickyOverlayGeometry.swiftUICoordinates(
            for: CGPoint(x: rect.minX, y: rect.maxY),
            in: screenFrame
        )
        return CGRect(origin: topLeft, size: rect.size)
    }
}

struct PickyRoughPath: Equatable {
    let commands: [PickyRoughPathCommand]

    var path: Path {
        Path { path in
            for command in commands {
                switch command {
                case .move(let point):
                    path.move(to: point)
                case .line(let point):
                    path.addLine(to: point)
                case .curve(let destination, let control1, let control2):
                    path.addCurve(to: destination, control1: control1, control2: control2)
                case .close:
                    path.closeSubpath()
                }
            }
        }
    }
}

enum PickyRoughPathCommand: Equatable {
    case move(CGPoint)
    case line(CGPoint)
    case curve(to: CGPoint, control1: CGPoint, control2: CGPoint)
    case close
}

enum PickyAnnotationRoughGeometry {
    /// Display-point deviation for the largest annotations. Smaller shapes scale
    /// this down so the sketch texture never obscures the target geometry.
    static let roughness: CGFloat = 1.6
    static let passCount = 2

    static func linePaths(id: String, start: CGPoint, end: CGPoint) -> [PickyRoughPath] {
        (0..<passCount).map { pass in
            roughLine(id: id, shape: .line, seedIndex: pass, start: start, end: end, overshoot: 0)
        }
    }

    static func pathPaths(
        id: String,
        commands: [PickyAgentAnnotationPathCommand]
    ) -> [PickyRoughPath] {
        (0..<passCount).map { pass in
            var random = PickySeededRandom(seed: seed(id: id, shape: .path, pass: pass))
            let jitter = { (point: CGPoint, random: inout PickySeededRandom) -> CGPoint in
                offset(point, by: CGPoint(
                    x: random.offset(maximum: roughness * 0.45),
                    y: random.offset(maximum: roughness * 0.45)
                ))
            }
            let roughCommands = commands.map { command -> PickyRoughPathCommand in
                switch command {
                case .move(let point):
                    return .move(jitter(point, &random))
                case .line(let point):
                    return .line(jitter(point, &random))
                case .cubic(to: let destination, control1: let control1, control2: let control2):
                    return .curve(
                        to: jitter(destination, &random),
                        control1: jitter(control1, &random),
                        control2: jitter(control2, &random)
                    )
                }
            }
            return PickyRoughPath(commands: roughCommands)
        }
    }

    static func rectanglePaths(id: String, rect: CGRect) -> [PickyRoughPath] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        return (0..<passCount).flatMap { pass in
            corners.indices.map { edge in
                roughLine(
                    id: id,
                    shape: .rect,
                    seedIndex: pass * corners.count + edge,
                    start: corners[edge],
                    end: corners[(edge + 1) % corners.count],
                    overshoot: roughness * 0.55
                )
            }
        }
    }

    private static func roughLine(
        id: String,
        shape: PickyAnnotationOverlayShape,
        seedIndex: Int,
        start: CGPoint,
        end: CGPoint,
        overshoot: CGFloat
    ) -> PickyRoughPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        guard length > 0 else {
            return PickyRoughPath(commands: [.move(start), .line(end)])
        }

        let tangent = CGPoint(x: dx / length, y: dy / length)
        let normal = CGPoint(x: -tangent.y, y: tangent.x)
        let amplitude = min(roughness, max(0.35, length * 0.02))
        let boundedOvershoot = min(overshoot, length * 0.05)
        var random = PickySeededRandom(seed: seed(id: id, shape: shape, pass: seedIndex))

        let adjustedStart = offset(start, by: tangent, distance: -boundedOvershoot)
        let adjustedEnd = offset(end, by: tangent, distance: boundedOvershoot)
        let roughStart = jitteredEndpoint(adjustedStart, tangent: tangent, normal: normal, amplitude: amplitude, random: &random)
        let roughEnd = jitteredEndpoint(adjustedEnd, tangent: tangent, normal: normal, amplitude: amplitude, random: &random)
        let midpoint = offset(
            offset(interpolate(roughStart, roughEnd, factor: 0.5), by: tangent, distance: random.offset(maximum: amplitude * 0.12)),
            by: normal,
            distance: random.signedMagnitude(minimum: amplitude * 0.35, maximum: amplitude * 0.9)
        )

        let firstControl1 = controlPoint(from: roughStart, to: midpoint, factor: 0.34, normal: normal, amplitude: amplitude, random: &random)
        let firstControl2 = controlPoint(from: roughStart, to: midpoint, factor: 0.72, normal: normal, amplitude: amplitude, random: &random)
        let secondControl1 = controlPoint(from: midpoint, to: roughEnd, factor: 0.28, normal: normal, amplitude: amplitude, random: &random)
        let secondControl2 = controlPoint(from: midpoint, to: roughEnd, factor: 0.66, normal: normal, amplitude: amplitude, random: &random)

        return PickyRoughPath(commands: [
            .move(roughStart),
            .curve(to: midpoint, control1: firstControl1, control2: firstControl2),
            .curve(to: roughEnd, control1: secondControl1, control2: secondControl2),
        ])
    }

    private static func jitteredEndpoint(
        _ point: CGPoint,
        tangent: CGPoint,
        normal: CGPoint,
        amplitude: CGFloat,
        random: inout PickySeededRandom
    ) -> CGPoint {
        offset(
            offset(point, by: tangent, distance: random.offset(maximum: amplitude * 0.18)),
            by: normal,
            distance: random.offset(maximum: amplitude * 0.55)
        )
    }

    private static func controlPoint(
        from start: CGPoint,
        to end: CGPoint,
        factor: CGFloat,
        normal: CGPoint,
        amplitude: CGFloat,
        random: inout PickySeededRandom
    ) -> CGPoint {
        offset(
            interpolate(start, end, factor: factor),
            by: normal,
            distance: random.offset(maximum: amplitude * 0.2)
        )
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * factor, y: start.y + (end.y - start.y) * factor)
    }

    private static func offset(_ point: CGPoint, by vector: CGPoint, distance: CGFloat) -> CGPoint {
        CGPoint(x: point.x + vector.x * distance, y: point.y + vector.y * distance)
    }

    private static func offset(_ point: CGPoint, by offset: CGPoint) -> CGPoint {
        CGPoint(x: point.x + offset.x, y: point.y + offset.y)
    }

    private static func seed(id: String, shape: PickyAnnotationOverlayShape, pass: Int) -> UInt64 {
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in "\(id):\(shape.rawValue):\(pass)".utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return hash == 0 ? 1 : hash
    }
}

private struct PickySeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func offset(maximum: CGFloat) -> CGFloat {
        CGFloat((nextUnit() * 2 - 1) * Double(maximum))
    }

    mutating func signedMagnitude(minimum: CGFloat, maximum: CGFloat) -> CGFloat {
        let magnitude = minimum + CGFloat(nextUnit()) * max(0, maximum - minimum)
        return nextUnit() < 0.5 ? -magnitude : magnitude
    }

    private mutating func nextUnit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
