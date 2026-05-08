//
//  PickyInkOverlayView.swift
//  Picky
//
//  Live semi-transparent freehand highlighter rendered while Picky owns mouse
//  input during PTT / Quick Input.
//

import QuartzCore
import SwiftUI

struct PickyInkOverlayView: View {
    let screenFrame: CGRect
    let state: PickyInkOverlayState

    /// Approx. lifetime in seconds for any cursor-trail entry. Must match the
    /// controller's value (`PickyInkCaptureController.trailLifetime`) so the
    /// fade aligns with the rate at which new points are captured.
    private let trailLifetime: TimeInterval = 0.45

    @State private var feedbackPulse: Double = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            cursorTrailLayer

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

    /// Fading ink trail painted behind the system cursor while ink mode is
    /// armed but no stroke is being actively drawn. The controller already
    /// drops the points whenever the user starts dragging; this view fades
    /// them out frame-by-frame against the live clock so a stationary mouse
    /// still shows a trail dissolving rather than freezing.
    @ViewBuilder
    private var cursorTrailLayer: some View {
        if !state.cursorTrailPoints.isEmpty {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { timeline in
                Canvas { context, _ in
                    drawCursorTrail(in: context, at: timeline.date)
                }
                .allowsHitTesting(false)
            }
        }
    }

    private func drawCursorTrail(in context: GraphicsContext, at frameDate: Date) {
        // CACurrentMediaTime aligns with capturedAt in the controller; convert
        // the timeline-provided wall-clock Date into the same domain.
        let now = CACurrentMediaTime() + frameDate.timeIntervalSinceNow
        let lifetime = trailLifetime
        let entries = state.cursorTrailPoints
            .filter { now - $0.capturedAt <= lifetime }
            .filter { screenFrame.insetBy(dx: -1, dy: -1).contains($0.point) }
        guard entries.count >= 2 else { return }

        for index in 1..<entries.count {
            let previous = entries[index - 1]
            let current = entries[index]
            let p1 = PickyOverlayGeometry.swiftUICoordinates(for: previous.point, in: screenFrame)
            let p2 = PickyOverlayGeometry.swiftUICoordinates(for: current.point, in: screenFrame)
            let segmentAge = max(now - current.capturedAt, 0)
            let life = max(0, 1 - segmentAge / lifetime)
            // Soft easing so the very tail dissolves instead of clipping.
            let intensity = life * life
            let opacity = 0.55 * intensity
            let lineWidth = 1.5 + 4.5 * intensity

            var path = Path()
            path.move(to: p1)
            path.addLine(to: p2)
            context.stroke(
                path,
                with: .color(DS.Colors.overlayCursorBlue.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            )
        }
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
