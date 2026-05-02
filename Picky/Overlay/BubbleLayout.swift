//
//  BubbleLayout.swift
//  Picky
//
//  Pure text sizing/markdown helpers and navigation bubble policy.
//

import AppKit
import SwiftUI

struct NavigationBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct ResponseBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

enum PickyBubbleLayout {
    static func textWidth(for text: String, font: NSFont, maxWidth: CGFloat) -> CGFloat {
        let lines = text.components(separatedBy: .newlines)
        let widestLine = lines.map { line in
            NSAttributedString(string: line.isEmpty ? " " : line, attributes: [.font: font]).size().width
        }.max() ?? 1
        return ceil(min(max(widestLine, 1), maxWidth))
    }
}

enum PickyBubbleMarkdown {
    static func attributedText(for text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            return attributed
        }
        return AttributedString(sanitizedPlainText(text))
    }

    static func displayString(for text: String) -> String {
        String(attributedText(for: text).characters)
    }

    private static func sanitizedPlainText(_ text: String) -> String {
        var sanitized = text
        let replacements: [(String, String)] = [
            (#"\[([^\]]+)\]\([^\)]+\)"#, "$1"),
            (#"\*\*([^*]+)\*\*"#, "$1"),
            (#"__([^_]+)__"#, "$1"),
            (#"`([^`]+)`"#, "$1"),
            (#"\*([^*]+)\*"#, "$1"),
            (#"_([^_]+)_"#, "$1")
        ]

        for (pattern, template) in replacements {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: template,
                options: .regularExpression
            )
        }

        return sanitized
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
    }
}

/// The buddy's behavioral mode. Controls whether it follows the cursor,
/// is flying toward a detected UI element, or is pointing at an element.
enum BuddyNavigationMode {
    /// Default — buddy follows the mouse cursor with spring animation
    case followingCursor
    /// Buddy is animating toward a detected UI element location
    case navigatingToTarget
    /// Buddy has arrived at the target and is pointing at it with a speech bubble
    case pointingAtTarget
}

