//
//  PickyConversationTitleSelectionPolicyTests.swift
//  PickyTests
//

import AppKit
import Testing
@testable import Picky

@MainActor
struct PickyConversationTitleSelectionPolicyTests {
    @Test func selectsOnlyFieldEditorInOriginatingWindowAndRequest() throws {
        let window = NSWindow()
        let editor = NSTextView()
        editor.isFieldEditor = true

        let eligible = PickyTitleFieldSelectionPolicy.eligibleEditor(
            expectedWindow: window,
            currentKeyWindow: window,
            firstResponder: editor,
            isEditing: true,
            isFocused: true,
            isCurrentRequest: true
        )

        #expect(try #require(eligible) === editor)
    }

    @Test func rejectsComposerTextViewEvenWhenWindowAndRequestStillMatch() {
        let window = NSWindow()
        let composer = NSTextView()
        composer.isFieldEditor = false

        let eligible = PickyTitleFieldSelectionPolicy.eligibleEditor(
            expectedWindow: window,
            currentKeyWindow: window,
            firstResponder: composer,
            isEditing: true,
            isFocused: true,
            isCurrentRequest: true
        )

        #expect(eligible == nil)
    }

    @Test func rejectsFieldEditorAfterKeyWindowChanges() {
        let originatingWindow = NSWindow()
        let replacementWindow = NSWindow()
        let editor = NSTextView()
        editor.isFieldEditor = true

        let eligible = PickyTitleFieldSelectionPolicy.eligibleEditor(
            expectedWindow: originatingWindow,
            currentKeyWindow: replacementWindow,
            firstResponder: editor,
            isEditing: true,
            isFocused: true,
            isCurrentRequest: true
        )

        #expect(eligible == nil)
    }

    @Test func rejectsFieldEditorAfterRequestOrFocusBecomesStale() {
        let window = NSWindow()
        let editor = NSTextView()
        editor.isFieldEditor = true

        let staleRequest = PickyTitleFieldSelectionPolicy.eligibleEditor(
            expectedWindow: window,
            currentKeyWindow: window,
            firstResponder: editor,
            isEditing: true,
            isFocused: true,
            isCurrentRequest: false
        )
        let staleFocus = PickyTitleFieldSelectionPolicy.eligibleEditor(
            expectedWindow: window,
            currentKeyWindow: window,
            firstResponder: editor,
            isEditing: true,
            isFocused: false,
            isCurrentRequest: true
        )

        #expect(staleRequest == nil)
        #expect(staleFocus == nil)
    }
}
