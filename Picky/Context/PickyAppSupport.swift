//
//  PickyAppSupport.swift
//  Picky
//

import AppKit
import Foundation

enum PickyAppSupport {
    static func defaultRoot() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("Picky", isDirectory: true)
    }

    /// Default location for transient screenshot bytes captured during a Picky
    /// turn. We deliberately route this through `FileManager.temporaryDirectory`
    /// (Apple docs: https://developer.apple.com/documentation/foundation/filemanager/1642996-temporarydirectory)
    /// so screen capture data does not accumulate inside the durable
    /// `Application Support/Picky` tree alongside settings and session metadata.
    static func screenshotsRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Picky", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)
    }
}

struct PickyAppSupportScreenshotStore: PickyScreenshotStoring {
    let screenshotsRoot: URL
    let fileManager: FileManager

    init(screenshotsRoot: URL = PickyAppSupport.screenshotsRoot(), fileManager: FileManager = .default) {
        self.screenshotsRoot = screenshotsRoot
        self.fileManager = fileManager
    }

    func store(_ screen: PickyScreenContext, contextID: String, index: Int) throws -> PickyScreenshotContext {
        let directory = screenshotsRoot
            .appendingPathComponent(contextID, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let id = "shot-\(index + 1)"
        let fileURL = directory.appendingPathComponent("\(id).jpg")
        if let imageData = screen.imageData {
            let dataToStore = annotatedImageData(from: imageData, inkMarks: screen.inkMarks) ?? imageData
            try dataToStore.write(to: fileURL, options: .atomic)
        } else if !fileManager.fileExists(atPath: fileURL.path) {
            try Data().write(to: fileURL, options: .atomic)
        }

        return PickyScreenshotContext(
            id: id,
            label: screen.label,
            path: fileURL.path,
            screenId: "screen\(index + 1)",
            bounds: screen.frame,
            screenshotWidthInPixels: screen.screenshotWidthInPixels,
            screenshotHeightInPixels: screen.screenshotHeightInPixels,
            isCursorScreen: screen.isCursorScreen,
            cursor: screen.cursor
        )
    }

    private func annotatedImageData(from imageData: Data, inkMarks: [PickyInkMarkContext]) -> Data? {
        guard !inkMarks.isEmpty else { return imageData }
        guard let image = NSImage(data: imageData),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }

        let width = cgImage.width
        let height = cgImage.height
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = context

        let rect = NSRect(x: 0, y: 0, width: width, height: height)
        NSImage(cgImage: cgImage, size: rect.size).draw(in: rect)

        for (index, mark) in inkMarks.enumerated() {
            draw(mark: mark, index: index + 1, imageHeight: CGFloat(height))
        }

        return bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    private func draw(mark: PickyInkMarkContext, index: Int, imageHeight: CGFloat) {
        let points = mark.points.map { point in
            CGPoint(x: point.x, y: imageHeight - point.y)
        }
        guard points.count >= 2 else { return }

        let path = smoothedPath(points: points)
        NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.0, alpha: CGFloat(mark.opacity)).setStroke()
        path.lineWidth = CGFloat(mark.strokeWidth)
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()

        if let first = points.first {
            drawIndexBadge(index, near: first)
        }
    }

    private func smoothedPath(points: [CGPoint]) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: points[0])
        guard points.count > 2 else {
            for point in points.dropFirst() { path.line(to: point) }
            return path
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            path.curve(to: midpoint, controlPoint1: previous, controlPoint2: previous)
        }
        if let last = points.last { path.line(to: last) }
        return path
    }

    private func drawIndexBadge(_ index: Int, near point: CGPoint) {
        let badgeSize = CGSize(width: 22, height: 22)
        let rect = CGRect(
            x: point.x - badgeSize.width / 2,
            y: point.y - badgeSize.height / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )
        let badgePath = NSBezierPath(ovalIn: rect)
        NSColor(calibratedRed: 0.20, green: 0.50, blue: 1.0, alpha: 0.88).setFill()
        badgePath.fill()
        NSColor.white.setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()

        let text = "\(index)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white
        ]
        let textSize = text.size(withAttributes: attributes)
        text.draw(
            at: CGPoint(x: rect.midX - textSize.width / 2, y: rect.midY - textSize.height / 2),
            withAttributes: attributes
        )
    }
}
