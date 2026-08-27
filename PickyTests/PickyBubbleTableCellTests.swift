//
//  PickyBubbleTableCellTests.swift
//  PickyTests
//
//  Guards the markdown table cells inside conversation bubbles.
//
//  Clicking a selectable NSTextField installs the shared field editor. With
//  rich text disabled that editor runs in plain-text mode and repaints the
//  whole string using the *cell's* font and alignment, which setting
//  `attributedStringValue` never updates. A cell holding monospaced or bold
//  runs therefore resized the instant it was clicked.
//

import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Picky

@MainActor
struct PickyBubbleTableCellTests {
    @Test func cellMeasurementCoversTheHeightUsedByWrappedRendering() throws {
        let field = PickyBubbleMarkdownTableCell.makeField(
            text: "`tz: ''`를 Bull은 no-tz로, 헬퍼는 빈 문자열로 해석하여 같은 repeat key를 stale로 삭제할 수 있음",
            isHeader: false
        )
        let cell = try #require(field.cell)
        var foundBoundingRectMismatch = false

        for widthValue in 120...460 {
            let width = CGFloat(widthValue)
            let renderedHeight = ceil(cell.cellSize(
                forBounds: NSRect(
                    x: 0,
                    y: 0,
                    width: width,
                    height: CGFloat.greatestFiniteMagnitude
                )
            ).height)
            let measuredHeight = ceil(PickyBubbleMarkdownTableCell.measuredContentHeight(
                for: field,
                width: width
            ))
            let boundingHeight = ceil(field.attributedStringValue.boundingRect(
                with: NSSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)

            #expect(measuredHeight >= renderedHeight)
            foundBoundingRectMismatch = foundBoundingRectMismatch || renderedHeight > boundingHeight
        }

        #expect(foundBoundingRectMismatch)
    }

    @Test func codeCellSelectionPreservesItsMonospacedRun() {
        let field = PickyBubbleMarkdownTableCell.makeField(
            text: "`reservation-cancel.service.ts:349`",
            isHeader: false
        )
        let rendered = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        // A selectable field with this disabled asks AppKit's shared field
        // editor to flatten rich runs, which made code resize on click.
        #expect(field.isSelectable)
        #expect(!field.isEditable)
        #expect(field.allowsEditingTextAttributes)
        #expect(rendered?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
    }

    @Test func boldCellSelectionPreservesItsWeight() {
        let field = PickyBubbleMarkdownTableCell.makeField(text: "**58/58**", isHeader: false)
        let rendered = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont

        #expect(field.allowsEditingTextAttributes)
        #expect(rendered?.fontDescriptor.symbolicTraits.contains(.bold) == true)
    }

    @Test func dataCellsAreLeftAlignedRegardlessOfColumn() {
        // The first column used to be centered, so clicking it also shifted
        // the text sideways. Text columns align left like every other column.
        let field = PickyBubbleMarkdownTableCell.makeField(text: "runner.mjs", isHeader: false)
        let style = field.attributedStringValue.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle
        #expect(style?.alignment != .center)
    }

    @Test func dataCellsKeepTheInlineRenderersSemanticColors() {
        let field = PickyBubbleMarkdownTableCell.makeField(
            text: "plain `code` text",
            isHeader: false
        )
        let attributed = field.attributedStringValue
        let codeRange = (attributed.string as NSString).range(of: "code")
        let codeColor = attributed.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let proseColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        // A blanket foreground override used to repaint code and links in the
        // body color, erasing the only cue that a cell held an identifier.
        #expect(codeColor != nil)
        #expect(proseColor != nil)
        #expect(codeColor?.usingColorSpace(.sRGB)?.redComponent != proseColor?.usingColorSpace(.sRGB)?.redComponent)
    }

    @Test func headerCellsPromoteProseToSemiboldButKeepCodeTint() {
        let field = PickyBubbleMarkdownTableCell.makeField(text: "name `id`", isHeader: true)
        let attributed = field.attributedStringValue
        let proseFont = attributed.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(proseFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == false)

        let codeRange = (attributed.string as NSString).range(of: "id")
        let codeFont = attributed.attribute(.font, at: codeRange.location, effectiveRange: nil) as? NSFont
        let codeColor = attributed.attribute(.foregroundColor, at: codeRange.location, effectiveRange: nil) as? NSColor
        let proseColor = attributed.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        #expect(codeFont?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(codeColor?.usingColorSpace(.sRGB)?.blueComponent != proseColor?.usingColorSpace(.sRGB)?.blueComponent)
    }
}
