//
//  PickyInkWindowContentHitTest.swift
//  Picky
//
//  Decides whether a Picky window actually renders hittable content at a
//  global point. Frame-based checks are not enough for ink pass-through:
//  Picky's transparent panels (e.g. the HUD, which reserves an invisible
//  card-width column beside the dock rail) let clicks fall through their
//  transparent pixels to the app underneath, so passing an ink mouse-down
//  "to the window" would really leak it to the browser below and let it
//  steal key focus from the Quick Input panel.
//

import AppKit

@MainActor
enum PickyInkWindowContentHitTest {
    /// True when `window` is visible and its view hierarchy claims the global
    /// point. `NSHostingView.hitTest` returns nil over regions where SwiftUI
    /// renders no hittable content, which is exactly the set of pixels the
    /// window server would click through.
    static func windowClaimsGlobalPoint(_ window: NSWindow, point: CGPoint) -> Bool {
        guard window.isVisible,
              window.frame.contains(point),
              let contentView = window.contentView else {
            return false
        }
        let windowPoint = window.convertPoint(fromScreen: point)
        let pointInSuperview = contentView.superview?.convert(windowPoint, from: nil) ?? windowPoint
        return contentView.hitTest(pointInSuperview) != nil
    }
}
