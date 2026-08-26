//
//  PickyHUDDockGroupListKeyboardPolicyTests.swift
//  PickyTests
//
//  Contract for context-dependent dock keyboard routing: which surface owns the
//  number keys, how the highlight moves, and what Esc closes first.
//

import Foundation
import Testing
@testable import Picky

struct PickyHUDDockGroupListKeyboardPolicyTests {
    private let rows = ["alpha", "bravo", "charlie"]

    // MARK: - Context

    @Test func railOwnsNumbersUntilAListIsOpen() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.shortcutContext(openGroupID: nil) == .rail)
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.shortcutContext(openGroupID: "group-1")
                == .groupList(groupID: "group-1")
        )
    }

    @Test func numbersResolveAgainstRowsAndStopAtTheNinth() {
        let many = (1...12).map { "row-\($0)" }

        #expect(PickyHUDDockGroupListKeyboardPolicy.rowID(forShortcutNumber: 1, rowIDs: many) == "row-1")
        #expect(PickyHUDDockGroupListKeyboardPolicy.rowID(forShortcutNumber: 9, rowIDs: many) == "row-9")
        #expect(PickyHUDDockGroupListKeyboardPolicy.rowID(forShortcutNumber: 10, rowIDs: many) == nil)
    }

    @Test func numberBeyondTheRowCountResolvesToNothing() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.rowID(forShortcutNumber: 4, rowIDs: rows) == nil)
        #expect(PickyHUDDockGroupListKeyboardPolicy.rowID(forShortcutNumber: 0, rowIDs: rows) == nil)
    }

    @Test func onlyTheFirstNineRowsAdvertiseAHint() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.shortcutNumber(forRowIndex: 0) == 1)
        #expect(PickyHUDDockGroupListKeyboardPolicy.shortcutNumber(forRowIndex: 8) == 9)
        #expect(PickyHUDDockGroupListKeyboardPolicy.shortcutNumber(forRowIndex: 9) == nil)
    }

    // MARK: - Highlight

    @Test func arrowsMoveOneRowAtATime() {
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.highlight(after: .down, current: "alpha", rowIDs: rows) == "bravo"
        )
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.highlight(after: .up, current: "bravo", rowIDs: rows) == "alpha"
        )
    }

    @Test func arrowsClampAtBothEndsInsteadOfWrapping() {
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.highlight(after: .up, current: "alpha", rowIDs: rows) == "alpha"
        )
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.highlight(after: .down, current: "charlie", rowIDs: rows) == "charlie"
        )
    }

    @Test func arrowsAdoptAnEndRowWhenNothingIsHighlightedYet() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.highlight(after: .down, current: nil, rowIDs: rows) == "alpha")
        #expect(PickyHUDDockGroupListKeyboardPolicy.highlight(after: .up, current: nil, rowIDs: rows) == "charlie")
        #expect(PickyHUDDockGroupListKeyboardPolicy.highlight(after: .down, current: nil, rowIDs: []) == nil)
    }

    /// Passive updates must not invent keyboard focus merely because a list is
    /// open, while a removed active row still needs a visible fallback.
    @Test func reconciliationPreservesInactiveFocusAndRecoversRemovedActiveRows() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.reconciledHighlight(current: nil, rowIDs: rows) == nil)
        #expect(PickyHUDDockGroupListKeyboardPolicy.reconciledHighlight(current: "bravo", rowIDs: rows) == "bravo")
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.reconciledHighlight(current: "gone", rowIDs: rows) == "alpha"
        )
        #expect(PickyHUDDockGroupListKeyboardPolicy.reconciledHighlight(current: "gone", rowIDs: []) == nil)
    }

    // MARK: - Scroll motion

    @Test func keyboardScrollUsesTheFastMotionTokenWhenMotionIsAllowed() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.scrollMotion(reduceMotion: false) == .fast)
    }

    @Test func keyboardScrollDisablesAnimationWhenReduceMotionIsEnabled() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.scrollMotion(reduceMotion: true) == .none)
    }

    // MARK: - Focus contract

    @Test func listOwnsArrowsOnlyWhileNoTextInputIsFocused() {
        #expect(
            PickyHUDDockGroupListKeyboardPolicy.ownsListNavigationKeys(isListOpen: true, isTextInputFocused: false)
        )
        #expect(
            PickyHUDDockGroupListKeyboardPolicy
                .ownsListNavigationKeys(isListOpen: true, isTextInputFocused: true) == false
        )
        #expect(
            PickyHUDDockGroupListKeyboardPolicy
                .ownsListNavigationKeys(isListOpen: false, isTextInputFocused: false) == false
        )
    }

    /// Esc closes the list even from the composer, then later presses fall
    /// through to the composer's own behavior.
    @Test func escapeClosesTheListFirstAndThenStopsInterfering() {
        #expect(PickyHUDDockGroupListKeyboardPolicy.escapeOutcome(isListOpen: true) == .closeGroupList)
        #expect(PickyHUDDockGroupListKeyboardPolicy.escapeOutcome(isListOpen: false) == .passThrough)
    }
}
