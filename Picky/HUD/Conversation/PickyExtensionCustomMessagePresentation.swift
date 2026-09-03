//
//  PickyExtensionCustomMessagePresentation.swift
//  Picky
//
//  Collapse policy for Pi `role="custom"` extension messages.
//

import Foundation

/// Projection of a tagged extension message into a bounded preview plus the
/// full payload.
///
/// Pi labels every custom message with its `customType` and lets an extension
/// register a renderer that honors an `expanded` flag
/// (`registerMessageRenderer` / `MessageRenderOptions`). Picky cannot run those
/// terminal renderers, so it applies one structural rule to every tagged
/// message: keep the first line of each blank-line separated block, bounded by
/// the same 10-line budget Pi uses for its own collapsed fallback
/// (`FALLBACK_PREVIEW_LINES` in `tool-execution.js`).
///
/// Preferring block heads over "the first N lines" is what keeps a batched
/// notification honest. The `bash_async` extension joins one entry per job with
/// a blank line, so a batch where job 1 succeeded and job 2 failed shows both
/// status headers while collapsed instead of hiding the failure behind the
/// first job's output tail.
///
/// Known limit: a single-block dump with no internal structure (for example
/// `prompt-suggest-lite-status`) can only contribute its own first lines, so
/// details buried mid-payload still require expanding. Picky has no contract
/// that would let it find them without extension-specific knowledge.
struct PickyExtensionCustomMessagePresentation: Equatable {
    /// Mirrors Pi's collapsed fallback budget for tool output.
    static let maxPreviewLines = 10

    let customType: String
    /// Lines shown while collapsed, in document order.
    let previewLines: [String]
    /// The whole payload, shown once expanded.
    let fullText: String
    let hiddenLineCount: Int

    /// Nothing to hide when the preview already covers the payload, so those
    /// messages render as a plain labeled bubble with no disclosure control.
    var isCollapsible: Bool { hiddenLineCount > 0 }

    static func make(message: PickySessionMessage) -> PickyExtensionCustomMessagePresentation? {
        guard message.kind == .system else { return nil }
        guard let customType = message.customType?.trimmingCharacters(in: .whitespacesAndNewlines),
              !customType.isEmpty else { return nil }
        return make(customType: customType, text: message.text ?? "")
    }

    static func make(
        customType: String,
        text: String,
        maxPreviewLines: Int = maxPreviewLines
    ) -> PickyExtensionCustomMessagePresentation? {
        let lines = contentLines(text)
        guard !lines.isEmpty else { return nil }

        let previewLines = Array(blockHeadLines(lines).prefix(max(1, maxPreviewLines)))
        return PickyExtensionCustomMessagePresentation(
            customType: customType,
            previewLines: previewLines,
            fullText: lines.joined(separator: "\n"),
            hiddenLineCount: max(0, lines.count - previewLines.count)
        )
    }

    /// Non-blank lines with leading and trailing padding removed. Interior
    /// blank lines survive because they are the block separators.
    private static func contentLines(_ text: String) -> [String] {
        var lines = PickyAnsiEscapeSanitizer.stripped(text).components(separatedBy: "\n")
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        return lines
    }

    private static func blockHeadLines(_ lines: [String]) -> [String] {
        var heads: [String] = []
        var atBlockStart = true
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                atBlockStart = true
                continue
            }
            if atBlockStart {
                heads.append(line)
                atBlockStart = false
            }
        }
        return heads
    }
}
