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

/// Whether a Picky highlight is over an arbitrary in-screen element
/// (where Picky should dim the surroundings) or over Picky's own HUD
/// chrome like the side-agent dock (where dimming would feel intrusive).
enum PickyDetectedHighlightKind: String, Codable, Equatable {
    case screenElement
    case hudDockIcon
}

enum PickyPointerCoordinateSpace: String, Codable, Equatable {
    /// Pixel coordinates in the captured screenshot image, top-left origin.
    case screenshotPixel
    /// Display point coordinates relative to the target display, top-left origin.
    case displayPoint
}

struct PickyPointerOverlayRequest: Codable, Equatable, Identifiable {
    let id: String
    let contextId: String?
    let sourceSessionId: String?
    let screenId: String?
    let screenIndex: Int?
    let x: Double
    let y: Double
    let coordinateSpace: PickyPointerCoordinateSpace
    let label: String?
    let durationMs: Int?
    let confidence: Double?
    let dryRun: Bool?
    let clamped: Bool?
    let screenBounds: PickyCGRect
    let screenshotSize: PickyPointerScreenshotSize?
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
}

enum PickyPointerOverlayResolveError: LocalizedError, Equatable {
    case invalidDisplayBounds
    case invalidScreenshotSize
    case invalidCoordinate

    var errorDescription: String? {
        switch self {
        case .invalidDisplayBounds:
            return "Pointer overlay request has invalid display bounds."
        case .invalidScreenshotSize:
            return "Pointer overlay request needs a positive screenshot size for screenshotPixel coordinates."
        case .invalidCoordinate:
            return "Pointer overlay request has non-finite coordinates."
        }
    }
}

enum PickyPointerOverlayResolver {
    static let defaultDuration: TimeInterval = 2.5
    static let minimumDuration: TimeInterval = 0.25
    static let maximumDuration: TimeInterval = 10.0

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
        let inputWidth: Double
        let inputHeight: Double
        switch request.coordinateSpace {
        case .screenshotPixel:
            guard let screenshotSize = request.screenshotSize,
                  screenshotSize.width > 0,
                  screenshotSize.height > 0 else {
                throw PickyPointerOverlayResolveError.invalidScreenshotSize
            }
            inputWidth = screenshotSize.width
            inputHeight = screenshotSize.height
        case .displayPoint:
            inputWidth = request.screenBounds.width
            inputHeight = request.screenBounds.height
        }

        let clampedX = clamp(request.x, lower: 0, upper: inputWidth)
        let clampedY = clamp(request.y, lower: 0, upper: inputHeight)
        let displayX = (clampedX / inputWidth) * request.screenBounds.width
        let displayYFromTop = (clampedY / inputHeight) * request.screenBounds.height
        let globalPoint = CGPoint(
            x: request.screenBounds.x + displayX,
            y: request.screenBounds.y + request.screenBounds.height - displayYFromTop
        )

        return PickyResolvedPointerOverlayTarget(
            screenLocation: globalPoint,
            displayFrame: displayFrame,
            bubbleText: normalizedBubbleText(request.label, confidence: request.confidence),
            duration: normalizedDuration(milliseconds: request.durationMs)
        )
    }

    private static func normalizedDuration(milliseconds: Int?) -> TimeInterval {
        guard let milliseconds else { return defaultDuration }
        let seconds = TimeInterval(milliseconds) / 1_000
        return clamp(seconds, lower: minimumDuration, upper: maximumDuration)
    }

    private static func normalizedBubbleText(_ label: String?, confidence: Double?) -> String? {
        let trimmed = label?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return nil }
        guard let confidence else { return trimmed }
        let boundedConfidence = clamp(confidence, lower: 0, upper: 1)
        return "\(trimmed) · \(Int((boundedConfidence * 100).rounded()))%"
    }

    private static func clamp<T: Comparable>(_ value: T, lower: T, upper: T) -> T {
        min(max(value, lower), upper)
    }
}
