//
//  PickyFullscreenWindow.swift
//  Picky
//
//  AppKit window used by the fullscreen workspace shell.
//

import AppKit

final class PickyFullscreenWindow: NSWindow, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePickyCloseWindowShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }

    override func sendEvent(_ event: NSEvent) {
        if handlePickyCloseWindowShortcut(event) { return }
        super.sendEvent(event)
    }
}
