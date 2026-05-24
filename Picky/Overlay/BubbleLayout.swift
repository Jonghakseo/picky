//
//  BubbleLayout.swift
//  Picky
//
//  Pure text sizing/markdown helpers and navigation bubble policy.
//

import AppKit
import CoreText
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

struct VoicePromptBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct OnboardingBubbleSizePreferenceKey: PreferenceKey {
    static var defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        value = nextValue()
    }
}

struct ShakeReactionBubbleSizePreferenceKey: PreferenceKey {
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

    /// Truncate an attributed string so it wraps to at most `maxLines` visual lines at the
    /// given width, appending an ellipsis when content was dropped. CoreText is the source
    /// of truth for visual line counting so the result matches what the SwiftUI Text view
    /// will render with the same font and lineSpacing.
    ///
    /// SwiftUI's `.lineLimit(N)` alone is unreliable when the containing view uses
    /// `fixedSize(vertical: true)` and the host panel sizes itself from
    /// `NSHostingView.fittingSize`: the ideal size measurement can ignore the line cap and
    /// the panel grows to fit every paragraph. Pre-truncating the AttributedString here
    /// keeps `fittingSize` and the visible text aligned with the intended cap.
    static func truncatedAttributedText(
        _ source: AttributedString,
        font: NSFont,
        lineSpacing: CGFloat,
        width: CGFloat,
        maxLines: Int
    ) -> AttributedString {
        guard maxLines > 0, width > 0 else { return source }

        let nsAttr = NSAttributedString(source)
        guard nsAttr.length > 0 else { return source }

        let mutable = NSMutableAttributedString(attributedString: nsAttr)
        let fullRange = NSRange(location: 0, length: mutable.length)
        // Mirror the SwiftUI lineSpacing modifier so CoreText's wrap calculations match.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        // Runs created by AttributedString(markdown:) may not carry an NSFont attribute;
        // CoreText falls back to a system default in that case, which over- or under-counts
        // lines vs. SwiftUI's rendering. Stamp the bubble font on any unfontless run.
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: font, range: range)
            }
        }

        // First check whether the *original* source already fits within `maxLines` at the
        // full width. If it does, return it unchanged so short replies don't pay an ellipsis.
        let fullFramesetter = CTFramesetterCreateWithAttributedString(mutable)
        let fullPath = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude),
            transform: nil
        )
        let fullFrame = CTFramesetterCreateFrame(fullFramesetter, CFRange(location: 0, length: 0), fullPath, nil)
        let fullLines = (CTFrameGetLines(fullFrame) as? [CTLine]) ?? []
        guard fullLines.count > maxLines else { return source }

        // Lay the source out again at a slightly narrower width that reserves room for the
        // ellipsis on the last visible line. Without this reservation, cutting at the end of
        // line N and then appending "…" re-wraps to N+1 lines whenever the original line N
        // already filled the width budget — a regression caught by the wrapped-paragraph
        // truncation test.
        let ellipsisWidth = ceil(NSAttributedString(string: "\u{2026}", attributes: [.font: font]).size().width)
        let measureWidth = max(1, width - ellipsisWidth)
        let framesetter = CTFramesetterCreateWithAttributedString(mutable)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: measureWidth, height: .greatestFiniteMagnitude),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        guard lines.count > maxLines else { return source }

        let lastVisibleLine = lines[maxLines - 1]
        let range = CTLineGetStringRange(lastVisibleLine)
        let cutoff = min(Int(range.location + range.length), mutable.length)
        guard cutoff > 0 else { return source }
        let truncated = NSMutableAttributedString(
            attributedString: mutable.attributedSubstring(from: NSRange(location: 0, length: cutoff))
        )
        // Trim trailing whitespace/newlines so the ellipsis attaches to the last word
        // instead of dangling on its own line.
        while truncated.length > 0,
              let last = truncated.string.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            truncated.deleteCharacters(in: NSRange(location: truncated.length - 1, length: 1))
        }
        let inheritedAttributes: [NSAttributedString.Key: Any] = truncated.length > 0
            ? truncated.attributes(at: truncated.length - 1, effectiveRange: nil)
            : [.font: font]
        truncated.append(NSAttributedString(string: "\u{2026}", attributes: inheritedAttributes))
        return AttributedString(truncated)
    }

    /// Maximum bubble height in points for the given font/lineSpacing/lineLimit combination,
    /// including symmetric vertical padding. Used to cap `NSHostingView.fittingSize` so the
    /// panel never grows beyond the visible-line budget even when the SwiftUI Text's line
    /// limit is bypassed by the ideal-size measurement.
    static func maxBubbleHeight(
        font: NSFont,
        lineSpacing: CGFloat,
        maxLines: Int,
        verticalPadding: CGFloat
    ) -> CGFloat {
        guard maxLines > 0 else { return verticalPadding * 2 }
        let lineHeight = font.ascender + abs(font.descender) + font.leading
        let totalLineHeight = lineHeight * CGFloat(maxLines) + lineSpacing * CGFloat(max(0, maxLines - 1))
        return ceil(totalLineHeight + verticalPadding * 2)
    }

    /// Number of visual lines the attributed string would wrap to at the given width with
    /// the bubble font/lineSpacing. Exposed for tests so we can assert truncation results
    /// without spinning up a real SwiftUI scene.
    static func visualLineCount(
        _ source: AttributedString,
        font: NSFont,
        lineSpacing: CGFloat,
        width: CGFloat
    ) -> Int {
        guard width > 0 else { return 0 }
        let nsAttr = NSAttributedString(source)
        guard nsAttr.length > 0 else { return 0 }

        let mutable = NSMutableAttributedString(attributedString: nsAttr)
        let fullRange = NSRange(location: 0, length: mutable.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byWordWrapping
        mutable.addAttribute(.paragraphStyle, value: paragraph, range: fullRange)
        mutable.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if value == nil {
                mutable.addAttribute(.font, value: font, range: range)
            }
        }

        let framesetter = CTFramesetterCreateWithAttributedString(mutable)
        let path = CGPath(
            rect: CGRect(x: 0, y: 0, width: width, height: .greatestFiniteMagnitude),
            transform: nil
        )
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: 0, length: 0), path, nil)
        let lines = (CTFrameGetLines(frame) as? [CTLine]) ?? []
        return lines.count
    }
}

enum PickyBubbleMarkdown {
    static func attributedText(for text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if var attributed = try? AttributedString(markdown: text, options: options) {
            stripPickyDeepLinkAttributes(&attributed)
            return attributed
        }
        return AttributedString(sanitizedPlainText(text))
    }

    /// `[label](picky://...)` is meant for clickable surfaces (HUD bubble,
    /// companion panel chat). The cursor speech bubble shares this renderer
    /// but can't be clicked, so the link styling (blue underline) reads as
    /// visual noise. Strip the link attribute on `picky://` runs only —
    /// other schemes (https, mailto) keep their styling for cases like the
    /// onboarding bubble.
    private static func stripPickyDeepLinkAttributes(_ attributed: inout AttributedString) {
        for run in attributed.runs {
            guard let link = run.link, link.scheme?.lowercased() == "picky" else { continue }
            attributed[run.range].link = nil
        }
    }

    /// Like `attributedText(for:)` but every `**bold**` run also gets a tinted
    /// foreground color. Used by the onboarding bubble where the markdown
    /// strong-emphasis weight alone wasn't visible enough on top of the bubble's
    /// medium base weight — the color difference makes action words pop.
    static func highlightedAttributedText(
        for text: String,
        highlightColor: Color
    ) -> AttributedString {
        var attributed = attributedText(for: text)
        for run in attributed.runs {
            guard let intent = run.inlinePresentationIntent, intent.contains(.stronglyEmphasized) else { continue }
            attributed[run.range].foregroundColor = highlightColor
        }
        return attributed
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
