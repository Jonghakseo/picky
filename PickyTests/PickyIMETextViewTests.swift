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
