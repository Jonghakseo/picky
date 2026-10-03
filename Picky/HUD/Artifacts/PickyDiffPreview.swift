//
//  PickyDiffPreview.swift
//  Picky
//

import Foundation

struct PickyDiffPreview: Equatable {
    struct FileDiff: Equatable, Identifiable {
        var id: String { path }
        let path: String
        let text: String
        let isTruncated: Bool
    }

    let files: [FileDiff]
    let totalOriginalCharacters: Int
}

struct PickyDiffPreviewBuilder {
    let maxCharactersPerFile: Int

    init(maxCharactersPerFile: Int = 12_000) {
        self.maxCharactersPerFile = max(1, maxCharactersPerFile)
    }

    func build(from unifiedDiff: String) -> PickyDiffPreview {
        var grouped: [(path: String, lines: [String])] = []
        var currentPath = "unified.diff"
        var currentLines: [String] = []

        for line in unifiedDiff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if line.hasPrefix("diff --git ") {
                if !currentLines.isEmpty { grouped.append((currentPath, currentLines)) }
                currentPath = Self.path(fromDiffHeader: line) ?? "unified.diff"
                currentLines = [line]
            } else {
                currentLines.append(line)
            }
        }
        if !currentLines.isEmpty { grouped.append((currentPath, currentLines)) }

        let files = grouped.map { group -> PickyDiffPreview.FileDiff in
            let text = group.lines.joined(separator: "\n")
            if text.count <= maxCharactersPerFile {
                return PickyDiffPreview.FileDiff(path: group.path, text: text, isTruncated: false)
            }
            let end = text.index(text.startIndex, offsetBy: maxCharactersPerFile)
            return PickyDiffPreview.FileDiff(path: group.path, text: String(text[..<end]) + "\n[diff truncated by Picky]", isTruncated: true)
        }
        return PickyDiffPreview(files: files, totalOriginalCharacters: unifiedDiff.count)
    }

    private static func path(fromDiffHeader line: String) -> String? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 4 else { return nil }
        return parts[3].hasPrefix("b/") ? String(parts[3].dropFirst(2)) : parts[3]
    }
}
