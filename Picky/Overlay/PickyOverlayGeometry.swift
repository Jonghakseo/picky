//
//  PickyOverlayGeometry.swift
//  Picky
//
//  Pure geometry helpers shared by the cursor overlay.
//

import CoreGraphics

enum PickyOverlayGeometry {
    /// Converts a macOS screen point (AppKit, bottom-left origin) to SwiftUI
    /// coordinates (top-left origin) relative to the overlay window for `screenFrame`.
    static func swiftUICoordinates(for screenPoint: CGPoint, in screenFrame: CGRect) -> CGPoint {
        let x = screenPoint.x - screenFrame.origin.x
        let y = (screenFrame.origin.y + screenFrame.height) - screenPoint.y
        return CGPoint(x: x, y: y)
    }

    /// The Pi buddy sits slightly down/right from the physical cursor so it does
    /// not cover the exact click point.
    static func cursorBuddyPosition(
        for screenPoint: CGPoint,
        in screenFrame: CGRect,
        offset: CGSize = CGSize(width: 30, height: 20)
    ) -> CGPoint {
        let localPoint = swiftUICoordinates(for: screenPoint, in: screenFrame)
        return CGPoint(x: localPoint.x + offset.width, y: localPoint.y + offset.height)
    }

    /// Returns whether a detected pointer target should be handled by the overlay
    /// attached to `screenFrame`. The direct point match handles normal cases;
    /// display-frame overlap covers edge cases where the detector reports a display
    /// frame instead of a point inside the local screen's coordinate rect.
    static func targetBelongsToScreen(
        screenLocation: CGPoint,
        displayFrame: CGRect?,
        screenFrame: CGRect,
        tolerance: CGFloat = 1
    ) -> Bool {
        let expandedScreenFrame = screenFrame.insetBy(dx: -tolerance, dy: -tolerance)
        if expandedScreenFrame.contains(screenLocation) { return true }

        guard let displayFrame else { return false }
        let displayCenter = CGPoint(x: displayFrame.midX, y: displayFrame.midY)
        let screenCenter = CGPoint(x: screenFrame.midX, y: screenFrame.midY)
        return expandedScreenFrame.contains(displayCenter)
            || displayFrame.insetBy(dx: -tolerance, dy: -tolerance).contains(screenCenter)
    }

    static func clamped(_ point: CGPoint, to size: CGSize) -> CGPoint {
        CGPoint(
            x: max(0, min(point.x, size.width)),
            y: max(0, min(point.y, size.height))
        )
    }
}
