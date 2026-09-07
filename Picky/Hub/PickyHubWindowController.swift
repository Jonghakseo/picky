//
//  PickyHubWindowController.swift
//  Picky
//
//  Owns the single hub window. Opening from the status item either creates
//  the window or brings the existing one forward (never toggles); closing is
//  the title bar button or ⌘W. The window is resizable with a 760×560 floor,
//  remembers its frame, and is excluded from Picky's own screen captures.
//

import AppKit
import SwiftUI

@MainActor
final class PickyHubWindowController: NSObject, NSWindowDelegate {
    private let dependencies: PickyHubDependencies
    private var window: PickyHubWindow?
    private var frameAutosaver: PickyDetachedPanelFrameAutosaver?
    /// Display of the status item that opened the window; used by the sidebar
    /// Dock toggle so it targets the screen the user is looking at.
    private var presentingDisplayID: CGDirectDisplayID?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Create-or-focus. Page/scroll state lives in the navigator and the
    /// mounted SwiftUI tree, so reopening lands where the user left off.
    func show(fromDisplayID displayID: CGDirectDisplayID? = nil) {
        presentingDisplayID = displayID ?? presentingDisplayID
        if window == nil { createWindow() }
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func show(deepLink: PickyDeepLink) {
        dependencies.navigator.apply(deepLink: deepLink)
        show()
    }

    func show(page: PickyHubPage) {
        dependencies.navigator.select(page)
        show()
    }

    func close() {
        window?.performClose(nil)
    }

    // MARK: - Window

    private func createWindow() {
        let hubWindow = PickyHubWindow(
            contentRect: initialFrame(),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        hubWindow.title = L10n.t("hub.window.title")
        hubWindow.titleVisibility = .hidden
        hubWindow.titlebarAppearsTransparent = true
        hubWindow.isMovableByWindowBackground = false
        hubWindow.isReleasedWhenClosed = false
        hubWindow.minSize = NSSize(
            width: PickyHubTheme.Layout.minimumWindowSize.width,
            height: PickyHubTheme.Layout.minimumWindowSize.height
        )
        hubWindow.collectionBehavior = [.fullScreenNone, .moveToActiveSpace]
        hubWindow.backgroundColor = PickyHubWindowChrome.backgroundColor()
        hubWindow.delegate = self
        hubWindow.identifier = NSUserInterfaceItemIdentifier("PickyHubWindow")

        let rootView = PickyAppFontScaleRoot(store: dependencies.fontScaleStore) {
            PickyHubRootView(dependencies: self.dependencies, dockDisplayIDProvider: { [weak self] in self?.presentingDisplayID })
                .environmentObject(self.dependencies.appearanceStore)
                .environmentObject(self.dependencies.hudVisibilityStore)
                .environmentObject(self.dependencies.updaterController)
                .environmentObject(self.dependencies.pluginReloadController)
                .modifier(PickyPreferredColorSchemeModifier(store: self.dependencies.appearanceStore))
        }
        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { rootView })
        hostingView.frame = NSRect(origin: .zero, size: hubWindow.frame.size)
        hostingView.autoresizingMask = [.width, .height]
        hubWindow.contentView = hostingView

        frameAutosaver = PickyDetachedPanelFrameAutosaver(
            panel: hubWindow,
            persister: PickyDetachedPanelFramePersister.backed(by: dependencies.settingsStore, kind: .hubWindow)
        )
        dependencies.modalHost.window = hubWindow
        window = hubWindow
    }

    private func initialFrame() -> NSRect {
        let size = PickyHubTheme.Layout.defaultWindowSize
        let screen = NSScreen.screens.first { $0.pickyDisplayID == presentingDisplayID } ?? NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else {
            return NSRect(origin: .zero, size: size)
        }
        let width = min(size.width, visible.width)
        let height = min(size.height, visible.height)
        return NSRect(
            x: visible.midX - width / 2,
            y: visible.midY - height / 2,
            width: width,
            height: height
        )
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        presentingDisplayID = window?.screen?.pickyDisplayID ?? presentingDisplayID
    }

    func windowWillClose(_ notification: Notification) {
        dependencies.modalHost.dismiss()
    }
}

/// Plain titled window that honours ⌘W and can host text input.
final class PickyHubWindow: NSWindow, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handlePickyCloseWindowShortcut(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

enum PickyHubWindowChrome {
    /// Matches `PickyHubTheme.Colors.canvas` so the transparent title bar and
    /// resize slivers never flash a different tone.
    static func backgroundColor() -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(red: 0x15 / 255, green: 0x17 / 255, blue: 0x19 / 255, alpha: 1)
                : NSColor.white
        }
    }
}
