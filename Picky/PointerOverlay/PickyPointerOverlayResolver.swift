//
//  PickyPointerOverlayResolver.swift
//  Picky
//
//  Converts agent-supplied visual-only pointer overlay requests into AppKit
//  global display coordinates. This file intentionally does not move, click,
//  drag, type, or synthesize any OS input events.
//

import CoreGraphics
import Foundation

/// Whether a Picky highlight is over an arbitrary in-screen element.
/// Picky always dims the surroundings to focus attention on the target.
enum PickyDetectedHighlightKind: String, Codable, Equatable {
    case screenElement
}

struct PickyPointerOverlayRequest: Codable, Equatable, Identifiable {
    let id: String
    let contextId: String?
    let contextGeneration: Int?
    let screenId: String?
    let x: Double
    let y: Double
    let r: Double?
    let label: String?
    let clamped: Bool?
    let screenBounds: PickyCGRect
    let screenshotSize: PickyPointerScreenshotSize
}

struct PickyPointerScreenshotSize: Codable, Equatable {
    let width: Double
    let height: Double
}

struct PickyResolvedPointerOverlayTarget: Equatable {
    let screenLocation: CGPoint
    let displayFrame: CGRect
    let bubbleText: String?
    let duration: TimeInterval
    let targetFrame: CGRect?
}

enum PickyPointerOverlayResolveError: LocalizedError, Equatable {
    case invalidDisplayBounds
    case invalidScreenshotSize
    case invalidCoordinate
    case invalidRadius

    var errorDescription: String? {
        switch self {
        case .invalidDisplayBounds:
            return "Pointer overlay request has invalid display bounds."
        case .invalidScreenshotSize:
            return "Pointer overlay request needs a positive screenshot size for screenshotPixel coordinates."
        case .invalidCoordinate:
            return "Pointer overlay request has non-finite coordinates."
        case .invalidRadius:
            return "Pointer overlay request has a non-finite highlight radius."
        }
    }
}

enum PickyPointerOverlayResolver {
    static let defaultDuration: TimeInterval = 1.0

    static func resolve(_ request: PickyPointerOverlayRequest) throws -> PickyResolvedPointerOverlayTarget {
        guard request.screenBounds.width > 0, request.screenBounds.height > 0 else {
            throw PickyPointerOverlayResolveError.invalidDisplayBounds
        }
        guard request.x.isFinite, request.y.isFinite else {
            throw PickyPointerOverlayResolveError.invalidCoordinate
        }

        let displayFrame = CGRect(
            x: request.screenBounds.x,
            y: request.screenBounds.y,
            width: request.screenBounds.width,
            height: request.screenBounds.height
        )
        guard request.screenshotSize.width > 0,
              request.screenshotSize.height > 0 else {
            throw PickyPointerOverlayResolveError.invalidScreenshotSize
        }

        let clampedX = clamp(request.x, lower: 0, upper: request.screenshotSize.width)
        let clampedY = clamp(request.y, lower: 0, upper: request.screenshotSize.height)
        let displayX = (clampedX / request.screenshotSize.width) * request.screenBounds.width
        let displayYFromTop = (clampedY / request.screenshotSize.height) * request.screenBounds.height
        let globalPoint = CGPoint(
            x: request.screenBounds.x + displayX,
            y: request.screenBounds.y + request.screenBounds.height - displayYFromTop
        )
        let targetFrame: CGRect?
        if let requestedRadius = request.r {
            guard requestedRadius.isFinite else { throw PickyPointerOverlayResolveError.invalidRadius }
            let radius = clamp(requestedRadius, lower: 0, upper: max(request.screenshotSize.width, request.screenshotSize.height))
            let radiusX = (radius / request.screenshotSize.width) * request.screenBounds.width
            let radiusY = (radius / request.screenshotSize.height) * request.screenBounds.height
            targetFrame = CGRect(
                x: globalPoint.x - radiusX,
                y: globalPoint.y - radiusY,
                width: radiusX * 2,
                height: radiusY * 2
            )
        } else {
            targetFrame = nil
        }

        return PickyResolvedPointerOverlayTarget(
            screenLocation: globalPoint,
            displayFrame: displayFrame,
            bubbleText: normalizedBubbleText(request.label),
            duration: defaultDuration,
            targetFrame: targetFrame
        )
    }

    private static func normalizedBubbleText(_ label: String?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        min(max(value, lower), upper)
    }
}
