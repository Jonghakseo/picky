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
        annotations
            .filter { PickyOverlayGeometry.targetBelongsToScreen(screenLocation: $0.displayFrame.center, displayFrame: $0.displayFrame, screenFrame: screenFrame) }
            .sorted { $0.zOrder == $1.zOrder ? $0.id < $1.id : $0.zOrder < $1.zOrder }
    }

    private var spotlights: [PickyAgentAnnotation] {
        annotationsForScreen.filter { $0.shape == .spotlight }
    }

    private var visibleShapes: [PickyAgentAnnotation] {
        annotationsForScreen.filter { $0.shape != .spotlight }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(spotlights) { annotation in
                spotlight(annotation)
            }
            ForEach(visibleShapes) { annotation in
                shape(annotation)
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func shape(_ annotation: PickyAgentAnnotation) -> some View {
        switch annotation.shape {
        case .target:
            if let point = localPoint(annotation.point), let radius = annotation.radius {
                ZStack {
                    Circle().fill(DS.Colors.accent.opacity(0.18)).frame(width: radius * 2, height: radius * 2)
                    Circle().stroke(DS.Colors.accent, lineWidth: 2).frame(width: radius * 2, height: radius * 2)
                    Circle().fill(DS.Colors.accent).frame(width: 6, height: 6)
                }
                .position(point)
            }
        case .circle:
            if let point = localPoint(annotation.point) {
                let radiusX = annotation.radiusX ?? annotation.radius ?? 0
                let radiusY = annotation.radiusY ?? annotation.radius ?? 0
                Ellipse()
                    .stroke(DS.Colors.accent, lineWidth: 2)
                    .frame(width: radiusX * 2, height: radiusY * 2)
                    .position(point)
            }
        case .rect:
            if let rect = localRect(annotation.rect) {
                Rectangle()
                    .stroke(DS.Colors.accent, lineWidth: 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
        case .line:
            if let start = localPoint(annotation.point), let end = localPoint(annotation.endPoint) {
                Path { path in
                    path.move(to: start)
                    path.addLine(to: end)
                }
                .stroke(DS.Colors.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            }
        case .label:
            if let point = localPoint(annotation.point), let label = annotation.label {
                annotationLabel(label).position(x: point.x, y: point.y)
            }
        case .spotlight:
            EmptyView()
        }
    }

    @ViewBuilder
    private func spotlight(_ annotation: PickyAgentAnnotation) -> some View {
        Canvas { context, size in
            var path = Path(CGRect(origin: .zero, size: size))
            if annotation.spotlightShape == .circle,
               let point = localPoint(annotation.point),
               let radius = annotation.radius {
                path.addEllipse(in: CGRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2))
            } else if let rect = localRect(annotation.rect) {
                path.addRect(rect)
            }
            // A transient dimmer is the one component-level visual exception: it
            // communicates the spotlight's excluded region rather than a status.
            context.fill(path, with: .color(Color.black.opacity(0.38)), style: FillStyle(eoFill: true))
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
    }

    private func annotationLabel(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(DS.Colors.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(DS.Colors.accent, lineWidth: 1))
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

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
