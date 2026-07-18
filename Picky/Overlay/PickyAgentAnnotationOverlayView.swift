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

    private var spotlightedAnnotations: [PickyAgentAnnotation] {
        annotationsForScreen.filter(\.spotlight)
    }

    /// Semantic layers are intentionally fixed: agents cannot control stacking.
    private var outlineShapes: [PickyAgentAnnotation] {
        [.rect, .line].flatMap { shape in
            annotationsForScreen.filter { $0.shape == shape }
        }
    }

    private var labels: [PickyAgentAnnotation] {
        annotationsForScreen.filter { $0.shape == .label }
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
                if let label = annotation.label,
                   let anchor = PickyAnnotationLabelGeometry.outlineAnchor(for: annotation, screenFrame: screenFrame) {
                    annotationLabel(label).position(x: anchor.x, y: anchor.y)
                }
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
        case .label:
            EmptyView()
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

/// Stable text-chip anchors for outline annotations. RECT labels sit just above the
/// top-left edge; LINE labels sit above their midpoint so neither obscures the stroke.
enum PickyAnnotationLabelGeometry {
    static let strokeOffset: CGFloat = 14

    static func outlineAnchor(for annotation: PickyAgentAnnotation, screenFrame: CGRect) -> CGPoint? {
        switch annotation.shape {
        case .rect:
            guard let rect = annotation.rect else { return nil }
            let localRect = localRect(rect, in: screenFrame)
            return CGPoint(x: localRect.minX, y: max(0, localRect.minY - strokeOffset))
        case .line:
            guard let start = annotation.point, let end = annotation.endPoint else { return nil }
            let localStart = PickyOverlayGeometry.swiftUICoordinates(for: start, in: screenFrame)
            let localEnd = PickyOverlayGeometry.swiftUICoordinates(for: end, in: screenFrame)
            return CGPoint(
                x: (localStart.x + localEnd.x) / 2,
                y: max(0, (localStart.y + localEnd.y) / 2 - strokeOffset)
            )
        case .label:
            return nil
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

/// Component-level values for the non-interactive, transient annotation surface.
/// They preserve the semantic DS mappings while keeping its dimmer as an
/// explicit overlay-specific exception.
private enum PickyAgentAnnotationOverlayStyle {
    static let strokeColor = DS.Colors.accent
    static let labelBorder = DS.Colors.accent
    static let dimmingOpacity = 0.38
    static let dimmingColor = Color.black.opacity(dimmingOpacity)
    static let outlineLineWidth: CGFloat = 2
    static let labelBorderWidth: CGFloat = 1
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
            case .label:
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
