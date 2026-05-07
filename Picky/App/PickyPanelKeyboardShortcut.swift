//
//  PickyPanelKeyboardShortcut.swift
//  Picky
//
//  Shared keyboard handling for detached AppKit panels that live outside the
//  SwiftUI scene/menu command chain.
//

import AppKit

enum PickyPanelKeyboardShortcut {
    private static let ansiWKeyCode: UInt16 = 13
    private static let closeCharacters: Set<String> = ["w", "ㅈ"]

    static func isCloseWindowShortcut(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown else { return false }

        let modifiers = event.modifierFlags.intersection([.command, .option, .control, .shift])
        guard modifiers == .command else { return false }

        if event.keyCode == ansiWKeyCode { return true }

        guard let character = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return closeCharacters.contains(character)
    }
}

extension NSWindow {
    @discardableResult
    func handlePickyCloseWindowShortcut(_ event: NSEvent) -> Bool {
        guard PickyPanelKeyboardShortcut.isCloseWindowShortcut(event) else { return false }
        performClose(nil)
        return true
    }
}
