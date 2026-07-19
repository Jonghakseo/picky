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
    static func resolve(
        _ request: PickyAnnotationOverlayRequest,
        sampleGrid: PickyScreenshotColorSampleGrid? = nil,
        preferredBasePalette: PickyAnnotationPaletteRole? = nil
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
        let visualStyles = PickyAnnotationPaletteResolver.styles(
            for: request.annotations,
            screenshotSize: CGSize(width: screenshotSize.width, height: screenshotSize.height),
            sampleGrid: sampleGrid,
            preferredBasePalette: preferredBasePalette
        )
        return try request.annotations.map { annotation in
            try resolve(
                annotation,
                displayFrame: displayFrame,
                screenshotSize: screenshotSize,
                visualStyle: visualStyles[annotation.id] ?? .fallback
            )
        }
    }

    private static func resolve(
        _ annotation: PickyAnnotationOverlayAnnotation,
        displayFrame: CGRect,
        screenshotSize: PickyPointerScreenshotSize,
        visualStyle: PickyAnnotationVisualStyle
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
        switch annotation.shape {
        case .rect:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                rect: try rect(annotation, displayFrame: displayFrame, xScale: xScale, yScale: yScale),
                spotlight: annotation.spotlight ?? false,
                label: normalizedLabel(annotation.label),
                visualStyle: visualStyle
            )
        case .line:
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                point: try point(annotation.x1, annotation.y1, "x1", "y1"),
                endPoint: try point(annotation.x2, annotation.y2, "x2", "y2"),
                spotlight: annotation.spotlight ?? false,
                label: normalizedLabel(annotation.label),
                visualStyle: visualStyle
            )
        case .path:
            guard annotation.spotlight == nil else {
                throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotation.id, field: "spotlight")
            }
            return PickyAgentAnnotation(
                id: annotation.id,
                shape: annotation.shape,
                displayFrame: displayFrame,
                pathCommands: try pathCommands(annotation, point: point),
                label: normalizedLabel(annotation.label),
                visualStyle: visualStyle
            )
        }
    }

    private static func pathCommands(
        _ annotation: PickyAnnotationOverlayAnnotation,
        point: (Double?, Double?, String, String) throws -> CGPoint
    ) throws -> [PickyAgentAnnotationPathCommand] {
        guard let commands = annotation.commands,
              (2...32).contains(commands.count),
              commands.first?.type == .move,
              !commands.dropFirst().contains(where: { $0.type == .move }) else {
            throw PickyAnnotationOverlayResolveError.invalidGeometry(annotationID: annotation.id, field: "commands")
        }
        return try commands.enumerated().map { index, command in
            let destination = try point(command.x, command.y, "commands[\(index)].x", "commands[\(index)].y")
            switch command.type {
            case .move:
                return .move(destination)
            case .line:
                return .line(destination)
            case .cubic:
                let control1 = try point(command.c1x, command.c1y, "commands[\(index)].c1x", "commands[\(index)].c1y")
                let control2 = try point(command.c2x, command.c2y, "commands[\(index)].c2x", "commands[\(index)].c2y")
                return .cubic(to: destination, control1: control1, control2: control2)
            }
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
