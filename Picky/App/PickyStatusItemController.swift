//
//  PickyStatusItemController.swift
//  Picky
//
//  Owns the NSStatusItem. A left click opens (or focuses) the hub window; a
//  right click shows a context menu with the same app-level controls the hub
//  sidebar exposes: open Picky, Dock visibility, appearance, feedback, and
//  quit/restart.
//

import AppKit
import SwiftUI

@MainActor
final class PickyStatusItemController: NSObject, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private let hubWindowController: PickyHubWindowController
    private let hudVisibilityStore: PickyHUDVisibilityStore
    private let appearanceStore: PickyAppearanceStore
    private let settingsViewModel: PickySettingsViewModel
    private let navigator: PickyHubNavigator
    private let modalHost: PickyHubModalHost
    private let contextMenu = NSMenu()

    init(
        hubWindowController: PickyHubWindowController,
        hudVisibilityStore: PickyHUDVisibilityStore,
        appearanceStore: PickyAppearanceStore,
        settingsViewModel: PickySettingsViewModel,
        navigator: PickyHubNavigator,
        modalHost: PickyHubModalHost
    ) {
        self.hubWindowController = hubWindowController
        self.hudVisibilityStore = hudVisibilityStore
        self.appearanceStore = appearanceStore
        self.settingsViewModel = settingsViewModel
        self.navigator = navigator
        self.modalHost = modalHost
        super.init()
        contextMenu.delegate = self
        createStatusItem()
    }

    /// Opens the hub on launch when setup still needs attention.
    func showHubOnLaunch() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.showHub()
        }
    }

    func present(deepLink: PickyDeepLink) {
        hubWindowController.show(deepLink: deepLink)
    }

    func showHub() {
        // Status items can be mirrored across menu bars; their backing window
        // is not necessarily on the display where the user clicked.
        let clickedDisplayID = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        }?.pickyDisplayID
        hubWindowController.show(fromDisplayID: clickedDisplayID ?? statusItemDisplayID)
    }

    // MARK: - Status item

    private var statusItemDisplayID: CGDirectDisplayID? {
        statusItem?.button?.window?.screen?.pickyDisplayID
    }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = makePickyMenuBarIcon()
        button.image?.isTemplate = true
        button.action = #selector(statusItemClicked)
        button.target = self
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        button.setAccessibilityLabel(L10n.t("hub.window.title"))
    }

    @objc private func statusItemClicked() {
        guard let event = NSApp.currentEvent else {
            showHub()
            return
        }
        let isSecondary = event.type == .rightMouseUp || event.modifierFlags.contains(.control)
        if isSecondary {
            showContextMenu()
        } else {
            showHub()
        }
    }

    private func showContextMenu() {
        guard let statusItem, let button = statusItem.button else { return }
        rebuildContextMenu()
        statusItem.menu = contextMenu
        button.performClick(nil)
    }

    /// Detaching the menu after it closes keeps left clicks routed to the
    /// action (a permanently attached menu would swallow every click).
    func menuDidClose(_ menu: NSMenu) {
        statusItem?.menu = nil
    }

    private func rebuildContextMenu() {
        contextMenu.removeAllItems()

        let open = NSMenuItem(title: L10n.t("hub.menu.open"), action: #selector(openHub), keyEquivalent: "")
        open.target = self
        contextMenu.addItem(open)

        contextMenu.addItem(.separator())

        let dockPresentation = CompanionPanelDockActionPresentation.resolve(
            isDockVisible: hudVisibilityStore.isVisible(for: dockDisplayID)
        )
        let dock = NSMenuItem(title: L10n.t(dockPresentation.titleKey), action: #selector(toggleDock), keyEquivalent: "")
        dock.target = self
        contextMenu.addItem(dock)

        let appearance = NSMenuItem(title: L10n.t("hub.menu.appearance"), action: nil, keyEquivalent: "")
        let appearanceMenu = NSMenu()
        for (title, mode) in [(L10n.t("hub.appearance.light"), PickyAppearanceMode.light), (L10n.t("hub.appearance.dark"), .dark)] {
            let item = NSMenuItem(title: title, action: #selector(selectAppearance(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = appearanceStore.mode == mode ? .on : .off
            appearanceMenu.addItem(item)
        }
        appearance.submenu = appearanceMenu
        contextMenu.addItem(appearance)

        let feedback = NSMenuItem(title: L10n.t("footer.feedback.accessibilityLabel"), action: #selector(openFeedback), keyEquivalent: "")
        feedback.target = self
        contextMenu.addItem(feedback)

        contextMenu.addItem(.separator())

        let requiresRestart = PickyRestartSettingsSnapshotStore.requirement(for: settingsViewModel.settings).isRequired
        let quit = NSMenuItem(
            title: L10n.t(requiresRestart ? "common.restart" : "common.quit"),
            action: requiresRestart ? #selector(relaunch) : #selector(quit),
            keyEquivalent: "q"
        )
        quit.target = self
        contextMenu.addItem(quit)
    }

    private var dockDisplayID: CGDirectDisplayID? {
        let cursorDisplayID = (NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main)?.pickyDisplayID
        return PickyHUDDockVisibilityTarget.resolve(companionDisplayID: statusItemDisplayID, cursorDisplayID: cursorDisplayID)
    }

    @objc private func openHub() { showHub() }

    @objc private func toggleDock() {
        guard let dockDisplayID else { return }
        hudVisibilityStore.toggle(for: dockDisplayID)
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = PickyAppearanceMode(rawValue: raw) else { return }
        appearanceStore.setMode(mode)
    }

    @objc private func openFeedback() {
        showHub()
        let viewModel = settingsViewModel
        modalHost.present(width: 480, accessibilityLabel: L10n.t("settings.section.feedback.title")) {
            PickyHubFeedbackDialog(viewModel: viewModel)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func relaunch() { PickyRelauncher.relaunchAndTerminate() }

    // MARK: - Icon

    private func makePickyMenuBarIcon() -> NSImage {
        let iconSize: CGFloat = 18
        if let image = NSImage(named: NSImage.Name("PickyStatusBarIcon")) {
            image.size = NSSize(width: iconSize, height: iconSize)
            image.isTemplate = true
            return image
        }
        return makeFallbackPickyMenuBarIcon(iconSize: iconSize)
    }

    private func makeFallbackPickyMenuBarIcon(iconSize: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: iconSize, height: iconSize), flipped: false) { _ in
            let baseFont = NSFont.systemFont(ofSize: iconSize * 0.78, weight: .bold)
            let roundedFont: NSFont = {
                guard let descriptor = baseFont.fontDescriptor.withDesign(.rounded) else { return baseFont }
                return NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
            }()
            let attributes: [NSAttributedString.Key: Any] = [.font: roundedFont, .foregroundColor: NSColor.black]
            let glyph = "π" as NSString
            let textSize = glyph.size(withAttributes: attributes)
            glyph.draw(
                at: CGPoint(x: (iconSize - textSize.width) / 2, y: (iconSize - textSize.height) / 2 - roundedFont.descender / 2),
                withAttributes: attributes
            )
            return true
        }
        image.isTemplate = true
        return image
    }
}
