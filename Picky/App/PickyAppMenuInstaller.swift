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
        mainMenu.addTopLevelMenu(title: "Edit", submenu: makeEditMenu())
        mainMenu.addTopLevelMenu(title: "View", submenu: makeViewMenu())
        mainMenu.addTopLevelMenu(title: "Window", submenu: makeWindowMenu())
        return mainMenu
    }

    /// View > Font Size submenu binds ⌘+ / ⌘- / ⌘0 to the global app font
    /// scale via the responder chain so any key panel (HUD, Companion, etc.)
    /// without its own local zoom shortcut routes to `CompanionAppDelegate`.
    /// Report/terminal panels intentionally claim the same shortcuts from
    /// within their SwiftUI view tree so detached panels keep their per-panel
    /// zoom — the responder chain only reaches here when no panel handles it.
    private static func makeViewMenu() -> NSMenu {
        let menu = NSMenu(title: "View")
        let fontSizeItem = NSMenuItem(title: "Font Size", action: nil, keyEquivalent: "")
        let fontSizeMenu = NSMenu(title: "Font Size")
        fontSizeMenu.addItem(
            menuItem(
                title: "Increase",
                action: Selector(("pickyIncreaseAppFontScale:")),
                keyEquivalent: "=",
                modifiers: .command
            )
        )
        fontSizeMenu.addItem(
            menuItem(
                title: "Decrease",
                action: Selector(("pickyDecreaseAppFontScale:")),
                keyEquivalent: "-",
                modifiers: .command
            )
        )
        fontSizeMenu.addItem(
            menuItem(
                title: "Actual Size",
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
                title: "Check for Updates…",
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            )
            item.target = controller
            menu.addItem(item)
        }
        return menu
    }

    private static func makeEditMenu() -> NSMenu {
        let menu = NSMenu(title: "Edit")
        menu.addItem(
            menuItem(
                title: "Undo",
                action: Selector(("undo:")),
                keyEquivalent: "z",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "z",
                modifiers: [.command, .shift]
            )
        )
        menu.addItem(
            menuItem(
                title: "Redo",
                action: Selector(("redo:")),
                keyEquivalent: "y",
                modifiers: .command
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: "Cut",
                action: #selector(NSText.cut(_:)),
                keyEquivalent: "x",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: "Copy",
                action: #selector(NSText.copy(_:)),
                keyEquivalent: "c",
                modifiers: .command
            )
        )
        menu.addItem(
            menuItem(
                title: "Paste",
                action: #selector(NSText.paste(_:)),
                keyEquivalent: "v",
                modifiers: .command
            )
        )
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                title: "Select All",
                action: #selector(NSStandardKeyBindingResponding.selectAll(_:)),
                keyEquivalent: "a",
                modifiers: .command
            )
        )
        return menu
    }

    private static func makeWindowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(
            menuItem(
                title: "Close Window",
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
