//
//  OverlayWindow.swift
//  Picky
//
//  Transparent per-screen overlay window.
//

import AppKit

extension NSWindow.Level {
    /// Sit just below `.screenSaver` (1000) so the system lock screen and
    /// screen saver can still cover the blue cursor, while remaining above
    /// every normal app surface — including the markdown report panel
    /// (`PickyReportPanel` uses default `.normal`) and any submenu/popup
    /// (`.popUpMenu` = 101). The overlay window sets `ignoresMouseEvents = true`,
    /// so click/drag events still pass through to whatever is below.
    static let pickyCursorOverlay = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue - 1)
}

class OverlayWindow: NSPanel, PickyScreenCaptureExcludedWindow {
    init(screen: NSScreen) {
        // A/B debug flag: shrink the overlay to a small corner frame to test
        // whether purchase-sheet suppression depends on overlapping the sheet.
        let overlayFrame = UserDefaults.standard.bool(forKey: "PickyDebugCursorOverlayShrunk")
            ? NSRect(origin: screen.frame.origin, size: NSSize(width: 400, height: 400))
            : screen.frame
        // Create a non-activating panel covering the entire screen. A plain
        // NSWindow can interfere with command-key keyDown dispatch while the
        // screen-context cursor overlay is visible; keep this overlay visually
        // frontmost without participating in key-window routing.
        super.init(
            contentRect: overlayFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Make window transparent and non-interactive
        self.isOpaque = false
        self.backgroundColor = .clear
        // A/B debug flag: override the window level (e.g. 3 = floating,
        // 101 = popUpMenu) to test whether suppression depends on level.
        if let levelOverride = UserDefaults.standard.object(forKey: "PickyDebugCursorOverlayLevel") as? Int {
            self.level = NSWindow.Level(rawValue: levelOverride)
        } else {
            self.level = .pickyCursorOverlay  // Above report panels and submenus/popups, below the lock screen
        }
        self.ignoresMouseEvents = true  // Click-through
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        self.isReleasedWhenClosed = false
        self.hasShadow = false
        // Keep the always-on cursor chrome out of macOS' built-in window
        // capture target. Without this, Screenshot's "selected window" mode can
        // choose the transparent full-screen panel and save a black image with
        // only the Picky cursor.
        self.sharingType = .none

        // Important: Allow the window to appear even when app is not active
        self.hidesOnDeactivate = false

        // Cover the entire screen (or the shrunk A/B test frame)
        self.setFrame(overlayFrame, display: true)

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
