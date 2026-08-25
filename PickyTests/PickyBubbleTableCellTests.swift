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
    /// Mirrors what AppKit does when a click installs the field editor.
    private func fieldEditorAttributes(for field: NSTextField) -> (font: NSFont?, alignment: NSTextAlignment?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 80),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        field.frame = NSRect(x: 10, y: 10, width: 380, height: 40)
        window.contentView?.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        field.selectText(nil)
        guard let editor = window.fieldEditor(false, for: field) as? NSTextView,
              let storage = editor.textStorage,
              storage.length > 0 else {
            return (nil, nil)
        }
        let font = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        return (font, style?.alignment)
    }

    @Test func clickingACodeCellKeepsItsMonospacedRun() {
        let field = PickyBubbleMarkdownTableCell.makeField(
            text: "`reservation-cancel.service.ts:349`",
            isHeader: false
        )
        let rendered = field.attributedStringValue.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        #expect(rendered?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)

        let editor = fieldEditorAttributes(for: field)
        // Without allowsEditingTextAttributes this collapsed to the label's
        // own system font, which is what made the text jump size on click.
        #expect(editor.font?.fontDescriptor.symbolicTraits.contains(.monoSpace) == true)
        #expect(editor.font?.pointSize == rendered?.pointSize)
    }

    @Test func clickingABoldCellKeepsItsWeight() {
        let field = PickyBubbleMarkdownTableCell.makeField(text: "**58/58**", isHeader: false)
        let editor = fieldEditorAttributes(for: field)
        #expect(editor.font?.fontDescriptor.symbolicTraits.contains(.bold) == true)
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
