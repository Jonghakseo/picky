//
//  PickyInkContext.swift
//  Picky
//
//  User-drawn screen marks captured during PTT / Quick Input. Ink marks are
//  neutral desktop context: they describe where the user pointed with Picky's
//  cursor without triggering any workflow routing in the app.
//

import CoreGraphics
import Foundation

enum PickyInkCaptureSource: String, Codable, Equatable {
    case voice
    case text
}

struct PickyInkCapture: Equatable {
    let id: String
    let source: PickyInkCaptureSource
    let startedAt: Date
    let endedAt: Date
    let strokes: [PickyInkCaptureStroke]

    var hasVisibleInk: Bool { strokes.contains { $0.points.count >= 2 } }
}

struct PickyInkCaptureStroke: Equatable, Identifiable {
    let id: String
    let source: PickyInkCaptureSource
    /// Global AppKit screen points, bottom-left origin across the desktop.
    let points: [PickyCGPoint]
    /// Stroke width in display points. Converted to screenshot pixels per screen.
    let strokeWidth: Double
    /// Visual opacity used both for the live overlay and annotated screenshots.
    let opacity: Double
}

struct PickyInkOverlayState: Equatable {
    static let inactive = PickyInkOverlayState(
        isActive: false,
        source: nil,
        virtualCursorGlobalPoint: nil,
        strokes: [],
        didCrossThreshold: false,
        thresholdFeedbackGlobalPoint: nil,
        cursorTrailPoints: []
    )

    let isActive: Bool
    let source: PickyInkCaptureSource?
    /// Global AppKit screen point for the hidden-system-cursor replacement.
    let virtualCursorGlobalPoint: CGPoint?
    let strokes: [PickyInkOverlayStroke]
    let didCrossThreshold: Bool
    let thresholdFeedbackGlobalPoint: CGPoint?
    /// Recent virtual-cursor positions used to paint a fading ink trail behind
    /// the system pointer. The view filters expired entries against the live
    /// clock; the controller only appends + clears, never expires.
    let cursorTrailPoints: [PickyInkCursorTrailPoint]
}

struct PickyInkOverlayStroke: Equatable, Identifiable {
    let id: String
    let points: [CGPoint]
    let strokeWidth: CGFloat
    let opacity: Double
}

struct PickyInkCursorTrailPoint: Equatable, Identifiable {
    let id: UUID
    /// Global AppKit screen point.
    let point: CGPoint
    /// `CACurrentMediaTime` at capture, used by the renderer to compute fade.
    let capturedAt: TimeInterval
}

struct PickyInkMarkContext: Codable, Equatable, Identifiable {
    let id: String
    let source: PickyInkCaptureSource
    let kind: String
    let screenId: String?
    /// Freehand stroke points in screenshot pixel coordinates, top-left origin.
    let points: [PickyCGPoint]
    /// Bounding box in screenshot pixel coordinates, top-left origin.
    let bounds: PickyCGRect
    /// Stroke width in screenshot pixels.
    let strokeWidth: Double
    /// Stroke opacity. Kept below 1 so underlying content remains visible.
    let opacity: Double

    init(
        id: String,
        source: PickyInkCaptureSource,
        kind: String = "freehand-highlight",
        screenId: String?,
        points: [PickyCGPoint],
        bounds: PickyCGRect,
        strokeWidth: Double,
        opacity: Double
    ) {
        self.id = id
        self.source = source
        self.kind = kind
        self.screenId = screenId
        self.points = points
        self.bounds = bounds
        self.strokeWidth = strokeWidth
        self.opacity = opacity
    }
}

enum PickyInkMarkMapper {
    static func map(
        capture: PickyInkCapture?,
        to screen: CompanionScreenCapture,
        screenId: String
    ) -> [PickyInkMarkContext] {
        guard let capture, capture.hasVisibleInk else { return [] }
        return capture.strokes.flatMap { stroke in
            map(stroke: stroke, to: screen, screenId: screenId)
        }
    }

    private static func map(
        stroke: PickyInkCaptureStroke,
        to screen: CompanionScreenCapture,
        screenId: String
    ) -> [PickyInkMarkContext] {
        let displayFrame = screen.displayFrame
        let screenshotSize = CGSize(width: screen.screenshotWidthInPixels, height: screen.screenshotHeightInPixels)
        guard displayFrame.width > 0, displayFrame.height > 0,
              screenshotSize.width > 0, screenshotSize.height > 0 else { return [] }

        let clippedPointLists = clippedPointLists(for: stroke.points, to: displayFrame)
        let averageScale = ((screenshotSize.width / displayFrame.width) + (screenshotSize.height / displayFrame.height)) / 2
        return clippedPointLists.enumerated().map { index, points in
            let screenshotPoints = points.map {
                screenshotPixel(for: $0, displayFrame: displayFrame, screenshotSize: screenshotSize)
            }
            return PickyInkMarkContext(
                id: clippedPointLists.count == 1 ? stroke.id : "\(stroke.id)-\(index + 1)",
                source: stroke.source,
                screenId: screenId,
                points: screenshotPoints.map(PickyCGPoint.init),
                bounds: PickyCGRect(boundingRect(for: screenshotPoints)),
                strokeWidth: max(1, stroke.strokeWidth * Double(averageScale)),
                opacity: stroke.opacity
            )
        }
    }

    private static func clippedPointLists(for points: [PickyCGPoint], to rect: CGRect) -> [[CGPoint]] {
        var clippedPointLists: [[CGPoint]] = []
        var currentPointList: [CGPoint] = []

        for (start, end) in zip(points, points.dropFirst()) {
            guard let clippedSegment = clippedSegment(
                from: CGPoint(x: start.x, y: start.y),
                to: CGPoint(x: end.x, y: end.y),
                to: rect
            ) else {
                if currentPointList.count >= 2 {
                    clippedPointLists.append(currentPointList)
                }
                currentPointList = []
                continue
            }

            if currentPointList.last == clippedSegment.start {
                currentPointList.append(clippedSegment.end)
            } else {
                if currentPointList.count >= 2 {
                    clippedPointLists.append(currentPointList)
                }
                currentPointList = [clippedSegment.start, clippedSegment.end]
            }
        }

        if currentPointList.count >= 2 {
            clippedPointLists.append(currentPointList)
        }
        return clippedPointLists
    }

    private static func clippedSegment(from start: CGPoint, to end: CGPoint, to rect: CGRect) -> (start: CGPoint, end: CGPoint)? {
        let deltaX = end.x - start.x
        let deltaY = end.y - start.y
        var minimumT = 0.0
        var maximumT = 1.0

        for (p, q) in [
            (-deltaX, start.x - rect.minX),
            (deltaX, rect.maxX - start.x),
            (-deltaY, start.y - rect.minY),
            (deltaY, rect.maxY - start.y)
        ] {
            if p == 0 {
                guard q >= 0 else { return nil }
                continue
            }

            let t = q / p
            if p < 0 {
                minimumT = max(minimumT, t)
            } else {
                maximumT = min(maximumT, t)
            }
            guard minimumT <= maximumT else { return nil }
        }

        let clippedStart = CGPoint(x: start.x + minimumT * deltaX, y: start.y + minimumT * deltaY)
        let clippedEnd = CGPoint(x: start.x + maximumT * deltaX, y: start.y + maximumT * deltaY)
        guard clippedStart != clippedEnd else { return nil }
        return (clippedStart, clippedEnd)
    }

    private static func screenshotPixel(
        for globalPoint: CGPoint,
        displayFrame: CGRect,
        screenshotSize: CGSize
    ) -> CGPoint {
        let displayLocalX = globalPoint.x - displayFrame.origin.x
        let displayLocalYFromBottom = globalPoint.y - displayFrame.origin.y
        let displayYFromTop = displayFrame.height - displayLocalYFromBottom
        return CGPoint(
            x: displayLocalX * screenshotSize.width / max(displayFrame.width, 1),
            y: displayYFromTop * screenshotSize.height / max(displayFrame.height, 1)
        )
    }

    private static func boundingRect(for points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .zero }
        var minX = first.x
        var maxX = first.x
        var minY = first.y
        var maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x)
            maxX = max(maxX, point.x)
            minY = min(minY, point.y)
            maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: max(1, maxX - minX), height: max(1, maxY - minY))
    }
}
