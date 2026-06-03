//
//  PickyHUDKeyboardShortcutPolicyTests.swift
//  PickyTests
//
//  Characterization coverage for HUD-owned keyboard shortcuts before moving
//  shortcut matching out of PickyHUDView.
//

import AppKit
import Testing
@testable import Picky

struct PickyHUDKeyboardShortcutPolicyTests {
    @Test func cycleDirectionSupportsBracketKeyCodesAndCharacters() {
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 33, charactersIgnoringModifiers: "{") == -1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 30, charactersIgnoringModifiers: "}") == 1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 0, charactersIgnoringModifiers: "[") == -1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 0, charactersIgnoringModifiers: "]") == 1)
        #expect(PickyHUDKeyboardShortcutPolicy.cycleDirection(keyCode: 0, charactersIgnoringModifiers: "x") == nil)
    }

    @Test func composerFocusShortcutRequiresPlainReturnOrKeypadEnter() {
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 76, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: .command) == false)
    }

    @Test func terminalFocusOnlyInterceptsHUDOwnedCommandTAndCommandW() {
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 13, charactersIgnoringModifiers: "w", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 0, charactersIgnoringModifiers: "W", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 8, charactersIgnoringModifiers: "c", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 9, charactersIgnoringModifiers: "v", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 13, charactersIgnoringModifiers: "w", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: []) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 0, charactersIgnoringModifiers: "a", modifiers: .control) == false)
    }

    @Test func commandShortcutMatchersSupportKeyCodesAndCharacters() {
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 15, charactersIgnoringModifiers: "r", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isLatestResponseReportShortcut(keyCode: 0, charactersIgnoringModifiers: "R", modifiers: .command) == true)

        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.command, .shift]) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isTerminalOverlayShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: [.command, .shift]) == true)

        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isInlineTerminalToggleShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: .command) == true)

        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 45, charactersIgnoringModifiers: "n", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 45, charactersIgnoringModifiers: "n", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isNotifyOnCompletionShortcut(keyCode: 0, charactersIgnoringModifiers: "N", modifiers: .command) == true)

        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isExtendedTerminalShortcut(keyCode: 0, charactersIgnoringModifiers: "E", modifiers: .command) == true)

        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 40, charactersIgnoringModifiers: "k", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 40, charactersIgnoringModifiers: "k", modifiers: .control) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isScreenContextTargetShortcut(keyCode: 0, charactersIgnoringModifiers: "K", modifiers: .command) == true)
    }

    @Test func thinkingToggleUsesControlTOnly() {
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .control) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: [.control, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isThinkingToggleShortcut(keyCode: 0, charactersIgnoringModifiers: "T", modifiers: .control) == true)
    }
}
