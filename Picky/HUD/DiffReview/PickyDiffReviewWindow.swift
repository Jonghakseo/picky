//
//  PickyDiffReviewWindow.swift
//  Picky
//

import AppKit
import WebKit

@MainActor
final class PickyDiffReviewPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class PickyDiffReviewWindowController: NSWindowController, NSWindowDelegate {
    private let onClose: () -> Void
    private var frameAutosaver: PickyDetachedPanelFrameAutosaver?

    init(
        host: PickyDiffReviewWebHost,
        title: String,
        frame: NSRect,
        frameAutosaver: PickyDetachedPanelFrameAutosaver,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose
        self.frameAutosaver = frameAutosaver

        let panel = PickyDiffReviewPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 900, height: 560)

        host.webView.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.webView.autoresizingMask = [.width, .height]
        panel.contentView = host.webView

        super.init(window: panel)
        panel.delegate = self
    }

    init(
        host: PickyDiffReviewWebHost,
        title: String,
        frame: NSRect,
        framePersister: PickyDetachedPanelFramePersister,
        onClose: @escaping () -> Void
    ) {
        self.onClose = onClose

        let panel = PickyDiffReviewPanel(
            contentRect: frame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.title = title
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.isExcludedFromWindowsMenu = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.titlebarAppearsTransparent = true
        panel.backgroundColor = PickyAppearancePanelChrome.windowBackground()
        panel.minSize = NSSize(width: 900, height: 560)

        self.frameAutosaver = PickyDetachedPanelFrameAutosaver(panel: panel, persister: framePersister)

        host.webView.frame = NSRect(origin: .zero, size: panel.frame.size)
        host.webView.autoresizingMask = [.width, .height]
        panel.contentView = host.webView

        super.init(window: panel)
        panel.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }

    static func targetFrame() -> NSRect {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1680, height: 1020)
        let width = min(CGFloat(1680), max(CGFloat(640), visibleFrame.width - 48))
        let height = min(CGFloat(1020), max(CGFloat(480), visibleFrame.height - 48))
        return NSRect(
            x: visibleFrame.midX - width / 2,
            y: visibleFrame.midY - height / 2,
            width: width,
            height: height
        )
    }
}
