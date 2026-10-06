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

    /// Esc on an active Pickle is a stop request, never a silent dismissal of
    /// the run the user is watching; only a card with nothing to stop closes.
    @Test func cardEscapeStopsActiveRunsAndClosesIdleCards() {
        for status in [PickySessionStatus.running, .queued, .waiting_for_input] {
            #expect(PickyHUDKeyboardShortcutPolicy.cardEscapeOutcome(status: status) == .stop)
        }
        for status in [PickySessionStatus.blocked, .completed, .failed, .cancelled] {
            #expect(PickyHUDKeyboardShortcutPolicy.cardEscapeOutcome(status: status) == .close)
        }
        #expect(PickyHUDKeyboardShortcutPolicy.cardEscapeOutcome(status: nil) == .close)
    }

    @Test func composerFocusShortcutRequiresPlainReturnOrKeypadEnter() {
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 76, modifiers: []) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isComposerFocusShortcut(keyCode: 36, modifiers: .command) == false)
    }

    @MainActor @Test func composerFocusRoutingAllowsOnlyPanelFallbackResponders() {
        let panel = NSResponder()
        let contentView = NSView()
        let otherResponder = NSResponder()

        #expect(PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(nil, panel: panel))
        #expect(PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(panel, panel: panel))
        #expect(!PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(contentView, panel: panel))
        #expect(!PickyHUDKeyboardShortcutPolicy.isPanelFirstResponderFallback(otherResponder, panel: panel))
    }

    @MainActor @Test func readOnlySelectableBubbleTextDoesNotOwnInputShortcuts() {
        let markdownText = SelfSizingMarkdownTextView()
        markdownText.isEditable = false
        markdownText.isSelectable = true
        let tableCell = NSTextField(labelWithString: "Selectable result")
        tableCell.isSelectable = true

        #expect(!PickyHUDKeyboardShortcutPolicy.isEditableTextInputFocused(markdownText))
        #expect(!PickyHUDKeyboardShortcutPolicy.isEditableTextInputFocused(tableCell))
    }

    @MainActor @Test func editableComposerAndTitleInputsKeepOwningEscape() {
        let composer = NSTextView()
        composer.isEditable = true
        let titleField = NSTextField(string: "Pickle title")
        titleField.isEditable = true

        #expect(PickyHUDKeyboardShortcutPolicy.isEditableTextInputFocused(composer))
        #expect(PickyHUDKeyboardShortcutPolicy.isEditableTextInputFocused(titleField))
    }

    @Test func terminalFocusInterceptsHUDShellShortcutsButPassesInputShortcutsThrough() {
        // ⌘T no longer belongs to the HUD, so a focused terminal keeps it.
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 17, charactersIgnoringModifiers: "t", modifiers: .command) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 14, charactersIgnoringModifiers: "e", modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.shouldInterceptWhileTerminalFocused(keyCode: 0, charactersIgnoringModifiers: "E", modifiers: .command) == true)
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

    @Test func archiveSessionUsesCommandDeleteOnly() {
        #expect(PickyHUDKeyboardShortcutPolicy.isArchiveSessionShortcut(keyCode: 51, modifiers: .command) == true)
        #expect(PickyHUDKeyboardShortcutPolicy.isArchiveSessionShortcut(keyCode: 51, modifiers: []) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isArchiveSessionShortcut(keyCode: 51, modifiers: [.command, .shift]) == false)
        #expect(PickyHUDKeyboardShortcutPolicy.isArchiveSessionShortcut(keyCode: 117, modifiers: .command) == false)
    }
}
