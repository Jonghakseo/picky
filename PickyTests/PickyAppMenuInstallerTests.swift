//
//  PickyAppMenuInstallerTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyAppMenuInstallerTests {
    @Test func mainMenuContainsStandardEditingAndCloseKeyEquivalents() throws {
        let menu = PickyAppMenuInstaller.makeMainMenu(appName: "Picky")

        let undo = try #require(menu.findItem(action: Selector(("undo:")), keyEquivalent: "z", modifiers: .command))
        #expect(undo.title == L10n.t("menu.undo"))

        let redoShiftZ = try #require(menu.findItem(action: Selector(("redo:")), keyEquivalent: "z", modifiers: [.command, .shift]))
        #expect(redoShiftZ.title == L10n.t("menu.redo"))

        let redoCommandY = try #require(menu.findItem(action: Selector(("redo:")), keyEquivalent: "y", modifiers: .command))
        #expect(redoCommandY.title == L10n.t("menu.redo"))

        let cut = try #require(menu.findItem(action: #selector(NSText.cut(_:)), keyEquivalent: "x", modifiers: .command))
        #expect(cut.title == L10n.t("menu.cut"))

        let copy = try #require(menu.findItem(action: #selector(NSText.copy(_:)), keyEquivalent: "c", modifiers: .command))
        #expect(copy.title == L10n.t("menu.copy"))

        let paste = try #require(menu.findItem(action: #selector(NSText.paste(_:)), keyEquivalent: "v", modifiers: .command))
        #expect(paste.title == L10n.t("menu.paste"))

        let selectAll = try #require(menu.findItem(action: #selector(NSStandardKeyBindingResponding.selectAll(_:)), keyEquivalent: "a", modifiers: .command))
        #expect(selectAll.title == L10n.t("menu.selectAll"))

        let closeWindow = try #require(menu.findItem(action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w", modifiers: .command))
        #expect(closeWindow.title == L10n.t("menu.closeWindow"))

        #expect(menu.findItem(action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q", modifiers: .command) == nil)
    }

    @Test func installAssignsMainMenuWithoutSwiftUIScene() {
        let previousMenu = NSApp.mainMenu
        defer { NSApp.mainMenu = previousMenu }

        PickyAppMenuInstaller.install(on: NSApp)

        #expect(NSApp.mainMenu?.findItem(action: Selector(("undo:")), keyEquivalent: "z", modifiers: .command) != nil)
        #expect(NSApp.mainMenu?.findItem(action: #selector(NSText.paste(_:)), keyEquivalent: "v", modifiers: .command) != nil)
        #expect(NSApp.mainMenu?.findItem(action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w", modifiers: .command) != nil)
    }
}

private extension NSMenu {
    func findItem(action: Selector, keyEquivalent: String, modifiers: NSEvent.ModifierFlags) -> NSMenuItem? {
        for item in items {
            if item.action == action,
               item.keyEquivalent == keyEquivalent,
               item.keyEquivalentModifierMask.normalizedKeyEquivalentFlags == modifiers.normalizedKeyEquivalentFlags {
                return item
            }
            if let found = item.submenu?.findItem(action: action, keyEquivalent: keyEquivalent, modifiers: modifiers) {
                return found
            }
        }
        return nil
    }
}

private extension NSEvent.ModifierFlags {
    var normalizedKeyEquivalentFlags: NSEvent.ModifierFlags {
        intersection([.command, .option, .control, .shift])
    }
}
