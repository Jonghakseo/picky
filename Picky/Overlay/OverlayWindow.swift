//
//  OverlayWindow.swift
//  Picky
//
//  Transparent per-screen overlay window.
//

import AppKit

extension NSWindow.Level {
    /// Keep the Picky cursor overlay above the markdown report panel
    /// (`PickyReportPanel` uses `.screenSaver + 1`). The overlay window sets
    /// `ignoresMouseEvents = true`, so click/drag events still pass through
    /// to the report panel below — only the z-order is bumped here so the
    /// blue cursor stays visible while a report is open.
    static let pickyCursorOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
}

class OverlayWindow: NSWindow {
    init(screen: NSScreen) {
        // Create window covering entire screen
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        self.level = .pickyCursorOverlay  // Above report panels and submenus/popups
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen
        self.setFrame(screen.frame, display: true)

        // Make sure it's on the right screen
        if let screenForWindow = NSScreen.screens.first(where: { $0.frame == screen.frame }) {
            self.setFrameOrigin(screenForWindow.frame.origin)
        }
    }

    // Prevent window from becoming key (no focus stealing)
    override var canBecomeKey: Bool {
        return false
    }

    override var canBecomeMain: Bool {
        return false
    }
}
