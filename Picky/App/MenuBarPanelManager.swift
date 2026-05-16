//
//  MenuBarPanelManager.swift
//  Picky
//
//  Manages the NSStatusItem (menu bar icon) and a custom borderless NSPanel
//  that drops down below it when clicked. The panel hosts a SwiftUI view
//  (CompanionPanelView) via NSHostingView. Uses the same NSPanel pattern as
//  FloatingSessionButton and GlobalPushToTalkOverlay for consistency.
//
//  The panel is non-activating so it does not steal focus from the user's
//  current app, and auto-dismisses when the user clicks outside.
//

import AppKit
import SwiftUI

extension Notification.Name {
    static let pickyDismissPanel = Notification.Name("pickyDismissPanel")
    static let pickyPanelAutoDismissSuspensionChanged = Notification.Name("pickyPanelAutoDismissSuspensionChanged")
}

enum PickyPanelAutoDismissSuspension {
    static let isSuspendedUserInfoKey = "isSuspended"
}

/// Custom NSPanel subclass that can become the key window even with
/// .nonactivatingPanel style, allowing text fields to receive focus.
private class KeyablePanel: NSPanel, PickyScreenCaptureExcludedWindow {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class MenuBarPanelManager: NSObject {
    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var clickOutsideMonitor: Any?
    private var dismissPanelObserver: NSObjectProtocol?
    private var autoDismissSuspensionObserver: NSObjectProtocol?
    private var isAutoDismissSuspended = false

    private let companionManager: CompanionManager
    private let appearanceStore: PickyAppearanceStore
    private let updaterController: PickyUpdaterController
    /// Lives on the manager so the panel's tab/route selection survives
    /// panel teardown (hidePanel only orderOuts; the hosting view is kept).
    /// Also lets `present(deepLink:)` route the panel from outside the
    /// SwiftUI view tree without touching the view's internal @State.
    let navigator: PickyPanelNavigator
    private let panelWidth: CGFloat = CompanionPanelMetrics.panelWidth
    private let panelHeight: CGFloat = CompanionPanelMetrics.panelHeight

    init(
        companionManager: CompanionManager,
        appearanceStore: PickyAppearanceStore,
        updaterController: PickyUpdaterController,
        navigator: PickyPanelNavigator
    ) {
        self.companionManager = companionManager
        self.appearanceStore = appearanceStore
        self.updaterController = updaterController
        self.navigator = navigator
        super.init()
        createStatusItem()

        dismissPanelObserver = NotificationCenter.default.addObserver(
            forName: .pickyDismissPanel,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.hidePanel()
        }

        autoDismissSuspensionObserver = NotificationCenter.default.addObserver(
            forName: .pickyPanelAutoDismissSuspensionChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let key = PickyPanelAutoDismissSuspension.isSuspendedUserInfoKey
            self?.isAutoDismissSuspended = notification.userInfo?[key] as? Bool ?? false
        }
    }

    deinit {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = dismissPanelObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = autoDismissSuspensionObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Status Item

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem?.button else { return }

        button.image = makePickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
    }

    /// Loads the bundled status bar vector as a menu bar template icon.
    private func makePickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        if let image = NSImage(named: NSImage.Name("PickyStatusBarIcon")) {
            image.size = NSSize(width: iconSize, height: iconSize)
            image.isTemplate = true
            return image
        }

        return makeFallbackPickyMenuBarIcon(iconSize: iconSize)
    }

    /// Fallback glyph used only if the bundled status bar asset cannot be loaded.
    private func makeFallbackPickyMenuBarIcon(iconSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { _ in
            let baseFont = NSFont.systemFont(ofSize: iconSize * 0.78, weight: .bold)
            let roundedFont: NSFont = {
                guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else { return baseFont }
                return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
            }()
            let attributes: [NSAttributedString.Key: Any] = [
                .font: roundedFont,
                .foregroundColor: NSColor.black
            ]
            let glyph = "π" as NSString
            let textSize = glyph.size(withAttributes: attributes)
            let originX = (iconSize - textSize.width) / 2
            let originY = (iconSize - textSize.height) / 2 - roundedFont.descender / 2
            glyph.draw(at: CGPoint(x: originX, y: originY), withAttributes: attributes)
            return true
        }
        image.isTemplate = true
        return image
    }

    /// Opens the panel automatically on app launch so the user sees
    /// permissions and the start button right away.
    func showPanelOnLaunch() {
        // Small delay so the status item has time to appear in the menu bar
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showPanel()
        }
    }

    @objc private func statusItemClicked() {
        if let panel, panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    /// Public entry point used by `PickyDeepLinkDispatcher` so a `picky://`
    /// link inside the conversation can both route the panel and pop it
    /// open in one call. Keeps the navigation-vs-visibility ordering in one
    /// place so we can't accidentally route without revealing the panel.
    func present(deepLink: PickyDeepLink) {
        navigator.apply(deepLink: deepLink)
        showPanel()
    }

    // MARK: - Panel Lifecycle

    private func showPanel() {
        if panel == nil {
            createPanel()
        }

        positionPanelBelowStatusItem()

        panel?.makeKeyAndOrderFront(nil)
        panel?.orderFrontRegardless()
        installClickOutsideMonitor()
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        removeClickOutsideMonitor()
    }

    private func createPanel() {
        let companionPanelView = CompanionPanelView(companionManager: companionManager, navigator: navigator)
            .frame(width: panelWidth, height: panelHeight)
            .environmentObject(appearanceStore)
            .environmentObject(updaterController)
            .modifier(PickyPreferredColorSchemeModifier(store: appearanceStore))

        let hostingView = NSHostingView(rootView: LocalizedHostingRoot { companionPanelView })
        hostingView.frame = NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = .clear

        let menuBarPanel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        menuBarPanel.isFloatingPanel = true
        // Keep the menu bar companion panel above Picky's HUD dock (raw level 19)
        // and other app floating panels while it is open from the status item.
        menuBarPanel.level = .statusBar
        menuBarPanel.isOpaque = false
        menuBarPanel.backgroundColor = .clear
        menuBarPanel.hasShadow = false
        menuBarPanel.hidesOnDeactivate = false
        menuBarPanel.isExcludedFromWindowsMenu = true
        menuBarPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        menuBarPanel.isMovableByWindowBackground = false
        menuBarPanel.titleVisibility = .hidden
        menuBarPanel.titlebarAppearsTransparent = true

        menuBarPanel.contentView = hostingView
        panel = menuBarPanel
    }

    private func positionPanelBelowStatusItem() {
        guard let panel else { return }
        guard let buttonWindow = statusItem?.button?.window else { return }

        let statusItemFrame = buttonWindow.frame
        let gapBelowMenuBar: CGFloat = 4

        // Calculate the panel's content height from the hosting view's fitting size
        // so the panel snugly wraps the SwiftUI content instead of using a fixed height.
        let fittingSize = panel.contentView?.fittingSize ?? CGSize(width: panelWidth, height: panelHeight)
        let actualPanelHeight = fittingSize.height

        // Horizontally center the panel beneath the status item icon
        let panelOriginX = statusItemFrame.midX - (panelWidth / 2)
        let panelOriginY = statusItemFrame.minY - actualPanelHeight - gapBelowMenuBar

        panel.setFrame(
            NSRect(x: panelOriginX, y: panelOriginY, width: panelWidth, height: actualPanelHeight),
            display: true
        )
    }

    // MARK: - Click Outside Dismissal

    /// Installs a global event monitor that hides the panel when the user clicks
    /// anywhere outside it — the same transient dismissal behavior as NSPopover.
    /// Uses a short delay so that system permission dialogs (triggered by Grant
    /// buttons in the panel) don't immediately dismiss the panel when they appear.
    private func installClickOutsideMonitor() {
        removeClickOutsideMonitor()

        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            guard let self, let panel = self.panel else { return }
            guard !self.isAutoDismissSuspended else { return }

            // Check if the click is inside the status item button — if so, the
            // statusItemClicked handler will toggle the panel, so don't also hide.
            let clickLocation = NSEvent.mouseLocation
            if panel.frame.contains(clickLocation) {
                return
            }

            // Delay dismissal slightly to avoid closing the panel when
            // a system permission dialog appears (e.g. microphone access).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard panel.isVisible else { return }
                guard !self.isAutoDismissSuspended else { return }

                // If permissions aren't all granted yet, a system dialog
                // may have focus — don't dismiss while setup is in progress.
                if !self.companionManager.allPermissionsGranted && !NSApp.isActive {
                    return
                }

                self.hidePanel()
            }
        }
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}
