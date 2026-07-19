//
//  PickySpeechTextSanitizer.swift
//  Picky
//
//  Pure text normalization for speech playback.
//

import Foundation

/// Removes Markdown presentation syntax and neutralizes speech-hostile supplementary
/// detail so TTS reads only the user-visible prose. Visible UI text remains unchanged.
func sanitizedTextForSpeech(_ text: String) -> String {
    let markdownText = markdownPlainTextForSpeech(text)
    let parentheticalPattern = #"[\(\uFF08][^\(\)\uFF08\uFF09]*[\)\uFF09]"#
    guard let parentheticalRegex = try? NSRegularExpression(pattern: parentheticalPattern, options: []) else { return markdownText }
    let range = NSRange(markdownText.startIndex..., in: markdownText)
    let withoutParentheticals = parentheticalRegex.stringByReplacingMatches(in: markdownText, options: [], range: range, withTemplate: "")

    let withoutURLs = withoutParentheticals.replacingOccurrences(
        of: #"(?i)(?:https?://|www\.)[^\s,，。！？!?]+"#,
        with: "링크",
        options: .regularExpression
    )
    let withoutPaths = withoutURLs.replacingOccurrences(
        of: #"(?<!\S)(?:~/[^\s,，。！？!?]*|\.{1,2}/[^\s,，。！？!?]*|/[^\s,，。！？!?]+)(?=[\s,，。！？!?]|$)"#,
        with: "해당 경로",
        options: .regularExpression
    )
    let collapsed = withoutPaths
        .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        .replacingOccurrences(of: " ([,.!?。，！？])", with: "$1", options: .regularExpression)
        .replacingOccurrences(of: "해당 경로 에서", with: "해당 경로에서")
        .replacingOccurrences(of: "링크 에", with: "링크에")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return collapsed.isEmpty ? markdownText : collapsed
}

private func markdownPlainTextForSpeech(_ markdown: String) -> String {
    let blockText = markdownBlockTextForSpeech(markdown)
    let options = AttributedString.MarkdownParsingOptions(
        interpretedSyntax: .inlineOnlyPreservingWhitespace
    )
    guard let attributed = try? AttributedString(markdown: blockText, options: options) else {
        return blockText
    }
    return String(attributed.characters)
}

private func markdownBlockTextForSpeech(_ markdown: String) -> String {
    var lines: [String] = []
    var openFence: (character: Character, length: Int)?

    for rawLine in markdown.components(separatedBy: .newlines) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if let fence = markdownFence(in: trimmed) {
            if let activeFence = openFence {
                if fence.character == activeFence.character,
                   fence.length >= activeFence.length,
                   trimmed.dropFirst(fence.length).trimmingCharacters(in: .whitespaces).isEmpty {
                    openFence = nil
                }
            } else {
                openFence = fence
            }
            continue
        }
        guard openFence == nil else { continue }

        guard !isMarkdownHorizontalRule(trimmed),
              !isMarkdownTableSeparator(trimmed) else { continue }
        var line = trimmed
            .replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:>\s*)+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(?:[-+*]|\d{1,9}[.)])\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^\[[ xX]\]\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
        if line.contains("|"), let tableText = markdownTableRowText(line) {
            line = tableText
        }
        lines.append(line)
    }
    return lines.joined(separator: "\n")
}

private func markdownFence(in line: String) -> (character: Character, length: Int)? {
    guard let first = line.first, first == "`" || first == "~" else { return nil }
    let length = line.prefix(while: { $0 == first }).count
    return length >= 3 ? (first, length) : nil
}

private func isMarkdownHorizontalRule(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let marker = compact.first,
          marker == "*" || marker == "-" || marker == "_" else { return false }
    return compact.allSatisfy { $0 == marker }
}

private func isMarkdownTableSeparator(_ line: String) -> Bool {
    guard line.contains("|") else { return false }
    let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
    return cells.count >= 2 && cells.allSatisfy { cell in
        let core = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        return core.count >= 3 && core.allSatisfy { $0 == "-" }
    }
}

private func markdownTableRowText(_ line: String) -> String? {
    let cells = line.trimmingCharacters(in: CharacterSet(charactersIn: "|"))
        .split(separator: "|", omittingEmptySubsequences: false)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard cells.count >= 2 else { return nil }
    return cells.joined(separator: ", ")
}
