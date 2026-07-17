//
//  PickyAnnotationOverlayResolver.swift
//  Picky
//
//  Converts agent-supplied screenshot-pixel annotation requests into global
//  AppKit geometry. It only resolves visual overlays and never synthesizes input.
//

import CoreGraphics
import Foundation

enum PickyAnnotationOverlayResolveError: LocalizedError, Equatable {
    case invalidDisplayBounds
    case invalidScreenshotSize
    case invalidGeometry(annotationID: String, field: String)

    var errorDescription: String? {
        switch self {
        case .invalidDisplayBounds:
            return "Annotation overlay request has invalid display bounds."
        case .invalidScreenshotSize:
            return "Annotation overlay request needs a positive screenshot size for screenshot-pixel coordinates."
        case .invalidGeometry(let annotationID, let field):
            return "Annotation \(annotationID) has invalid \(field) geometry."
        }
    }
}

enum PickyAnnotationOverlayResolver {
    static let defaultTTL: TimeInterval = 6

    static func resolve(
        _ request: PickyAnnotationOverlayRequest,
        now: Date = Date()
    ) throws -> [PickyAgentAnnotation] {
        guard let screenBounds = request.screenBounds, screenBounds.width > 0, screenBounds.height > 0 else {
            throw PickyAnnotationOverlayResolveError.invalidDisplayBounds
        }
        guard let screenshotSize = request.screenshotSize, screenshotSize.width > 0, screenshotSize.height > 0 else {
            throw PickyAnnotationOverlayResolveError.invalidScreenshotSize
        }

        let displayFrame = CGRect(
            x: screenBounds.x,
            y: screenBounds.y,
            width: screenBounds.width,
            height: screenBounds.height
        )
        return try request.annotations.map { annotation in
            try resolve(annotation, displayFrame: displayFrame, screenshotSize: screenshotSize, now: now)
        }
    }

    private static func resolve(
        _ annotation: PickyAnnotationOverlayAnnotation,
        displayFrame: CGRect,
        screenshotSize: PickyPointerScreenshotSize,
        now: Date
    ) throws -> PickyAgentAnnotation {
        let xScale = displayFrame.width / screenshotSize.width
        let yScale = displayFrame.height / screenshotSize.height
        let point = { (x: Double?, y: Double?, xField: String, yField: String) throws -> CGPoint in
            let sourceX = try finite(x, annotationID: annotation.id, field: xField)
            let sourceY = try finite(y, annotationID: annotation.id, field: yField)
            return CGPoint(
                x: displayFrame.minX + sourceX * xScale,
                y: displayFrame.maxY - sourceY * yScale
            )
        }
        let radius = { (value: Double?, field: String, scale: CGFloat) throws -> CGFloat in
            let source = try finite(value, annotationID: annotation.id, field: field)
            guard source >= 0 else { throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotation.id, field: field) }
            return source * scale
        }
        let expiresAt = now.addingTimeInterval((annotation.ttlMs ?? defaultTTL * 1_000) / 1_000)

        switch annotation.shape {
        case .target:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x, annotation.y, "x", "y"),
                radius: try radius(annotation.r, "r", min(xScale, yScale)),
                spotlightShape: nil,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        case .circle:
            let resolvedRadius: CGFloat?
            let resolvedRadiusX: CGFloat?
            let resolvedRadiusY: CGFloat?
            if let r = annotation.r {
                resolvedRadius = try radius(r, "r", min(xScale, yScale))
                resolvedRadiusX = nil
                resolvedRadiusY = nil
            } else {
                resolvedRadius = nil
                resolvedRadiusX = try radius(annotation.rx, "rx", xScale)
                resolvedRadiusY = try radius(annotation.ry, "ry", yScale)
            }
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x, annotation.y, "x", "y"),
                radius: resolvedRadius,
                radiusX: resolvedRadiusX,
                radiusY: resolvedRadiusY,
                spotlightShape: nil,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        case .rect:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                rect: try rect(annotation, displayFrame: displayFrame, xScale: xScale, yScale: yScale),
                spotlightShape: nil,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        case .line:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x1, annotation.y1, "x1", "y1"),
                endPoint: try point(annotation.x2, annotation.y2, "x2", "y2"),
                spotlightShape: nil,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        case .spotlight:
            guard let spotlightShape = annotation.spotlightShape else {
                throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotation.id, field: "spotlightShape")
            }
            if spotlightShape == .rect {
                return PickyAgentAnnotation(
                    id: annotation.id,
                    shape: annotation.shape,
                    displayFrame: displayFrame,
                    rect: try rect(annotation, displayFrame: displayFrame, xScale: xScale, yScale: yScale),
                    spotlightShape: spotlightShape,
                    label: normalizedLabel(annotation.label),
                    expiresAt: expiresAt
                )
            }
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x, annotation.y, "x", "y"),
                radius: try radius(annotation.r, "r", min(xScale, yScale)),
                spotlightShape: spotlightShape,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        case .label:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x, annotation.y, "x", "y"),
                spotlightShape: nil,
                label: normalizedLabel(annotation.label),
                expiresAt: expiresAt
            )
        }
    }

    private static func rect(
        _ annotation: PickyAnnotationOverlayAnnotation,
        displayFrame: CGRect,
        xScale: CGFloat,
        yScale: CGFloat
    ) throws -> CGRect {
        let x = try finite(annotation.x, annotationID: annotation.id, field: "x")
        let y = try finite(annotation.y, annotationID: annotation.id, field: "y")
        let width = try finite(annotation.w, annotationID: annotation.id, field: "w")
        let height = try finite(annotation.h, annotationID: annotation.id, field: "h")
        guard width >= 0, height >= 0 else {
            throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotation.id, field: "w/h")
        }
        return CGRect(
            x: displayFrame.minX + x * xScale,
            y: displayFrame.maxY - (y + height) * yScale,
            width: width * xScale,
            height: height * yScale
        )
    }

    private static func finite(_ value: Double?, annotationID: String, field: String) throws -> CGFloat {
        guard let value, value.isFinite else {
            throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotationID, field: field)
        }
        return CGFloat(value)
    }

    private static func normalizedLabel(_ label: String?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}
