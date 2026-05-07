//
//  PickyPanelKeyboardShortcutTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyPanelKeyboardShortcutTests {
    @Test func closeShortcutMatchesCommandWAndKoreanPhysicalW() throws {
        let commandW = try Self.keyEvent(characters: "w", keyCode: 13)
        #expect(PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandW))

        let koreanPhysicalW = try Self.keyEvent(characters: "ㅈ", keyCode: 13)
        #expect(PickyPanelKeyboardShortcut.isCloseWindowShortcut(koreanPhysicalW))
    }

    @Test func closeShortcutRequiresPlainCommandW() throws {
        let commandR = try Self.keyEvent(characters: "r", keyCode: 15)
        #expect(!PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandR))

        let commandShiftW = try Self.keyEvent(characters: "W", modifiers: [.command, .shift], keyCode: 13)
        #expect(!PickyPanelKeyboardShortcut.isCloseWindowShortcut(commandShiftW))
    }

    @Test func windowHelperPerformsCloseOnlyForCloseShortcut() throws {
        let window = CloseCountingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 120, height: 80),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )

        let ignored = try Self.keyEvent(characters: "r", keyCode: 15)
        #expect(!window.handlePickyCloseWindowShortcut(ignored))
        #expect(window.performCloseCallCount == 0)

        let close = try Self.keyEvent(characters: "w", keyCode: 13)
        #expect(window.handlePickyCloseWindowShortcut(close))
        #expect(window.performCloseCallCount == 1)
    }

    private static func keyEvent(
        characters: String,
        modifiers: NSEvent.ModifierFlags = .command,
        keyCode: UInt16
    ) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode
        ))
    }
}

private final class CloseCountingWindow: NSWindow {
    private(set) var performCloseCallCount = 0

    override func performClose(_ sender: Any?) {
        performCloseCallCount += 1
    }
}
