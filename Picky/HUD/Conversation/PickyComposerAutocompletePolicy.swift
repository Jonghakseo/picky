//
//  PickyComposerAutocompletePolicy.swift
//  Picky
//
//  Pure UTF-16 cursor and trigger policy shared by the HUD composer and tests.
//

import Foundation

nonisolated enum PickyComposerAutocompletePolicy {
    struct CursorPosition: Equatable, Sendable {
        let lines: [String]
        let line: Int
        let column: Int
    }

    static func cursorPosition(in text: String, utf16Offset: Int?) -> CursorPosition? {
        let lines = text.components(separatedBy: "\n")
        let offset = utf16Offset ?? text.utf16.count
        guard offset >= 0, offset <= text.utf16.count else { return nil }

        var consumed = 0
        for (lineIndex, line) in lines.enumerated() {
            let lineLength = line.utf16.count
            if offset <= consumed + lineLength {
                return CursorPosition(lines: lines, line: lineIndex, column: offset - consumed)
            }
            consumed += lineLength
            if lineIndex < lines.count - 1 {
                consumed += 1
            }
        }
        return CursorPosition(lines: lines, line: max(0, lines.count - 1), column: lines.last?.utf16.count ?? 0)
    }

    static func text(from lines: [String]) -> String {
        lines.joined(separator: "\n")
    }

    static func utf16Offset(lines: [String], line: Int, column: Int) -> Int? {
        guard lines.indices.contains(line) else { return nil }
        let clampedColumn = min(max(column, 0), lines[line].utf16.count)
        return lines[..<line].reduce(0) { $0 + $1.utf16.count + 1 } + clampedColumn
    }

    static func shouldQuery(
        text: String,
        cursorLocation: Int?,
        triggerCharacters: [String]
    ) -> Bool {
        guard let position = cursorPosition(in: text, utf16Offset: cursorLocation),
              position.lines.indices.contains(position.line),
              let beforeCursor = utf16Prefix(position.lines[position.line], length: position.column)
        else { return false }

        if beforeCursor.hasPrefix("/") { return true }
        let token = activeToken(in: beforeCursor)
        if token.hasPrefix("@") { return true }
        if token.contains("/") || token.hasPrefix(".") || token.hasPrefix("~/") { return true }
        if token.isEmpty && beforeCursor.last?.isWhitespace == true { return true }
        return triggerCharacters.contains { trigger in
            !trigger.isEmpty && token.hasPrefix(trigger)
        }
    }

    static func highlightRange(prefix: String?, cursorLocation: Int?, text: String) -> NSRange? {
        guard let prefix, !prefix.isEmpty, let cursorLocation else { return nil }
        let prefixLength = prefix.utf16.count
        guard cursorLocation >= prefixLength, cursorLocation <= text.utf16.count else { return nil }
        let range = NSRange(location: cursorLocation - prefixLength, length: prefixLength)
        guard (text as NSString).substring(with: range) == prefix else { return nil }
        return range
    }

    private static func activeToken(in text: String) -> String {
        let delimiters = CharacterSet(charactersIn: " \t\"'=\n")
        let scalarView = text.unicodeScalars
        guard let delimiter = scalarView.lastIndex(where: { delimiters.contains($0) }) else { return text }
        return String(scalarView[scalarView.index(after: delimiter)...])
    }

    private static func utf16Prefix(_ text: String, length: Int) -> String? {
        guard length >= 0, length <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: length)
        guard let index = utf16Index.samePosition(in: text) else { return nil }
        return String(text[..<index])
    }
}
