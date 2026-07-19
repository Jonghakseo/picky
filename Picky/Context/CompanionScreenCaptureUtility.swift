//
//  CompanionScreenCaptureUtility.swift
//  Picky
//
//  Standalone screenshot capture for the companion voice flow.
//  Decoupled from the legacy ScreenshotManager so the companion mode
//  can capture screenshots independently without session state.
//

import AppKit
import CoreGraphics
import ScreenCaptureKit

/// Marker for Picky-owned chrome that should stay visible to the user but be
/// omitted from screenshots sent as model context. Artifact viewers such as the
/// markdown report panel and Pi terminal deliberately do not conform so the
/// model can still inspect them when the user asks about their contents.
protocol PickyScreenCaptureExcludedWindow: AnyObject {}

struct CompanionScreenCapture {
    let imageData: Data
    let label: String
    let isCursorScreen: Bool
    let displayWidthInPoints: Int
    let displayHeightInPoints: Int
    let displayFrame: CGRect
    let screenshotWidthInPixels: Int
    let screenshotHeightInPixels: Int
    let cursor: PickyCursorContext?
    /// App-local downsample used only to choose readable annotation colors.
    /// The neutral context payload never encodes or sends these pixels.
    let annotationColorSampleGrid: PickyScreenshotColorSampleGrid?
    /// Cursor-free raw-image baseline for annotation-scene visual validation.
    /// The neutral context payload never encodes or sends these pixels.
    let annotationSceneFingerprint: PickyAnnotationSceneFingerprint?

    init(
        imageData: Data,
        label: String,
        isCursorScreen: Bool,
        displayWidthInPoints: Int,
        displayHeightInPoints: Int,
        displayFrame: CGRect,
        screenshotWidthInPixels: Int,
        screenshotHeightInPixels: Int,
        cursor: PickyCursorContext?,
        annotationColorSampleGrid: PickyScreenshotColorSampleGrid? = nil,
        annotationSceneFingerprint: PickyAnnotationSceneFingerprint? = nil
    ) {
        self.imageData = imageData
        self.label = label
        self.isCursorScreen = isCursorScreen
        self.displayWidthInPoints = displayWidthInPoints
        self.displayHeightInPoints = displayHeightInPoints
        self.displayFrame = displayFrame
        self.screenshotWidthInPixels = screenshotWidthInPixels
        self.screenshotHeightInPixels = screenshotHeightInPixels
        self.cursor = cursor
        self.annotationColorSampleGrid = annotationColorSampleGrid
        self.annotationSceneFingerprint = annotationSceneFingerprint
    }
}

@MainActor
enum CompanionScreenCaptureUtility {
    static let annotationSceneFingerprintMaximumDimension = 256

    static func shouldExcludeWindowFromContextCapture(_ window: NSWindow) -> Bool {
        window is PickyScreenCaptureExcludedWindow
    }

    static func contextCaptureExcludedWindowIDs(in windows: [NSWindow]) -> Set<CGWindowID> {
        Set(windows.compactMap { window in
            guard shouldExcludeWindowFromContextCapture(window), window.windowNumber > 0 else { return nil }
            return CGWindowID(window.windowNumber)
        })
    }

    nonisolated static func annotationSceneFingerprintPixelSize(
        displayWidth: Int,
        displayHeight: Int
    ) -> (width: Int, height: Int) {
        capturePixelSize(
            displayWidth: displayWidth,
            displayHeight: displayHeight,
            maximumDimension: annotationSceneFingerprintMaximumDimension
        )
    }

    nonisolated static func capturePixelSize(
        displayWidth: Int,
        displayHeight: Int,
        maximumDimension: Int
    ) -> (width: Int, height: Int) {
        let clampedMaximumDimension = max(1, maximumDimension)
        guard displayWidth > 0, displayHeight > 0 else {
            return (clampedMaximumDimension, clampedMaximumDimension)
        }

        let aspectRatio = CGFloat(displayWidth) / CGFloat(displayHeight)
        if displayWidth >= displayHeight {
            return (
                width: clampedMaximumDimension,
                height: max(1, Int(CGFloat(clampedMaximumDimension) / aspectRatio))
            )
        }

        return (
            width: max(1, Int(CGFloat(clampedMaximumDimension) * aspectRatio)),
            height: clampedMaximumDimension
        )
    }

    /// Captures all connected displays as JPEG data, labeling each with
    /// whether the user's cursor is on that screen. This gives the AI
    /// full context across multiple monitors.
    static func captureAllScreensAsJPEG(maximumDimension: Int = PickyScreenshotQuality.defaultMaximumDimension) async throws -> [CompanionScreenCapture] {
        try await captureScreensAsJPEG(scope: .allScreens, maximumDimension: maximumDimension)
    }

    /// Captures the user-configured screen context scope as JPEG data.
    /// The focused screen is the display containing the physical cursor at capture time.
    static func captureScreensAsJPEG(
        scope: PickyScreenContextScope,
        maximumDimension: Int = PickyScreenshotQuality.defaultMaximumDimension
    ) async throws -> [CompanionScreenCapture] {
        guard !PickyRuntimeEnvironment.isRunningUnitTests else {
            throw NSError(
                domain: "CompanionScreenCapture",
                code: -1000,
                userInfo: [NSLocalizedDescriptionKey: "Screen capture is disabled while running unit tests"]
            )
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

        guard !content.displays.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "No display available for capture"])
        }

        let mouseLocation = NSEvent.mouseLocation

        // Exclude Picky-owned control chrome (cursor overlays, HUD/dock, and
        // transient input panels) while leaving artifact viewers such as the
        // markdown report panel and Pi terminal visible for model inspection.
        let excludedContextWindowIDs = contextCaptureExcludedWindowIDs(in: NSApp.windows)
        let excludedContextWindows = content.windows.filter { window in
            excludedContextWindowIDs.contains(window.windowID)
        }

        // Build a lookup from display ID to NSScreen so we can use AppKit-coordinate
        // frames instead of CG-coordinate frames. NSEvent.mouseLocation and NSScreen.frame
        // both use AppKit coordinates (bottom-left origin), while SCDisplay.frame uses
        // Core Graphics coordinates (top-left origin). On multi-display setups, the Y
        // origins differ for secondary displays, which breaks cursor-contains checks
        // and downstream coordinate conversions.
        var nsScreenByDisplayID: [CGDirectDisplayID: NSScreen] = [:]
        for screen in NSScreen.screens {
            if let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID {
                nsScreenByDisplayID[screenNumber] = screen
            }
        }

        // Sort displays so the cursor screen is always first
        let sortedDisplays = content.displays.sorted { displayA, displayB in
            let frameA = nsScreenByDisplayID[displayA.displayID]?.frame ?? displayA.frame
            let frameB = nsScreenByDisplayID[displayB.displayID]?.frame ?? displayB.frame
            let aContainsCursor = frameA.contains(mouseLocation)
            let bContainsCursor = frameB.contains(mouseLocation)
            if aContainsCursor != bContainsCursor { return aContainsCursor }
            return false
        }

        let displaysToCapture: [SCDisplay]
        switch scope {
        case .allScreens:
            displaysToCapture = sortedDisplays
        case .focusedScreen:
            let focusedDisplays = sortedDisplays.filter { display in
                let frame = nsScreenByDisplayID[display.displayID]?.frame ?? display.frame
                return frame.contains(mouseLocation)
            }
            displaysToCapture = focusedDisplays.isEmpty ? Array(sortedDisplays.prefix(1)) : focusedDisplays
        }

        var capturedScreens: [CompanionScreenCapture] = []

        for (displayIndex, display) in displaysToCapture.enumerated() {
            // Use NSScreen.frame (AppKit coordinates, bottom-left origin) so
            // displayFrame is in the same coordinate system as NSEvent.mouseLocation
            // and the overlay window's screenFrame in BlueCursorView.
            let displayFrame = nsScreenByDisplayID[display.displayID]?.frame
                ?? CGRect(x: display.frame.origin.x, y: display.frame.origin.y,
                          width: CGFloat(display.width), height: CGFloat(display.height))
            let isCursorScreen = displayFrame.contains(mouseLocation)

            let filter = SCContentFilter(display: display, excludingWindows: excludedContextWindows)

            let configuration = SCStreamConfiguration()
            let pixelSize = capturePixelSize(
                displayWidth: display.width,
                displayHeight: display.height,
                maximumDimension: maximumDimension
            )
            configuration.width = pixelSize.width
            configuration.height = pixelSize.height
            configuration.showsCursor = false

            let cgImage = try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )

            let fingerprintSize = annotationSceneFingerprintPixelSize(
                displayWidth: display.width,
                displayHeight: display.height
            )
            guard let annotationSceneFingerprint = PickyAnnotationSceneFingerprint.make(
                from: cgImage,
                width: fingerprintSize.width,
                height: fingerprintSize.height
            ) else {
                continue
            }

            let cursorContext: PickyCursorContext?
            if isCursorScreen {
                let displayLocalX = mouseLocation.x - displayFrame.origin.x
                let displayLocalYFromBottom = mouseLocation.y - displayFrame.origin.y
                let displayPoint = CGPoint(
                    x: displayLocalX,
                    y: displayFrame.height - displayLocalYFromBottom
                )
                let screenshotPixel = CGPoint(
                    x: displayPoint.x * CGFloat(configuration.width) / max(displayFrame.width, 1),
                    y: displayPoint.y * CGFloat(configuration.height) / max(displayFrame.height, 1)
                )
                cursorContext = PickyCursorContext(
                    globalPoint: PickyCGPoint(mouseLocation),
                    displayPoint: PickyCGPoint(displayPoint),
                    screenshotPixel: PickyCGPoint(screenshotPixel)
                )
            } else {
                cursorContext = nil
            }

            let modelContextImage = cursorContext.map { imageWithCursorMarker(on: cgImage, cursor: $0) } ?? cgImage
            guard let jpegData = NSBitmapImageRep(cgImage: modelContextImage)
                    .representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else {
                continue
            }

            let screenLabel: String
            if scope == .focusedScreen {
                screenLabel = isCursorScreen
                    ? "focused screen — cursor is on this screen (primary focus)"
                    : "focused screen — fallback display"
            } else if displaysToCapture.count == 1 {
                screenLabel = "user's screen (cursor is here)"
            } else if isCursorScreen {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — cursor is on this screen (primary focus)"
            } else {
                screenLabel = "screen \(displayIndex + 1) of \(displaysToCapture.count) — secondary screen"
            }

            capturedScreens.append(CompanionScreenCapture(
                imageData: jpegData,
                label: screenLabel,
                isCursorScreen: isCursorScreen,
                displayWidthInPoints: Int(displayFrame.width),
                displayHeightInPoints: Int(displayFrame.height),
                displayFrame: displayFrame,
                screenshotWidthInPixels: configuration.width,
                screenshotHeightInPixels: configuration.height,
                cursor: cursorContext,
                annotationColorSampleGrid: PickyScreenshotColorSampleGrid.make(from: cgImage),
                annotationSceneFingerprint: annotationSceneFingerprint
            ))
        }

        guard !capturedScreens.isEmpty else {
            throw NSError(domain: "CompanionScreenCapture", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to capture any screen"])
        }

        return capturedScreens
    }

    private static func imageWithCursorMarker(on image: CGImage, cursor: PickyCursorContext) -> CGImage {
        let width = image.width
        let height = image.height
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let center = CGPoint(
            x: min(max(cursor.screenshotPixel.x, 0), Double(width - 1)),
            y: min(max(Double(height) - cursor.screenshotPixel.y, 0), Double(height - 1))
        )
        let markerRect = CGRect(x: center.x - 7, y: center.y - 7, width: 14, height: 14)
        context.setStrokeColor(CGColor(gray: 0, alpha: 0.9))
        context.setLineWidth(4)
        context.strokeEllipse(in: markerRect)
        context.setStrokeColor(CGColor(red: 0.2, green: 0.5, blue: 1, alpha: 1))
        context.setLineWidth(2)
        context.strokeEllipse(in: markerRect)
        return context.makeImage() ?? image
    }
}
