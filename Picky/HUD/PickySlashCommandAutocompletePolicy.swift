import Foundation

enum PickySlashCommandNavigationDirection {
    case up
    case down
}

enum PickySlashCommandAutocompletePolicy {
    static let maxSuggestions = 20
    /// Maximum number of dense rows visible before the composer panel scrolls.
    static let maxVisibleRows = 4

    static func query(in text: String, cursorLocation: Int?) -> String? {
        let utf16Count = text.utf16.count
        let cursorLocation = cursorLocation ?? utf16Count
        guard text.hasPrefix("/"), cursorLocation >= 1, cursorLocation <= utf16Count,
              let queryStart = stringIndex(in: text, utf16Offset: 1),
              let queryEnd = stringIndex(in: text, utf16Offset: cursorLocation) else { return nil }
        let query = String(text[queryStart..<queryEnd])
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    static func suggestions(
        for text: String,
        cursorLocation: Int?,
        commands: [PickySlashCommand],
        limit: Int = maxSuggestions
    ) -> [PickySlashCommand] {
        guard let query = query(in: text, cursorLocation: cursorLocation) else { return [] }
        let scored = commands.enumerated().compactMap { index, command -> (score: Int, index: Int, command: PickySlashCommand)? in
            guard let score = score(commandName: command.name, query: query) else { return nil }
            return (score, index, command)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score < rhs.score }
                return lhs.index < rhs.index
            }
            .prefix(limit)
            .map(\.command)
    }

    static func completionText(for command: PickySlashCommand) -> String {
        "/\(command.name) "
    }

    static func completedText(
        in text: String,
        cursorLocation: Int?,
        command: PickySlashCommand
    ) -> (text: String, cursorLocation: Int) {
        let remainder: String
        if let cursorLocation,
           let remainderStart = stringIndex(in: text, utf16Offset: cursorLocation) {
            remainder = String(text[remainderStart...])
        } else {
            remainder = ""
        }
        if let firstCharacter = remainder.first, firstCharacter.isWhitespace {
            // Keep the existing whitespace to avoid a double space, but place the
            // cursor after it so the accepted command reads "/name " with the caret
            // ready to type arguments.
            let namePart = "/\(command.name)"
            let whitespaceLength = String(firstCharacter).utf16.count
            return (namePart + remainder, namePart.utf16.count + whitespaceLength)
        }
        let prefix = completionText(for: command)
        return (prefix + remainder, prefix.utf16.count)
    }

    static func clampedSelectionIndex(_ index: Int, suggestionCount: Int) -> Int {
        guard suggestionCount > 0 else { return 0 }
        return min(max(index, 0), suggestionCount - 1)
    }

    static func movedSelectionIndex(current index: Int, suggestionCount: Int, direction: PickySlashCommandNavigationDirection) -> Int {
        guard suggestionCount > 0 else { return 0 }
        let current = clampedSelectionIndex(index, suggestionCount: suggestionCount)
        switch direction {
        case .up:
            return current == 0 ? suggestionCount - 1 : current - 1
        case .down:
            return current == suggestionCount - 1 ? 0 : current + 1
        }
    }

    static func visibleRange(selectedIndex: Int, suggestionCount: Int, maxVisible: Int) -> Range<Int> {
        guard suggestionCount > 0, maxVisible > 0 else { return 0..<0 }
        let clampedIndex = clampedSelectionIndex(selectedIndex, suggestionCount: suggestionCount)
        let visibleCount = min(maxVisible, suggestionCount)
        let halfWindow = visibleCount / 2
        let lowerBound = min(max(clampedIndex - halfWindow, 0), suggestionCount - visibleCount)
        return lowerBound..<(lowerBound + visibleCount)
    }

    private static func stringIndex(in text: String, utf16Offset: Int) -> String.Index? {
        guard utf16Offset >= 0, utf16Offset <= text.utf16.count else { return nil }
        let utf16Index = text.utf16.index(text.utf16.startIndex, offsetBy: utf16Offset)
        return utf16Index.samePosition(in: text)
    }

    private static func score(commandName: String, query: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        let name = commandName.lowercased()
        let needle = query.lowercased()
        if name == needle { return 0 }
        if name.hasPrefix(needle) { return 10 + max(0, name.count - needle.count) }
        if let range = name.range(of: needle) {
            let distance = name.distance(from: name.startIndex, to: range.lowerBound)
            return 100 + distance + max(0, name.count - needle.count)
        }
        return fuzzySubsequenceScore(name: name, query: needle)
    }

    private static func fuzzySubsequenceScore(name: String, query: String) -> Int? {
        let haystack = Array(name)
        let needle = Array(query)
        guard !needle.isEmpty else { return 0 }
        var searchStart = haystack.startIndex
        var gapPenalty = 0
        for character in needle {
            guard let match = haystack[searchStart...].firstIndex(of: character) else { return nil }
            gapPenalty += haystack.distance(from: searchStart, to: match)
            searchStart = haystack.index(after: match)
        }
        return 200 + gapPenalty + max(0, haystack.count - needle.count)
    }
}
