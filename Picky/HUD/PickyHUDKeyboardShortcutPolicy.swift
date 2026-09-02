//
//  PickyHUDKeyboardShortcutPolicy.swift
//  Picky
//
//  HUD-owned keyboard shortcut matching. Kept separate from PickyHUDView so
//  shortcut routing can be characterized without touching SwiftUI view identity.
//

import AppKit

enum PickyHUDKeyboardShortcutPolicy {
    private static let leftBracketKeyCode: UInt16 = 33
    private static let rightBracketKeyCode: UInt16 = 30
    private static let rKeyCode: UInt16 = 15
    private static let tKeyCode: UInt16 = 17
    private static let eKeyCode: UInt16 = 14
    private static let nKeyCode: UInt16 = 45
    private static let kKeyCode: UInt16 = 40
    private static let wKeyCode: UInt16 = 13
    private static let returnKeyCode: UInt16 = 36
    private static let keypadEnterKeyCode: UInt16 = 76
    private static let deleteKeyCode: UInt16 = 51

    static func isComposerFocusShortcut(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.intersection([.command, .shift, .option, .control]).isEmpty
            && (keyCode == returnKeyCode || keyCode == keypadEnterKeyCode)
    }

    /// Only the panel itself or no responder represents an unintentional input
    /// fallback. Any mounted responder, including an NSHostingView, owns its
    /// own keyboard intent and must not be replaced by the composer shortcut.
    static func isPanelFirstResponderFallback(
        _ firstResponder: NSResponder?,
        panel: NSResponder
    ) -> Bool {
        firstResponder == nil || firstResponder === panel
    }

    /// Only editable controls own text-input shortcuts. Conversation bubbles use
    /// selectable, read-only NSTextView/NSTextField instances for copy support;
    /// treating those as editors prevents shell-level Escape dismissal after a
    /// user clicks or selects response text.
    static func isEditableTextInputFocused(_ firstResponder: NSResponder?) -> Bool {
        if let textView = firstResponder as? NSTextView {
            return textView.isEditable
        }
        if let textField = firstResponder as? NSTextField {
            return textField.isEditable
        }
        return false
    }

    /// While a Pi TUI terminal is focused, the HUD forwards virtually every key to
    /// the terminal so cmd-based TUI shortcuts (⌘C, ⌘V, ⌘arrows, etc.) reach Pi.
    /// Cmd+T (toggle back to chat), Cmd+E (hide the local extended terminal),
    /// and Cmd+W (close the held card) stay owned by the HUD because they control
    /// the Picky shell around the terminal instead of terminal input.
    static func shouldInterceptWhileTerminalFocused(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if isInlineTerminalToggleShortcut(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            return true
        }
        if isExtendedTerminalShortcut(
            keyCode: keyCode,
            charactersIgnoringModifiers: charactersIgnoringModifiers,
            modifiers: modifiers
        ) {
            return true
        }
        if keyCode == wKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "w"
    }

    static func isLatestResponseReportShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == rKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "r"
    }

    static func isTerminalOverlayShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == [.command, .shift] else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isInlineTerminalToggleShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isThinkingToggleShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .control else { return false }
        if keyCode == tKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "t"
    }

    static func isNotifyOnCompletionShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == nKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "n"
    }

    static func isExtendedTerminalShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == eKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "e"
    }

    static func isScreenContextTargetShortcut(
        keyCode: UInt16,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard modifiers == .command else { return false }
        if keyCode == kKeyCode { return true }
        return charactersIgnoringModifiers?.lowercased() == "k"
    }

    /// Matched on the key code alone because the delete key reports the
    /// non-printing U+007F, which no character fallback can widen.
    static func isArchiveSessionShortcut(
        keyCode: UInt16,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        modifiers == .command && keyCode == deleteKeyCode
    }

    static func cycleDirection(keyCode: UInt16, charactersIgnoringModifiers: String?) -> Int? {
        switch keyCode {
        case leftBracketKeyCode: return -1
        case rightBracketKeyCode: return 1
        default: break
        }

        switch charactersIgnoringModifiers {
        case "[", "{": return -1
        case "]", "}": return 1
        default: return nil
        }
    }
}
