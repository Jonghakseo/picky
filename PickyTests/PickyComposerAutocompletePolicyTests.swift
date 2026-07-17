//
//  PickyComposerAutocompletePolicyTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyComposerAutocompletePolicyTests {
    @Test func convertsUTF16CursorPositionsAcrossEmojiAndNewlines() throws {
        let text = "😀 >w\nnext"
        let cursor = "😀 >w".utf16.count
        let position = try #require(PickyComposerAutocompletePolicy.cursorPosition(in: text, utf16Offset: cursor))

        #expect(position.lines == ["😀 >w", "next"])
        #expect(position.line == 0)
        #expect(position.column == cursor)
        #expect(PickyComposerAutocompletePolicy.utf16Offset(
            lines: position.lines,
            line: 1,
            column: 2
        ) == "😀 >w\nne".utf16.count)
    }

    @Test func recognizesPiBuiltInAndExtensionTriggerTokens() {
        #expect(PickyComposerAutocompletePolicy.shouldQuery(
            text: ">w",
            cursorLocation: 2,
            triggerCharacters: [">"]
        ))
        #expect(PickyComposerAutocompletePolicy.shouldQuery(
            text: "please @src",
            cursorLocation: nil,
            triggerCharacters: []
        ))
        #expect(PickyComposerAutocompletePolicy.shouldQuery(
            text: "/comp",
            cursorLocation: nil,
            triggerCharacters: []
        ))
        #expect(!PickyComposerAutocompletePolicy.shouldQuery(
            text: "plain prompt",
            cursorLocation: nil,
            triggerCharacters: [">"]
        ))
    }

    @Test func computesHighlightRangeInUTF16WithoutSplittingEarlierEmoji() throws {
        let text = "😀 >worker task"
        let cursor = "😀 >worker".utf16.count
        let range = try #require(PickyComposerAutocompletePolicy.highlightRange(
            prefix: ">worker",
            cursorLocation: cursor,
            text: text
        ))

        #expect(range.location == "😀 ".utf16.count)
        #expect(range.length == ">worker".utf16.count)
        #expect(PickyComposerAutocompletePolicy.highlightRange(
            prefix: ">stale",
            cursorLocation: cursor,
            text: text
        ) == nil)
    }

    @Test func joinsAppliedCompletionLinesAndClampsCursorColumn() {
        let lines = [">worker ", "next"]
        #expect(PickyComposerAutocompletePolicy.text(from: lines) == ">worker \nnext")
        #expect(PickyComposerAutocompletePolicy.utf16Offset(lines: lines, line: 1, column: 99) == ">worker \nnext".utf16.count)
    }
}
