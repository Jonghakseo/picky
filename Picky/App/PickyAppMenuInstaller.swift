//
//  PickyAppMenuInstaller.swift
//  Picky
//
//  Minimal AppKit menu used by the LSUIElement lifecycle. Picky does not expose
//  a normal menu bar, but NSApplication still uses `mainMenu` for key-equivalent
//  dispatch while our AppKit/SwiftUI panels are key.
//

import AppKit
import Sparkle

@MainActor
enum PickyAppMenuInstaller {
    static func install(
        on app: NSApplication? = nil,
        updaterController: SPUStandardUpdaterController? = nil
    ) {
        let app = app ?? .shared
        app.mainMenu = makeMainMenu(appName: resolvedAppName(), updaterController: updaterController)
    }

    static func makeMainMenu(
        appName: String = "Picky",
        updaterController: SPUStandardUpdaterController? = nil
    ) -> NSMenu {
        let mainMenu = NSMenu(title: appName)
        // Keep the app menu key-equivalent-free; quitting stays behind the explicit
        // companion footer confirmation instead of becoming an accidental global shortcut.
        mainMenu.addTopLevelMenu(title: appName, submenu: makeAppMenu(updaterController: updaterController))
        mainMenu.addTopLevelMenu(title: L10n.t("menu.edit"), submenu: makeEditMenu())
        mainMenu.addTopLevelMenu(title: L10n.t("menu.view"), submenu: makeViewMenu())
        mainMenu.addTopLevelMenu(title: L10n.t("menu.window"), submenu: makeWindowMenu())
        return mainMenu
    }

    /// View > Font Size submenu binds ⌘+ / ⌘- / ⌘0 to the global app font
    /// scale via the responder chain so any key panel (HUD, Companion, etc.)
    /// without its own local zoom shortcut routes to `CompanionAppDelegate`.
    /// Report/terminal panels intentionally claim the same shortcuts from
    /// within their SwiftUI view tree so detached panels keep their per-panel
    /// zoom — the responder chain only reaches here when no panel handles it.
    private static func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.view"))
        let fontSizeItem = NSMenuItem(title: L10n.t("menu.fontSize"), action: nil, keyEquivalent: "")
        let fontSizeMenu = NSMenu(title: L10n.t("menu.fontSize"))
        fontSizeMenu.addItem(
            menuItem(
                title: L10n.t("menu.fontSize.increase"),
                action: Selector(("pickyIncreaseAppFontScale:")),
                keyEquivalent: "=",
                modifiers: .command
            )
        )
        fontSizeMenu.addItem(
            menuItem(
                title: L10n.t("menu.fontSize.decrease"),
                action: Selector(("pickyDecreaseAppFontScale:")),
                keyEquivalent: "-",
                modifiers: .command
            )
        )
        fontSizeMenu.addItem(
            menuItem(
                title: L10n.t("menu.fontSize.reset"),
                action: Selector(("pickyResetAppFontScale:")),
                keyEquivalent: "0",
                modifiers: .command
            )
        )
        fontSizeItem.submenu = fontSizeMenu
        menu.addItem(fontSizeItem)
        return menu
    }

    private static func makeAppMenu(updaterController: SPUStandardUpdaterController?) -> NSMenu {
        let menu = NSMenu(title: "App")
        // Sparkle ships SPUStandardUpdaterController.checkForUpdates(_:) as an
        // IBAction. Wiring it directly here lets Sparkle handle validation
        // (disabling the item while a check is in progress) automatically.
        if let controller = updaterController {
            let item = NSMenuItem(
                title: L10n.t("menu.checkUpdates"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.edit"))
        menu.addItem(
            menuItem(
                title: L10n.t("menu.undo"),
                action: Selector(("undo:")),
                keyEquivalent: "z",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: L10n.t("menu.redo"),
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(
            menuItem(
                title: L10n.t("menu.redo"),
                action: Selector(("redo:")),
                keyEquivalent: "y",
                modifiers: .command
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: L10n.t("menu.cut"),
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: L10n.t("menu.copy"),
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: L10n.t("menu.paste"),
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v",
                modifiers: .command
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: L10n.t("menu.selectAll"),
                action: #selector(NSStandardKeyBindingResponding.selectAll(_:)),
                keyEquivalent: "a",
                modifiers: .command
            )
        )
        return menu
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: L10n.t("menu.window"))
        menu.addItem(
            menuItem(
                title: L10n.t("menu.closeWindow"),
                action: #selector(NSWindow.performClose(_:)),
                keyEquivalent: "w",
                modifiers: .command
            )
        )
        return menu
    }

    private static func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = nil
        return item
    }

    private static func resolvedAppName() -> String {
        let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        return name?.isEmpty == false ? name! : "Picky"
    }
}

private extension NSMenu {
    func addTopLevelMenu(title: String, submenu: NSMenu) {
        let item = NSMenuItem()
        item.title = title
        item.submenu = submenu
        addItem(item)
    }
}
