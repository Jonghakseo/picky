//
//  PickyTerminalLineEditingShortcutTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyTerminalLineEditingShortcutTests {
    @Test func commandChordsMapToReadlineControlBytes() throws {
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 51)) == [0x15]) // ⌘⌫ -> Ctrl-U
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 123)) == [0x01]) // ⌘← -> Ctrl-A
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 124)) == [0x05]) // ⌘→ -> Ctrl-E
    }

    @Test func nonCommandOrUnmappedChordsAreIgnored() throws {
        // Up/Down arrows are not remapped.
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 125)) == nil)
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 126)) == nil)
        // Plain backspace without command must reach the terminal normally.
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 51, modifiers: [])) == nil)
        // Adding another modifier disqualifies the chord (e.g. ⌥⌘←).
        #expect(PickySwiftTermView.macLineEditingShortcutBytes(for: try Self.keyEvent(keyCode: 123, modifiers: [.command, .option])) == nil)
    }

    private static func keyEvent(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags = .command
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}
