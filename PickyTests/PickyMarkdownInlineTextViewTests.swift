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
import SwiftUI
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

    @Test func blockGapLivesOnTheFollowingBlockAsSpacingBefore() {
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
        // Gaps are encoded from the leading edge so a heading can carry a large
        // gap above and a small one below in a single paragraph style.
        #expect(firstStyle?.paragraphSpacingBefore == 0)
        #expect(secondStyle?.paragraphSpacingBefore == PickyMarkdownBlockSpacing.bubble.paragraph)
    }

    @Test func headingDetachesFromPreviousBlockAndBindsToNextOne() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("Intro"),
            .heading(level: 2, text: "Section"),
            .paragraph("Body")
        ])
        let headingRange = (attributed.string as NSString).range(of: "Section")
        let bodyRange = (attributed.string as NSString).range(of: "Body")
        let headingStyle = attributed.attribute(
            .paragraphStyle,
            at: headingRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        let bodyStyle = attributed.attribute(
            .paragraphStyle,
            at: bodyRange.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(headingStyle?.paragraphSpacingBefore == PickyMarkdownBlockSpacing.bubble.headingLeading)
        #expect(bodyStyle?.paragraphSpacingBefore == PickyMarkdownBlockSpacing.bubble.headingTrailing)
    }

    @Test func consecutiveBulletsPackTighterThanParagraphs() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("Intro"),
            .bullet("one"),
            .bullet("two")
        ])
        let secondBullet = (attributed.string as NSString).range(of: "two")
        let style = attributed.attribute(
            .paragraphStyle,
            at: secondBullet.location,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.paragraphSpacingBefore == PickyMarkdownBlockSpacing.bubble.bullet)
    }

    @Test func blockSeparatorInheritsPrecedingParagraphStyle() {
        // The newline that joins two blocks terminates the *previous*
        // paragraph. Leaving it unattributed drops that paragraph's indent and
        // line height on its final line.
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .bullet("first bullet"),
            .paragraph("after")
        ])
        let newlineIndex = (attributed.string as NSString).range(of: "\n").location
        let separatorStyle = attributed.attribute(
            .paragraphStyle,
            at: newlineIndex,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(separatorStyle?.headIndent == 14)
        #expect(attributed.attribute(.link, at: newlineIndex, effectiveRange: nil) == nil)
    }

    @Test func inlineCodeRunUsesMonospacedCodeTint() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("call `spawnManaged()` first")
        ])
        #expect(attributed.string == "call spawnManaged() first")

        let codeRange = (attributed.string as NSString).range(of: "spawnManaged()")
        let codeFont = attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let proseFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let codeColor = attributed.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let proseColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(codeFont?.pointSize == PickyHUDTypography.Size.supporting)
        #expect(codeFont?.fontName != proseFont?.fontName)
        #expect(Self.rgb(codeColor) == Self.rgb(NSColor(DS.Colors.codeText)))
        #expect(Self.rgb(codeColor) != Self.rgb(proseColor))
    }

    @Test func boldRunReadsBrighterThanSurroundingBodyText() {
        // Emphasis gains a second axis: bold steps up to textPrimary while the
        // body sits at textBody. Weight alone stops working once a reply is
        // mostly bold lead-ins.
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("plain **loud** plain")
        ])
        let boldRange = (attributed.string as NSString).range(of: "loud")
        let boldColor = attributed.attribute(.foregroundColor, at: boldRange.location, effectiveRange: nil) as? NSColor
        let bodyColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor

        #expect(Self.rgb(boldColor) == Self.rgb(NSColor(DS.Colors.textPrimary)))
        #expect(Self.rgb(bodyColor) == Self.rgb(NSColor(DS.Colors.textBody)))
        #expect(Self.rgb(boldColor) != Self.rgb(bodyColor))
    }

    private static func rgb(_ color: NSColor?) -> [CGFloat]? {
        guard let resolved = color?.usingColorSpace(.sRGB) else { return nil }
        return [resolved.redComponent, resolved.greenComponent, resolved.blueComponent]
            .map { ($0 * 1_000).rounded() / 1_000 }
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

    @Test func strikethroughRunKeepsMarkdownPresentation() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("before ~~100~~ after")
        ])

        #expect(attributed.string == "before 100 after")
        let struckRange = (attributed.string as NSString).range(of: "100")
        let struckStyle = attributed.attribute(
            .strikethroughStyle,
            at: struckRange.location,
            effectiveRange: nil
        ) as? Int
        let surroundingStyle = attributed.attribute(
            .strikethroughStyle,
            at: 0,
            effectiveRange: nil
        ) as? Int

        #expect(struckStyle == NSUnderlineStyle.single.rawValue)
        #expect(surroundingStyle == nil)
    }

    @Test func emptyBlockListProducesEmptyString() {
        let attributed = PickyMarkdownInlineTextView.buildAttributedString(from: [])
        #expect(attributed.string.isEmpty)
    }

    @Test func hugModeIntrinsicWidthUsesMeasuredTextInsteadOfFullCap() {
        let view = SelfSizingMarkdownTextView()
        view.textStorage?.setAttributedString(PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("근데 왜 이렇게 렉이 걸리지?")
        ]))
        view.fillsAvailableWidth = false
        view.hugContentMaxWidth = 900

        let size = view.intrinsicContentSize

        #expect(size.width > 100)
        #expect(size.width < 260)
    }

    @Test func fillModeIntrinsicWidthKeepsStretchableWidth() {
        let view = SelfSizingMarkdownTextView()
        view.textStorage?.setAttributedString(PickyMarkdownInlineTextView.buildAttributedString(from: [
            .paragraph("agent replies stretch to the available column")
        ]))
        view.fillsAvailableWidth = true
        view.hugContentMaxWidth = 900

        #expect(view.intrinsicContentSize.width == NSView.noIntrinsicMetric)
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
