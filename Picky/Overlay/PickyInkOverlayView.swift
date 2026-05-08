//
//  PickyInkOverlayView.swift
//  Picky
//
//  Live semi-transparent freehand highlighter rendered while Picky owns mouse
//  input during PTT / Quick Input.
//

import SwiftUI

struct PickyInkOverlayView: View {
    let screenFrame: CGRect
    let state: PickyInkOverlayState

    @State private var feedbackPulse: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(strokesOnThisScreen) { stroke in
                SmoothInkStrokeShape(points: localPoints(for: stroke.points))
                    .stroke(
                        DS.Colors.overlayCursorBlue.opacity(stroke.opacity),
                        style: StrokeStyle(
                            lineWidth: stroke.strokeWidth,
                            lineCap: .round,
                            lineJoin: .round
                        )
                    )
                    .shadow(color: DS.Colors.overlayCursorBlue.opacity(0.18), radius: 4, x: 0, y: 0)
                    .blendMode(.normal)
                    .allowsHitTesting(false)
            }

            if let feedbackPoint = thresholdFeedbackPointOnThisScreen {
                Circle()
                    .stroke(DS.Colors.overlayCursorBlue.opacity(0.50 * (1.0 - feedbackPulse)), lineWidth: 1.4)
                    .frame(width: 24 + 28 * feedbackPulse, height: 24 + 28 * feedbackPulse)
                    .position(feedbackPoint)
                    .allowsHitTesting(false)
                    .onAppear {
                        feedbackPulse = 0
                        withAnimation(.easeOut(duration: 0.42)) {
                            feedbackPulse = 1
                        }
                    }
            }
        }
        .frame(width: screenFrame.width, height: screenFrame.height)
        .allowsHitTesting(false)
    }

    private var strokesOnThisScreen: [PickyInkOverlayStroke] {
        state.strokes.filter { stroke in
            stroke.points.contains { screenFrame.insetBy(dx: -1, dy: -1).contains($0) }
        }
    }

    private func localPoints(for points: [CGPoint]) -> [CGPoint] {
        points
            .filter { screenFrame.insetBy(dx: -1, dy: -1).contains($0) }
            .map { PickyOverlayGeometry.swiftUICoordinates(for: $0, in: screenFrame) }
    }

    private var thresholdFeedbackPointOnThisScreen: CGPoint? {
        guard state.didCrossThreshold,
              let feedbackPoint = state.thresholdFeedbackGlobalPoint,
              screenFrame.insetBy(dx: -1, dy: -1).contains(feedbackPoint) else { return nil }
        return PickyOverlayGeometry.swiftUICoordinates(for: feedbackPoint, in: screenFrame)
    }
}

private struct SmoothInkStrokeShape: Shape {
    let points: [CGPoint]

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: first)
        guard points.count > 2 else {
            for point in points.dropFirst() { path.addLine(to: point) }
            return path
        }

        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last { path.addLine(to: last) }
        return path
    }
}
