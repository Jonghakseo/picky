//
//  PickyIMETextViewTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyIMETextViewTests {
    @Test func bindingSyncPreservesNativeMarkedText() throws {
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "ㅎ",
            bindingText: "",
            hasMarkedText: true
        ) == false)
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "한글",
            bindingText: "한글",
            hasMarkedText: false
        ) == false)
        #expect(PickyIMETextSynchronization.shouldOverwriteNativeText(
            nativeText: "old",
            bindingText: "new",
            hasMarkedText: false
        ) == true)
    }

    @Test func returnCommitsThroughSubmitHandlerWithoutInsertingNewline() throws {
        let textView = PickyIMENSTextView()
        textView.string = "ready"
        var submittedModifiers: NSEvent.ModifierFlags?
        textView.onReturn = { modifiers in
            submittedModifiers = modifiers
            return true
        }

        textView.keyDown(with: Self.returnKeyEvent())

        #expect(submittedModifiers != nil)
        #expect(textView.string == "ready")
    }

    @Test func shiftReturnFallsThroughToNativeNewlineInsertion() throws {
        let textView = PickyIMENSTextView()
        textView.string = "first"
        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.onReturn = { modifiers in
            modifiers.contains(.shift) ? false : true
        }

        textView.keyDown(with: Self.returnKeyEvent(modifiers: .shift))

        #expect(textView.string == "first\n")
    }

    @Test func temporaryHighlightStylesTextWithoutMutatingEditorContent() throws {
        let textView = PickyIMENSTextView()
        textView.string = ">worker task"
        let range = NSRange(location: 0, length: 7)

        textView.setTemporaryHighlight(range: range, color: .systemBlue)

        #expect(textView.string == ">worker task")
        let temporaryColor = textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) as? NSColor
        #expect(temporaryColor == .systemBlue)

        textView.setTemporaryHighlight(range: nil, color: nil)
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) == nil)
    }

    @Test func markedTextClearsTemporaryHighlightAndReportsCompositionState() throws {
        let textView = PickyIMENSTextView()
        textView.string = ">w"
        textView.setTemporaryHighlight(range: NSRange(location: 0, length: 2), color: .systemBlue)
        var states: [Bool] = []
        textView.onMarkedTextChange = { states.append($0) }

        textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(states == [true])
        #expect(textView.layoutManager?.temporaryAttribute(
            .foregroundColor,
            atCharacterIndex: 1,
            effectiveRange: nil
        ) == nil)

        textView.unmarkText()
        #expect(states == [true, false])
    }

    @Test func insertTextCommitReportsMarkedTextEndedWithoutExplicitUnmark() throws {
        let textView = PickyIMENSTextView()
        var states: [Bool] = []
        textView.onMarkedTextChange = { states.append($0) }

        textView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        textView.insertText("한", replacementRange: NSRange(location: NSNotFound, length: 0))

        #expect(states == [true, false])
        #expect(!textView.hasMarkedText())
    }

    @Test func mouseDownFocusHelperMakesTextViewFirstResponderInNonactivatingHUDPanel() throws {
        let panel = PickyHUDPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        let textView = PickyIMENSTextView(frame: NSRect(x: 0, y: 0, width: 240, height: 120))
        panel.contentView = textView
        defer { panel.close() }

        #expect(panel.firstResponder !== textView)

        #expect(textView.focusForMouseDown())

        #expect(panel.firstResponder === textView)
    }

    private static func returnKeyEvent(modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: PickyIMENSTextView.returnKeyCode
        )!
    }
}
