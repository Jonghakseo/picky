import Foundation

enum PickySlashCommandNavigationDirection {
    case up
    case down
}

enum PickySlashCommandAutocompletePolicy {
    static let maxSuggestions = 20

    static func query(in text: String) -> String? {
        guard text.hasPrefix("/") else { return nil }
        let query = String(text.dropFirst())
        guard !query.contains(where: \.isWhitespace) else { return nil }
        return query
    }

    static func suggestions(for text: String, commands: [PickySlashCommand], limit: Int = maxSuggestions) -> [PickySlashCommand] {
        guard let query = query(in: text) else { return [] }
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
