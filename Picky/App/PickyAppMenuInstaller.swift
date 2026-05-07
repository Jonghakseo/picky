//
//  PickyAppMenuInstaller.swift
//  Picky
//
//  Minimal AppKit menu used by the LSUIElement lifecycle. Picky does not expose
//  a normal menu bar, but NSApplication still uses `mainMenu` for key-equivalent
//  dispatch while our AppKit/SwiftUI panels are key.
//

import AppKit

@MainActor
enum PickyAppMenuInstaller {
    static func install(on app: NSApplication = .shared) {
        app.mainMenu = makeMainMenu(appName: resolvedAppName())
    }

    static func makeMainMenu(appName: String = "Picky") -> NSMenu {
        let mainMenu = NSMenu(title: appName)
        // Keep the app menu key-equivalent-free; quitting stays behind the explicit
        // companion footer confirmation instead of becoming an accidental global shortcut.
        mainMenu.addTopLevelMenu(title: appName, submenu: NSMenu(title: appName))
        mainMenu.addTopLevelMenu(title: "Edit", submenu: makeEditMenu())
        mainMenu.addTopLevelMenu(title: "Window", submenu: makeWindowMenu())
        return mainMenu
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
