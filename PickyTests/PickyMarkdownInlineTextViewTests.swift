//
//  PickyMarkdownInlineTextViewTests.swift
//  PickyTests
//
//  Direct-tests the NSAttributedString builder for the conversation
//  markdown wrapper. Builder correctness is what guarantees the
//  pixel-stability of the migration off SwiftUI Text — the wrapper itself
//  is just plumbing around it.
//

import AppKit
import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyMarkdownInlineTextViewTests {
    @Test func builderConcatenatesInlineBlocksWithBlockSpacing() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("First line."),
            .paragraph("Second line.")
        ])

        // Two paragraphs with a single newline separator → "…line.\n…line."
        // The visual gap between paragraphs is driven by NSParagraphStyle's
        // paragraphSpacing, not by additional blank lines.
        #expect(attributed.string == "First line.\nSecond line.")
    }

    @Test func nonLastBlockGetsBlockSpacing() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("First"),
            .paragraph("Second")
        ])
        let firstStyle = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let secondStyle = attributed.attribute(
            .paragraphStyle,
            at: attributed.length - 1,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(firstStyle?.paragraphSpacing == PickyMarkdownInlineTextView.blockSpacing)
        #expect(secondStyle?.paragraphSpacing == 0)
    }

    @Test func bulletPrependsLeaderAndIndentsBody() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .bullet("hello")
        ])
        // "•\thello" — the tab pushes the body to the head-indent column so
        // wrapped second lines line up under the body, not the marker.
        #expect(attributed.string == "•\thello")

        let style = attributed.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        #expect(style?.headIndent == 14)
        #expect(style?.firstLineHeadIndent == 0)
    }

    @Test func bulletLeaderUsesSecondaryColor() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .bullet("body")
        ])
        // The "•" character (index 0) is rendered in textSecondary; the body
        // text uses textPrimary. Test that the two ranges have different
        // foreground colors so the visual hierarchy from the previous
        // SwiftUI HStack composition is preserved.
        let leaderColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let bodyColor = attributed.attribute(.foregroundColor, at: attributed.length - 1, effectiveRange: nil) as? NSColor
        #expect(leaderColor != nil)
        #expect(bodyColor != nil)
        #expect(leaderColor != bodyColor)
    }

    @Test func headingUsesLargerSemiboldFont() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .heading(level: 1, text: "Title")
        ])
        let font = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(font?.pointSize == PickyHUDTypography.Size.heading1)
        #expect(font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func inlineBoldRunPreservesTraitsAtBaseSize() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("normal **bold** more")
        ])
        // Walk runs to find the bold portion (locate by .font symbolic
        // traits .bold). The rendered string drops the literal "**" so the
        // bold range covers "bold".
        let range = NSRange(location: 0, length: attributed.length)
        var boldFonts: [NSFont] = []
        attributed.enumerateAttribute(.font, in: range, options: []) { value, _, _ in
            if let font = value as? NSFont, font.fontDescriptor.symbolicTraits.contains(.bold) {
                boldFonts.append(font)
            }
        }
        #expect(!boldFonts.isEmpty)
        // Bold run must keep the body point size — only the trait changes.
        #expect(boldFonts.allSatisfy { $0.pointSize == PickyHUDTypography.Size.body })
    }

    @Test func linkRunGetsAccentColor() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("see [docs](https://example.com)")
        ])
        // Find the link run and confirm it has a non-nil .link attribute
        // and its foreground color is the accent (i.e., differs from the
        // surrounding body color).
        var linkRangeFound = false
        var bodyColor: NSColor?
        var linkColor: NSColor?
        let range = NSRange(location: 0, length: attributed.length)
        attributed.enumerateAttribute(.link, in: range, options: []) { value, subrange, _ in
            if value != nil {
                linkRangeFound = true
                linkColor = attributed.attribute(.foregroundColor, at: subrange.location, effectiveRange: nil) as? NSColor
            } else if bodyColor == nil {
                bodyColor = attributed.attribute(.foregroundColor, at: subrange.location, effectiveRange: nil) as? NSColor
            }
        }
        #expect(linkRangeFound)
        #expect(linkColor != nil)
        #expect(bodyColor != nil)
        #expect(linkColor != bodyColor)
    }

    @Test func emptyBlockListProducesEmptyString() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [])
        #expect(attributed.string.isEmpty)
    }

    @Test func builderCachesByBlockSequence() {
        let blocks: [PickyMarkdownInlineTextView.InlineBlock] = [
            .paragraph("cached"),
            .bullet("entry")
        ]
        // Two calls with the same input return the same NSAttributedString
        // instance from the NSCache layer. This is what keeps SwiftUI body
        // re-renders (the same `groupedBlocks()` for the same markdown)
        // from rebuilding the heavyweight attributed string every tick.
        let first = PickyMarkdownInlineTextView.buildAttributedString(from: blocks)
        let second = PickyMarkdownInlineTextView.buildAttributedString(from: blocks)
        #expect(first === second)
    }
}
