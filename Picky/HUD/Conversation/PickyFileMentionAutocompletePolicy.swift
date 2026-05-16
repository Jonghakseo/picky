//
//  PickyFileMentionAutocompletePolicy.swift
//  Picky
//

import Foundation

enum PickyFileMentionAutocompletePolicy {
    static let maxSuggestions = 20
    private static let maxRecursiveScanEntries = 900
    private static let maxRecursiveDepth = 6
    private static let excludedRecursiveDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "DerivedData", "build", "node_modules",
    ]

    struct Query {
        let rawQuery: String
        let isQuoted: Bool
        let replacementRange: Range<String.Index>
        let replacementText: String
    }

    struct Suggestion: Equatable {
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

    static func suggestions(for text: String, cwd: String?, limit: Int = maxSuggestions, fileManager: FileManager = .default) -> [Suggestion] {
        guard let query = query(in: text) else { return [] }
        return suggestions(for: query, cwd: cwd, limit: limit, fileManager: fileManager)
    }

    static func completedText(in text: String, with suggestion: Suggestion) -> String {
        guard let query = query(in: text) else { return text }
        var next = text
        next.replaceSubrange(query.replacementRange, with: suggestion.completionText)
        return next
    }

    static func suggestions(for query: Query, cwd: String?, limit: Int = maxSuggestions, fileManager: FileManager = .default) -> [Suggestion] {
        guard limit > 0,
              let cwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines),
              !cwd.isEmpty
        else { return [] }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return [] }

        let directoryPart = directoryPart(for: query.rawQuery)
        guard isCwdRelativeDirectoryPart(directoryPart) else { return [] }
        guard !containsGitDirectory(directoryPart) else { return [] }

        let prefixSuggestions = prefixSuggestions(for: query, cwd: cwd, directoryPart: directoryPart, fileManager: fileManager)
        if query.rawQuery.isEmpty || query.rawQuery.hasSuffix("/") {
            return Array(prefixSuggestions.prefix(limit))
        }

        let prefixDisplayPaths = Set(prefixSuggestions.map(\.displayPath))
        let fuzzySuggestions = recursiveFuzzySuggestions(for: query, cwd: cwd, fileManager: fileManager)
            .filter { !prefixDisplayPaths.contains($0.displayPath) }
            .sorted { lhs, rhs in
                if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
                let lhsScore = score(suggestion: lhs, query: query.rawQuery)
                let rhsScore = score(suggestion: rhs, query: query.rawQuery)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
            }

        return Array((prefixSuggestions + fuzzySuggestions).prefix(limit))
    }

    private static func prefixSuggestions(for query: Query, cwd: String, directoryPart: String, fileManager: FileManager) -> [Suggestion] {
        let searchDirectory = URL(fileURLWithPath: cwd, isDirectory: true).appendingPathComponent(directoryPart, isDirectory: true)
        var searchDirectoryIsDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: searchDirectory.path, isDirectory: &searchDirectoryIsDirectory),
              searchDirectoryIsDirectory.boolValue
        else { return [] }

        let leafPrefix = leafPrefix(for: query.rawQuery)
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: searchDirectory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            return []
        }

        return entries.compactMap { url -> Suggestion? in
            let name = url.lastPathComponent
            guard !localizedCaseInsensitiveHasPrefix(name, prefix: ".git") else { return nil }
            guard leafPrefix.isEmpty || localizedCaseInsensitiveHasPrefix(name, prefix: leafPrefix) else { return nil }

            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = relativePath(directoryPart: directoryPart, name: name, isDirectory: isDirectory)
            return suggestion(relativePath: relativePath, name: name, isDirectory: isDirectory, query: query)
        }
        .sorted { lhs, rhs in
            if lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            return lhs.displayPath.localizedStandardCompare(rhs.displayPath) == .orderedAscending
        }
    }

    private static func recursiveFuzzySuggestions(for query: Query, cwd: String, fileManager: FileManager) -> [Suggestion] {
        let normalizedQuery = normalizedQuery(query.rawQuery)
        guard !normalizedQuery.isEmpty else { return [] }
        let root = URL(fileURLWithPath: cwd, isDirectory: true)
        var results: [Suggestion] = []
        var scannedEntries = 0
        scanDirectory(
            root,
            base: root,
            depth: 0,
            query: query,
            normalizedQuery: normalizedQuery,
            fileManager: fileManager,
            scannedEntries: &scannedEntries,
            results: &results
        )
        return results
    }

    private static func scanDirectory(
        _ directory: URL,
        base: URL,
        depth: Int,
        query: Query,
        normalizedQuery: String,
        fileManager: FileManager,
        scannedEntries: inout Int,
        results: inout [Suggestion]
    ) {
        guard depth <= maxRecursiveDepth, scannedEntries < maxRecursiveScanEntries else { return }
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants]
            )
        } catch {
            return
        }

        for url in entries where scannedEntries < maxRecursiveScanEntries {
            scannedEntries += 1
            let name = url.lastPathComponent
            guard !shouldExcludeFromRecursiveScan(name: name) else { continue }
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            let relativePath = relativePath(from: base, to: url, isDirectory: isDirectory)
            if score(path: relativePath, name: name, query: normalizedQuery) > 0 {
                results.append(suggestion(relativePath: relativePath, name: name, isDirectory: isDirectory, query: query))
            }
            if isDirectory {
                scanDirectory(
                    url,
                    base: base,
                    depth: depth + 1,
                    query: query,
                    normalizedQuery: normalizedQuery,
                    fileManager: fileManager,
                    scannedEntries: &scannedEntries,
                    results: &results
                )
            }
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

    private static func directoryPart(for rawQuery: String) -> String {
        let normalized = normalizedQuery(rawQuery)
        guard let slashIndex = normalized.lastIndex(of: "/") else { return "" }
        return String(normalized[..<slashIndex])
    }

    private static func leafPrefix(for rawQuery: String) -> String {
        let normalized = normalizedQuery(rawQuery)
        guard let slashIndex = normalized.lastIndex(of: "/") else { return normalized }
        return String(normalized[normalized.index(after: slashIndex)...])
    }

    private static func normalizedQuery(_ rawQuery: String) -> String {
        rawQuery.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
    }

    private static func containsGitDirectory(_ relativeDirectory: String) -> Bool {
        relativeDirectory.split(separator: "/").contains(".git")
    }

    private static func isCwdRelativeDirectoryPart(_ relativeDirectory: String) -> Bool {
        !relativeDirectory.hasPrefix("/") && !relativeDirectory.split(separator: "/").contains("..")
    }

    private static func shouldExcludeFromRecursiveScan(name: String) -> Bool {
        localizedCaseInsensitiveHasPrefix(name, prefix: ".git") || excludedRecursiveDirectoryNames.contains(name)
    }

    private static func localizedCaseInsensitiveHasPrefix(_ value: String, prefix: String) -> Bool {
        value.range(of: prefix, options: [.anchored, .caseInsensitive], locale: .current) != nil
    }

    private static func relativePath(directoryPart: String, name: String, isDirectory: Bool) -> String {
        let path = directoryPart.isEmpty ? name : "\(directoryPart)/\(name)"
        return isDirectory ? "\(path)/" : path
    }

    private static func relativePath(from base: URL, to url: URL, isDirectory: Bool) -> String {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        let relative: String
        if path == basePath {
            relative = ""
        } else if path.hasPrefix(basePath + "/") {
            relative = String(path.dropFirst(basePath.count + 1))
        } else {
            relative = url.lastPathComponent
        }
        return isDirectory && !relative.hasSuffix("/") ? "\(relative)/" : relative
    }

    private static func suggestion(relativePath: String, name: String, isDirectory: Bool, query: Query) -> Suggestion {
        Suggestion(
            label: isDirectory ? "\(name)/" : name,
            displayPath: relativePath,
            isDirectory: isDirectory,
            completionText: completionText(for: relativePath, isDirectory: isDirectory, query: query)
        )
    }

    private static func score(suggestion: Suggestion, query: String) -> Int {
        score(path: suggestion.displayPath, name: suggestion.label.trimmingCharacters(in: CharacterSet(charactersIn: "/")), query: normalizedQuery(query))
    }

    private static func score(path: String, name: String, query: String) -> Int {
        let lowerQuery = query.lowercased()
        guard !lowerQuery.isEmpty else { return 1 }
        let lowerName = name.lowercased()
        let lowerPath = path.lowercased()

        if lowerName == lowerQuery { return 1000 }
        if lowerName.hasPrefix(lowerQuery) { return 900 - max(0, lowerName.count - lowerQuery.count) }
        if lowerPath.hasPrefix(lowerQuery) { return 820 - max(0, lowerPath.count - lowerQuery.count) }
        if lowerName.contains(lowerQuery) { return 700 - max(0, lowerName.count - lowerQuery.count) }
        if lowerPath.contains(lowerQuery) { return 500 - max(0, lowerPath.count - lowerQuery.count) }
        return fuzzySubsequenceScore(candidate: lowerPath, query: lowerQuery)
    }

    private static func fuzzySubsequenceScore(candidate: String, query: String) -> Int {
        let haystack = Array(candidate)
        let needle = Array(query)
        guard !needle.isEmpty else { return 1 }
        var searchStart = haystack.startIndex
        var gapPenalty = 0
        for character in needle {
            guard let match = haystack[searchStart...].firstIndex(of: character) else { return 0 }
            gapPenalty += haystack.distance(from: searchStart, to: match)
            searchStart = haystack.index(after: match)
        }
        return max(1, 300 - gapPenalty - max(0, haystack.count - needle.count))
    }

    private static func completionText(for relativePath: String, isDirectory: Bool, query: Query) -> String {
        let shouldQuote = query.isQuoted || relativePath.contains(where: \.isWhitespace)
        if isDirectory {
            return shouldQuote ? "@\"\(relativePath)" : "@\(relativePath)"
        }
        return shouldQuote ? "@\"\(relativePath)\" " : "@\(relativePath) "
    }
}
