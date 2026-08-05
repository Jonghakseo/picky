//
//  PickyHUDInkPassThroughPolicy.swift
//  Picky
//
//  Converts SwiftUI-reported HUD chrome bounds (dock rail, conversation card)
//  into AppKit screen space for global ink-capture routing. The HUD's
//  transparent NSPanel reserves an invisible card-width column beside the dock
//  rail; only visibly rendered chrome may claim an ink gesture, because a
//  click on transparent pixels falls through to the app underneath and steals
//  key focus mid-ink.
//

import CoreGraphics

enum PickyHUDInkPassThroughPolicy {
    /// Translates frames measured in the HUD root's top-left SwiftUI
    /// coordinate space into bottom-left AppKit screen rects.
    static func screenRects(
        swiftUIFrames: [CGRect],
        panelFrame: CGRect
    ) -> [CGRect] {
        guard isUsable(panelFrame) else { return [] }
        return swiftUIFrames.compactMap { frame in
            guard isUsable(frame) else { return nil }
            return CGRect(
                x: panelFrame.minX + frame.minX,
                y: panelFrame.maxY - frame.maxY,
                width: frame.width,
                height: frame.height
            )
        }
    }

    static func contains(
        _ screenPoint: CGPoint,
        swiftUIFrames: [CGRect],
        panelFrame: CGRect
    ) -> Bool {
        guard screenPoint.x.isFinite, screenPoint.y.isFinite else { return false }
        return screenRects(swiftUIFrames: swiftUIFrames, panelFrame: panelFrame)
            .contains { $0.contains(screenPoint) }
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        !rect.isNull
            && !rect.isInfinite
            && rect.width > 0
            && rect.height > 0
            && rect.minX.isFinite
            && rect.minY.isFinite
            && rect.maxX.isFinite
            && rect.maxY.isFinite
    }
}
