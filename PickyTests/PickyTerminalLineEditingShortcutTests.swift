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

    @Test func shellEscapedPathLeavesOrdinaryPathsUntouched() {
        #expect(PickySwiftTermView.shellEscapedPath("/Users/me/Desktop/pic.png") == "/Users/me/Desktop/pic.png")
        // Non-ASCII letters are alphanumerics and stay readable.
        #expect(PickySwiftTermView.shellEscapedPath("/Users/me/바탕화면/이미지.png") == "/Users/me/바탕화면/이미지.png")
    }

    @Test func shellEscapedPathBackslashEscapesShellMetacharacters() {
        #expect(PickySwiftTermView.shellEscapedPath("/Users/me/Screen Shot 1.png") == "/Users/me/Screen\\ Shot\\ 1.png")
        #expect(PickySwiftTermView.shellEscapedPath("/tmp/a(b)'c\"d.png") == "/tmp/a\\(b\\)\\'c\\\"d.png")
        #expect(PickySwiftTermView.shellEscapedPath("/tmp/img&$!.png") == "/tmp/img\\&\\$\\!.png")
    }

    @Test func droppedFilesInputTextJoinsPathsWithTrailingSpace() {
        #expect(PickySwiftTermView.droppedFilesInputText(for: ["/tmp/a.png"]) == "/tmp/a.png ")
        #expect(PickySwiftTermView.droppedFilesInputText(for: ["/tmp/a.png", "/tmp/b 1.png"]) == "/tmp/a.png /tmp/b\\ 1.png ")
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
