//
//  PickySpeechTextSanitizer.swift
//  Picky
//
//  Pure text normalization for speech playback.
//

import Foundation

/// Removes or neutralizes speech-hostile supplementary detail so the TTS
/// layer does not try to pronounce URLs, paths, and identifiers. Visible text
/// keeps the original detail intact.
func stripParentheticalsForSpeech(_ text: String) -> String {
    let parentheticalPattern = #"[\(\uFF08][^\(\)\uFF08\uFF09]*[\)\uFF09]"#
    guard let parentheticalRegex = try? NSRegularExpression(pattern: parentheticalPattern, options: []) else { return text }
    let range = NSRange(text.startIndex..., in: text)
    let withoutParentheticals = parentheticalRegex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")

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
    return collapsed.isEmpty ? text : collapsed
}
