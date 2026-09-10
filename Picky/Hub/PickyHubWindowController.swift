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
    private let foregroundContextPreserver: PickyHubForegroundContextPreserver
    private var window: PickyHubWindow?
    private var frameAutosaver: PickyDetachedPanelFrameAutosaver?
    private var workspaceActivationObserver: NSObjectProtocol?
    /// Display of the status item that opened the window; used by the sidebar
    /// Dock toggle so it targets the screen the user is looking at.
    private var presentingDisplayID: CGDirectDisplayID?

    init(
        dependencies: PickyHubDependencies,
        foregroundContextPreserver: PickyHubForegroundContextPreserver
    ) {
        self.dependencies = dependencies
        self.foregroundContextPreserver = foregroundContextPreserver
        super.init()
    }

    var isVisible: Bool { window?.isVisible ?? false }
    var displayID: CGDirectDisplayID? { window?.screen?.pickyDisplayID }

    /// Create-or-focus. Page/scroll state lives in the navigator and the
    /// mounted SwiftUI tree, so reopening lands where the user left off.
    func show(fromDisplayID displayID: CGDirectDisplayID? = nil) {
        presentingDisplayID = displayID ?? presentingDisplayID
        if window == nil { createWindow() }
        guard let window else { return }
        foregroundContextPreserver.recordExternalForegroundBeforeHubActivation(hubIsVisible: isVisible)
        startTrackingExternalActivations()
        // Apply the explicit destination after autosave restoration, including
        // when reusing an existing window. Deep links keep the current frame.
        if let displayID,
           let screen = NSScreen.screens.first(where: { $0.pickyDisplayID == displayID }),
           window.screen?.pickyDisplayID != displayID {
            let visible = screen.visibleFrame
            let size = NSSize(
                width: min(window.frame.width, visible.width),
                height: min(window.frame.height, visible.height)
            )
            let frame = NSRect(
                x: visible.midX - size.width / 2,
                y: visible.midY - size.height / 2,
                width: size.width,
                height: size.height
            )
            window.setFrame(frame, display: true)
        }
        // Hub is a normal workspace window, not an accessory overlay. Keep
        // Picky in the Dock/app switcher while it is open so macOS can restore
        // app activation when returning to its Space, without forcing Z-order.
        // Move only when explicitly summoned. Leaving this flag set causes
        // Space round trips to restore other windows over Hub. AppKit processes
        // activation asynchronously, so restore normal Space behavior on the
        // next main-queue turn, not in a synchronous defer.
        window.collectionBehavior.insert(.moveToActiveSpace)
        setHubActivationPolicy(.regular)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak window] in
            window?.collectionBehavior.remove(.moveToActiveSpace)
        }
        dependencies.navigator.isWindowVisible = true
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

    /// The voice context coordinator calls this at PTT release, before it
    /// queries Workspace, AX, or browser state. Do not use timing sleeps here:
    /// the preserver waits for the requested external app activation.
    func restoreExternalForegroundForVoiceContextCapture() async {
        await foregroundContextPreserver.restoreExternalForegroundForContextCapture(
            hubIsVisible: isVisible,
            dismissHub: { [weak self] in
                self?.stopTrackingExternalActivations()
                self?.window?.orderOut(nil)
                self?.dependencies.navigator.isWindowVisible = false
                self?.setHubActivationPolicy(.accessory)
            }
        )
    }

    private func setHubActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        guard NSApp.activationPolicy() != policy else { return }
        if !NSApp.setActivationPolicy(policy) {
            NSLog("Picky Hub: could not set activation policy to %ld", policy.rawValue)
        }
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
        hubWindow.collectionBehavior = [.fullScreenNone]
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

    private func startTrackingExternalActivations() {
        guard workspaceActivationObserver == nil else { return }
        workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            // Main-queue delivery preserves activation order without another Task hop.
            MainActor.assumeIsolated {
                self?.foregroundContextPreserver.recordExternalActivation(PickyForegroundApplication(app))
            }
        }
    }

    private func stopTrackingExternalActivations() {
        guard let workspaceActivationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
        self.workspaceActivationObserver = nil
    }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        presentingDisplayID = window?.screen?.pickyDisplayID ?? presentingDisplayID
    }

    func windowDidMiniaturize(_ notification: Notification) {
        // A minimized Hub still belongs in the Dock and app switcher.
        dependencies.navigator.isWindowVisible = false
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        dependencies.navigator.isWindowVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        stopTrackingExternalActivations()
        dependencies.navigator.isWindowVisible = false
        foregroundContextPreserver.clearRememberedExternalForeground()
        dependencies.modalHost.dismiss()
        setHubActivationPolicy(.accessory)
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
