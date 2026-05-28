//
//  PickyFullscreenWindowController.swift
//  Picky
//
//  Strongly owns the fullscreen workspace window and reports AppKit close
//  events back to the coordinator exactly once.
//

import AppKit
import SwiftUI

@MainActor
final class PickyFullscreenWindowController: NSWindowController, NSWindowDelegate {
    let appearanceStore: PickyAppearanceStore
    let fontScaleStore: PickyAppFontScaleStore
    private let onClose: @MainActor (PickyFullscreenWindowController) -> Void
    private var didReportClose = false

    init(
        viewModel: PickySessionListViewModel,
        stateStore: PickyFullscreenStateStore,
        appearanceStore: PickyAppearanceStore,
        fontScaleStore: PickyAppFontScaleStore,
        onClose: @escaping @MainActor (PickyFullscreenWindowController) -> Void
    ) {
        self.appearanceStore = appearanceStore
        self.fontScaleStore = fontScaleStore
        self.onClose = onClose

        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let initialSize = NSSize(
            width: min(max(visibleFrame.width * 0.86, 1040), visibleFrame.width),
            height: min(max(visibleFrame.height * 0.86, 680), visibleFrame.height)
        )
        let initialFrame = NSRect(
            x: visibleFrame.midX - initialSize.width / 2,
            y: visibleFrame.midY - initialSize.height / 2,
            width: initialSize.width,
            height: initialSize.height
        )

        let window = PickyFullscreenWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Picky Workspace"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.minSize = NSSize(width: 1040, height: 680)
        let rootView = PickyAppFontScaleRoot(store: fontScaleStore) {
            PickyFullscreenWorkspaceView(viewModel: viewModel, stateStore: stateStore)
                .environmentObject(appearanceStore)
                .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))
        }
        window.contentView = NSHostingView(
            rootView: LocalizedHostingRoot { rootView }
        )

        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        guard let window else { return }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func closeWindow() {
        guard !didReportClose else { return }
        window?.performClose(nil)
    }

    func windowWillClose(_ notification: Notification) {
        reportCloseAfterTeardownIfNeeded()
    }

    private func reportCloseAfterTeardownIfNeeded() {
        guard !didReportClose else { return }
        didReportClose = true

        tearDownHostedWindow()

        Task { @MainActor [self] in
            onClose(self)
        }
    }

    private func tearDownHostedWindow() {
        window?.delegate = nil
        window?.contentView = nil
        window = nil
    }
}
