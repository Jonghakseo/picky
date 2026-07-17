//
//  PickyAgentAnnotationOverlayView.swift
//  Picky
//
//  Read-only AI guidance layer. User ink remains in PickyInkOverlayView.
//

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

    private var spotlights: [PickyAgentAnnotation] {
        annotationsForScreen.filter { $0.shape == .spotlight }
    }

    /// Semantic layers are intentionally fixed: agents cannot control stacking.
    private var outlineShapes: [PickyAgentAnnotation] {
        [.target, .circle, .rect, .line].flatMap { shape in
            annotationsForScreen.filter { $0.shape == shape }
        }
    }

    private var labels: [PickyAgentAnnotation] {
        annotationsForScreen.filter { $0.shape == .label }
    }

    private var accessibilitySummary: String {
        let labelTexts = labels.compactMap(\.label)
        guard !labelTexts.isEmpty else { return "Screen guidance is visible." }
        return "Screen guidance: \(labelTexts.joined(separator: ", "))."
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            spotlightMask
            ForEach(outlineShapes) { annotation in
                shape(annotation)
            }
            ForEach(labels) { annotation in
                if let point = localPoint(annotation.point), let label = annotation.label {
                    annotationLabel(label).position(x: point.x, y: point.y)
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
        case .target:
            if let point = localPoint(annotation.point), let radius = annotation.radius {
                ZStack {
                    Circle()
                        .fill(PickyAgentAnnotationOverlayStyle.targetFill)
                        .frame(width: radius * 2, height: radius * 2)
                        .position(point)
                    PickyRoughStrokeView(
                        paths: PickyAnnotationRoughGeometry.ellipsePaths(
                            id: annotation.id,
                            shape: .target,
                            center: point,
                            radiusX: radius,
                            radiusY: radius
                        )
                    )
                    Circle()
                        .fill(PickyAgentAnnotationOverlayStyle.strokeColor)
                        .frame(
                            width: PickyAgentAnnotationOverlayStyle.targetCenterDiameter,
                            height: PickyAgentAnnotationOverlayStyle.targetCenterDiameter
                        )
                        .position(point)
                }
            }
        case .circle:
            if let point = localPoint(annotation.point) {
                let radiusX = annotation.radiusX ?? annotation.radius ?? 0
                let radiusY = annotation.radiusY ?? annotation.radius ?? 0
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.ellipsePaths(
                        id: annotation.id,
                        shape: .circle,
                        center: point,
                        radiusX: radiusX,
                        radiusY: radiusY
                    )
                )
            }
        case .rect:
            if let rect = localRect(annotation.rect) {
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.rectanglePaths(id: annotation.id, rect: rect)
                )
            }
        case .line:
            if let start = localPoint(annotation.point), let end = localPoint(annotation.endPoint) {
                PickyRoughStrokeView(
                    paths: PickyAnnotationRoughGeometry.linePaths(id: annotation.id, start: start, end: end)
                )
            }
        case .label, .spotlight:
            EmptyView()
        }
    }

    @ViewBuilder
    private var spotlightMask: some View {
        if !spotlights.isEmpty {
            Canvas { context, size in
                context.fill(
                    Path(CGRect(origin: .zero, size: size)),
                    with: .color(PickyAgentAnnotationOverlayStyle.dimmingColor)
                )
                // destinationOut makes overlapping holes a union, so every
                // spotlighted region remains fully clear while dimming draws once.
                context.blendMode = .destinationOut
                for hole in PickyAnnotationSpotlightMaskGeometry.holes(for: spotlights, screenFrame: screenFrame) {
                    switch hole {
                    case .circle(let bounds):
                        context.fill(Path(ellipseIn: bounds), with: .color(.black))
                    case .rect(let bounds):
                        context.fill(Path(bounds), with: .color(.black))
                    }
                }
            }
            .frame(width: screenFrame.width, height: screenFrame.height)
        }
    }

    private func annotationLabel(_ label: String) -> some View {
        Text(label)
            .font(PickyHUDTypography.supportingSemibold)
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(PickyAgentAnnotationOverlayStyle.labelBorder, lineWidth: PickyAgentAnnotationOverlayStyle.labelBorderWidth)
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
}

/// Component-level values for the non-interactive, transient annotation surface.
/// They preserve the semantic DS mappings while keeping its dimmer and target dot
/// as explicit overlay-specific exceptions.
private enum PickyAgentAnnotationOverlayStyle {
    static let strokeColor = DS.Colors.accent
    static let targetFill = DS.Colors.accentSubtle
    static let labelBorder = DS.Colors.accent
    static let dimmingOpacity = 0.38
    static let dimmingColor = Color.black.opacity(dimmingOpacity)
    static let outlineLineWidth: CGFloat = 2
    static let labelBorderWidth: CGFloat = 1
    static let targetCenterDiameter: CGFloat = 6
}

private struct PickyRoughStrokeView: View {
    let paths: [PickyRoughPath]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasDrawn = false

    private var strokeEnd: CGFloat { reduceMotion || hasDrawn ? 1 : 0 }

    var body: some View {
        ZStack {
            ForEach(Array(paths.enumerated()), id: \.offset) { _, roughPath in
                roughPath.path
                    .trim(from: 0, to: strokeEnd)
                    .stroke(
                        PickyAgentAnnotationOverlayStyle.strokeColor,
                        style: StrokeStyle(
                            lineWidth: PickyAgentAnnotationOverlayStyle.outlineLineWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
            }
        }
        .onAppear {
            guard !reduceMotion else {
                hasDrawn = true
                return
            }
            withAnimation(.easeInOut(duration: DS.Animation.slow)) {
                hasDrawn = true
            }
        }
    }
}

enum PickyAnnotationSpotlightMaskGeometry {
    enum Hole: Equatable {
        case circle(CGRect)
        case rect(CGRect)
    }

    static let dimmingOpacity = PickyAgentAnnotationOverlayStyle.dimmingOpacity

    static func holes(for annotations: [PickyAgentAnnotation], screenFrame: CGRect) -> [Hole] {
        annotations.compactMap { annotation in
            guard annotation.shape == .spotlight else { return nil }
            if annotation.spotlightShape == .circle,
               let point = annotation.point,
               let radius = annotation.radius {
                let localPoint = PickyOverlayGeometry.swiftUICoordinates(for: point, in: screenFrame)
                return .circle(CGRect(
                    x: localPoint.x - radius,
                    y: localPoint.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }
            guard let rect = annotation.rect else { return nil }
            let topLeft = PickyOverlayGeometry.swiftUICoordinates(for: CGPoint(x: rect.minX, y: rect.maxY), in: screenFrame)
            return .rect(CGRect(origin: topLeft, size: rect.size))
        }
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
    /// Subtle, display-point jitter. This is deliberately not model configurable.
    static let roughness: CGFloat = 1.2

    static func linePaths(id: String, start: CGPoint, end: CGPoint) -> [PickyRoughPath] {
        (0..<2).map { pass in
            roughLine(id: id, shape: .line, pass: pass, start: start, end: end, overshoot: 0)
        }
    }

    static func rectanglePaths(id: String, rect: CGRect) -> [PickyRoughPath] {
        let corners = [
            CGPoint(x: rect.minX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.maxY),
            CGPoint(x: rect.minX, y: rect.maxY),
        ]
        return corners.indices.map { index in
            roughLine(
                id: id,
                shape: .rect,
                pass: index,
                start: corners[index],
                end: corners[(index + 1) % corners.count],
                overshoot: roughness * 0.6
            )
        }
    }

    static func ellipsePaths(
        id: String,
        shape: PickyAnnotationOverlayShape,
        center: CGPoint,
        radiusX: CGFloat,
        radiusY: CGFloat
    ) -> [PickyRoughPath] {
        var random = PickySeededRandom(seed: seed(id: id, shape: shape, pass: 0))
        let sampleCount = 9
        let points = (0..<sampleCount).map { index -> CGPoint in
            let angle = (CGFloat(index) / CGFloat(sampleCount)) * .pi * 2
            let radialOffset = random.offset(maximum: roughness)
            return CGPoint(
                x: center.x + cos(angle) * max(0, radiusX + radialOffset),
                y: center.y + sin(angle) * max(0, radiusY + radialOffset)
            )
        }

        var commands: [PickyRoughPathCommand] = [.move(points[0])]
        for index in points.indices {
            let previous = points[(index - 1 + sampleCount) % sampleCount]
            let current = points[index]
            let next = points[(index + 1) % sampleCount]
            let following = points[(index + 2) % sampleCount]
            let control1 = interpolate(current, next, factor: 1 / 6, relativeTo: previous)
            let control2 = interpolate(next, current, factor: 1 / 6, relativeTo: following)
            commands.append(.curve(to: next, control1: control1, control2: control2))
        }
        commands.append(.close)
        return [PickyRoughPath(commands: commands)]
    }

    private static func roughLine(
        id: String,
        shape: PickyAnnotationOverlayShape,
        pass: Int,
        start: CGPoint,
        end: CGPoint,
        overshoot: CGFloat
    ) -> PickyRoughPath {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let length = sqrt(dx * dx + dy * dy)
        let unit = length > 0 ? CGPoint(x: dx / length, y: dy / length) : .zero
        let amplitude = min(roughness, max(0.35, length * 0.015))
        var random = PickySeededRandom(seed: seed(id: id, shape: shape, pass: pass))
        let adjustedStart = offset(start, by: unit, distance: -overshoot)
        let adjustedEnd = offset(end, by: unit, distance: overshoot)
        let control1 = offset(interpolate(adjustedStart, adjustedEnd, factor: 1 / 3), by: random.pointOffset(maximum: amplitude))
        let control2 = offset(interpolate(adjustedStart, adjustedEnd, factor: 2 / 3), by: random.pointOffset(maximum: amplitude))
        return PickyRoughPath(commands: [
            .move(offset(adjustedStart, by: random.pointOffset(maximum: amplitude))),
            .curve(
                to: offset(adjustedEnd, by: random.pointOffset(maximum: amplitude)),
                control1: control1,
                control2: control2
            ),
        ])
    }

    private static func interpolate(_ start: CGPoint, _ end: CGPoint, factor: CGFloat) -> CGPoint {
        CGPoint(x: start.x + (end.x - start.x) * factor, y: start.y + (end.y - start.y) * factor)
    }

    private static func interpolate(_ current: CGPoint, _ next: CGPoint, factor: CGFloat, relativeTo previous: CGPoint) -> CGPoint {
        CGPoint(
            x: current.x + (next.x - previous.x) * factor,
            y: current.y + (next.y - previous.y) * factor
        )
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

    mutating func pointOffset(maximum: CGFloat) -> CGPoint {
        CGPoint(x: offset(maximum: maximum), y: offset(maximum: maximum))
    }

    private mutating func nextUnit() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / 9_007_199_254_740_992
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
