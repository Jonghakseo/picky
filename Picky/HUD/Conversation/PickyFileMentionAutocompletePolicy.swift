//
//  PickyFileMentionAutocompletePolicy.swift
//  Picky
//

import Foundation

nonisolated enum PickyFileMentionAutocompletePolicy {
    static let maxSuggestions = 20
    static let fdMaxResults = 100

    struct Query {
        let rawQuery: String
        let isQuoted: Bool
        let replacementRange: Range<String.Index>
        let replacementText: String
    }

    struct ScopedQuery: Equatable {
        let baseDirectory: String
        let pattern: String
        let displayBase: String
    }

    struct Suggestion: Equatable, Sendable {
        let label: String
        let displayPath: String
        let isDirectory: Bool
        let completionText: String
    }

    static func query(in text: String) -> Query? {
        guard !text.isEmpty else { return nil }

        if let quotedStart = activeQuotedMentionStart(in: text) {
            let queryStart = text.index(quotedStart, offsetBy: 2)
            let rawQueryWithOptionalClosingQuote = String(text[queryStart...])
            let hasClosingQuote = rawQueryWithOptionalClosingQuote.last == "\""
            let rawQuery = hasClosingQuote ? String(rawQueryWithOptionalClosingQuote.dropLast()) : rawQueryWithOptionalClosingQuote
            guard !rawQuery.contains("\"") else { return nil }
            return Query(
                rawQuery: rawQuery,
                isQuoted: true,
                replacementRange: quotedStart..<text.endIndex,
                replacementText: String(text[quotedStart...])
            )
        }

        guard text.last?.isWhitespace != true else { return nil }

        let tokenStart = text.lastIndex(where: \Character.isWhitespace).map { text.index(after: $0) } ?? text.startIndex
        guard tokenStart < text.endIndex, text[tokenStart] == "@" else { return nil }
        let queryStart = text.index(after: tokenStart)
        let rawQuery = String(text[queryStart...])
        return Query(
            rawQuery: rawQuery,
            isQuoted: false,
            replacementRange: tokenStart..<text.endIndex,
            replacementText: String(text[tokenStart...])
        )
    }

    static func completedText(in text: String, with suggestion: Suggestion) -> String {
        guard let query = query(in: text) else { return text }
        var next = text
        next.replaceSubrange(query.replacementRange, with: suggestion.completionText)
        return next
    }

    static func scopedQuery(
        for rawQuery: String,
        cwd: String,
        home: String = NSHomeDirectory(),
        fileManager: FileManager = .default
    ) -> ScopedQuery? {
        let normalizedQuery = normalizedQuery(rawQuery)
        guard let slashIndex = normalizedQuery.lastIndex(of: "/") else { return nil }

        let displayBase = String(normalizedQuery[...slashIndex])
        let pattern = String(normalizedQuery[normalizedQuery.index(after: slashIndex)...])
        let baseDirectory: String
        if displayBase.hasPrefix("~/") {
            baseDirectory = URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent(String(displayBase.dropFirst(2)), isDirectory: true)
                .standardizedFileURL.path
        } else if displayBase.hasPrefix("/") {
            baseDirectory = displayBase
        } else {
            baseDirectory = URL(fileURLWithPath: cwd, isDirectory: true)
                .appendingPathComponent(displayBase, isDirectory: true)
                .standardizedFileURL.path
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: baseDirectory, isDirectory: &isDirectory), isDirectory.boolValue else { return nil }
        return ScopedQuery(baseDirectory: baseDirectory, pattern: pattern, displayBase: displayBase)
    }

    static func fdPathQuery(_ query: String) -> String {
        guard query.contains("/") else { return query }
        let hasTrailingSeparator = query.hasSuffix("/")
        let trimmed = query.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !trimmed.isEmpty else { return query }

        let separatorPattern = "[\\\\/]"
        let segments = trimmed.split(separator: "/").map { regexEscaped(String($0)) }
        guard !segments.isEmpty else { return query }
        var pattern = segments.joined(separator: separatorPattern)
        if hasTrailingSeparator {
            pattern += separatorPattern
        }
        return pattern
    }

    static func fdArguments(baseDirectory: String, pattern: String) -> [String] {
        var arguments = [
            "--base-directory", baseDirectory,
            "--max-results", String(fdMaxResults),
            "--type", "f",
            "--type", "d",
            "--follow",
            "--hidden",
            "--exclude", ".git",
            "--exclude", ".git/*",
            "--exclude", ".git/**",
        ]
        if pattern.contains("/") {
            arguments.append("--full-path")
        }
        if !pattern.isEmpty {
            arguments.append(fdPathQuery(pattern))
        }
        return arguments
    }

    static func scoreEntry(path: String, query: String, isDirectory: Bool) -> Int {
        let fileNamePath = isDirectory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let fileName = URL(fileURLWithPath: fileNamePath).lastPathComponent
        let lowerFileName = fileName.lowercased()
        let lowerQuery = query.lowercased()
        let lowerPath = path.lowercased()
        var score = 0

        if lowerFileName == lowerQuery {
            score = 100
        } else if lowerFileName.hasPrefix(lowerQuery) {
            score = 80
        } else if lowerFileName.contains(lowerQuery) {
            score = 50
        } else if lowerPath.contains(lowerQuery) {
            score = 30
        }
        if isDirectory && score > 0 {
            score += 10
        }
        return score
    }

    static func suggestions(fromFdLines lines: [String], pattern: String, displayBase: String) -> [Suggestion] {
        suggestions(fromFdLines: lines, pattern: pattern, displayBase: displayBase, isQuoted: false)
    }

    static func suggestions(
        fromFdLines lines: [String],
        pattern: String,
        displayBase: String,
        isQuoted: Bool
    ) -> [Suggestion] {
        let scored = lines.enumerated().compactMap { offset, line -> (Int, Int, String, Bool)? in
            guard !line.isEmpty else { return nil }
            let isDirectory = line.hasSuffix("/")
            let path = isDirectory ? String(line.dropLast()) : line
            guard path != ".git", !path.hasPrefix(".git/"), !path.contains("/.git/") else { return nil }
            let score = pattern.isEmpty ? 1 : scoreEntry(path: line, query: pattern, isDirectory: isDirectory)
            guard score > 0 else { return nil }
            return (offset, score, path, isDirectory)
        }
        .sorted { lhs, rhs in
            lhs.1 == rhs.1 ? lhs.0 < rhs.0 : lhs.1 > rhs.1
        }
        .prefix(maxSuggestions)

        return scored.map { _, _, path, isDirectory in
            let displayPath = scopedPathForDisplay(displayBase: displayBase, relativePath: path)
            let completionPath = isDirectory ? "\(displayPath)/" : displayPath
            return Suggestion(
                label: URL(fileURLWithPath: path).lastPathComponent + (isDirectory ? "/" : ""),
                displayPath: displayPath,
                isDirectory: isDirectory,
                completionText: completionText(for: completionPath, isDirectory: isDirectory, isQuoted: isQuoted)
            )
        }
    }

    private static func activeQuotedMentionStart(in text: String) -> String.Index? {
        var index = text.endIndex
        while index > text.startIndex {
            index = text.index(before: index)
            guard text[index] == "\"" else { continue }
            guard index > text.startIndex else { continue }
            let atIndex = text.index(before: index)
            guard text[atIndex] == "@" else { continue }
            if atIndex == text.startIndex || text[text.index(before: atIndex)].isWhitespace {
                return atIndex
            }
        }
        return nil
    }

    private static func normalizedQuery(_ rawQuery: String) -> String {
        rawQuery.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func regexEscaped(_ value: String) -> String {
        value.replacingOccurrences(of: #"([.*+?^${}()|\[\]\\])"#, with: #"\\$1"#, options: .regularExpression)
    }

    private static func scopedPathForDisplay(displayBase: String, relativePath: String) -> String {
        displayBase == "/" ? "/\(relativePath)" : "\(displayBase)\(relativePath)"
    }

    private static func completionText(for path: String, isDirectory: Bool, isQuoted: Bool) -> String {
        let shouldQuote = isQuoted || path.contains(where: \.isWhitespace)
        if isDirectory {
            return shouldQuote ? "@\"\(path)" : "@\(path)"
        }
        return shouldQuote ? "@\"\(path)\" " : "@\(path) "
    }
}
