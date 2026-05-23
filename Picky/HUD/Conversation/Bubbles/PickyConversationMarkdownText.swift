//
//  PickyConversationMarkdownText.swift
//  Picky
//
//  Compact Markdown renderer for Pickle conversation bubbles.
//
//  Inline blocks (heading/paragraph/bullet) fold into a single NSTextView
//  (PickyMarkdownInlineTextView) so selection sweeps across them and the
//  macOS 26.x NSTextSelectionNavigation main-thread spin we saw on 2026-05-20
//  doesn't recur. Tables and code blocks stay as SwiftUI views because they
//  need horizontal scroll / column layout the text container can't express.
//

import SwiftUI

struct PickyConversationMarkdownText: View {
    let markdown: String
    var fillsAvailableWidth = true
    /// Per-block cap for fenced code output. Bash console dumps (`!git pull`,
    /// long stack traces) can otherwise grow the card to unbounded height.
    /// The full text stays in the underlying message (terminal overlay / open
    /// as report still show everything); only the inline preview is capped.
    /// Centralized in `PickyAgentResponsePreview` so the hover "open as report"
    /// gate can predict the same per-block truncation the renderer applies.
    var codeBlockMaxLines: Int = PickyAgentResponsePreview.codeBlockMaxLines
    /// Hug-fit width cap forwarded to the inline NSTextView wrapper when
    /// `fillsAvailableWidth == false`. Without this, the wrapper would
    /// inherit the parent's full width proposal as its ideal size and
    /// stretch the user bubble background to the entire 85% card column
    /// regardless of how short the message text is.
    var hugContentMaxWidth: CGFloat?
    /// Forwarded into the inline NSTextView wrapper's right-click menu when
    /// non-nil. Bubble views pass their existing "Open as Report" closure
    /// through so the in-text menu offers the same shortcut their SwiftUI
    /// `.contextMenu` does on the bubble surround.
    var onOpenAsReport: (() -> Void)?

    private let renderer = PickyReportMarkdownRenderer()

    var body: some View {
        if fillsAvailableWidth {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.openURL, pickyDeepLinkOpenURL)
        } else {
            content
                .environment(\.openURL, pickyDeepLinkOpenURL)
        }
    }

    /// Intercepts `picky://...` clicks so a deep link in the assistant
    /// reply opens the right companion panel screen instead of bouncing
    /// to the browser. Other schemes (https, mailto) fall through to the
    /// system handler unchanged.
    ///
    /// Still applied even though inline text is now rendered through an
    /// NSTextView (the wrapper's coordinator handles links there); table
    /// cells and any future SwiftUI fragment still rely on
    /// `Environment(\.openURL)` for deep-link routing.
    private var pickyDeepLinkOpenURL: OpenURLAction {
        OpenURLAction { url in
            if PickyDeepLinkDispatcher.shared.handle(url) {
                return .handled
            }
            return .systemAction
        }
    }

    /// Bucketed block stream:
    ///   - runs of inline blocks (heading/paragraph/bullet) collapse into
    ///     one NSTextView so selection spans them, and
    ///   - codeBlock/table blocks stay as their existing SwiftUI views.
    /// A code/table interruption splits inline runs — that matches the
    /// per-block selection-island behavior the previous composition
    /// already exhibited.
    private enum BlockGroup {
        case inline([PickyMarkdownInlineTextView.InlineBlock])
        case table(headers: [String], rows: [[String]])
        case codeBlock(String)
    }

    private func groupedBlocks() -> [BlockGroup] {
        var groups: [BlockGroup] = []
        var inlineBuffer: [PickyMarkdownInlineTextView.InlineBlock] = []

        func flushInline() {
            guard !inlineBuffer.isEmpty else { return }
            groups.append(.inline(inlineBuffer))
            inlineBuffer.removeAll(keepingCapacity: true)
        }

        for block in renderer.blocks(from: markdown) {
            switch block {
            case .heading(let level, let text):
                inlineBuffer.append(.heading(level: level, text: text))
            case .paragraph(let text):
                inlineBuffer.append(.paragraph(text))
            case .bullet(let text):
                inlineBuffer.append(.bullet(text))
            case .table(let headers, let rows):
                flushInline()
                groups.append(.table(headers: headers, rows: rows))
            case .codeBlock(let text):
                flushInline()
                groups.append(.codeBlock(text))
            }
        }
        flushInline()
        return groups
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(groupedBlocks().enumerated()), id: \.offset) { _, group in
                groupView(group)
            }
        }
    }

    @ViewBuilder
    private func groupView(_ group: BlockGroup) -> some View {
        switch group {
        case .inline(let blocks):
            // Horizontal axis: when we want to hug content (user bubble),
            // pin the wrapper to its ideal width via fixedSize so SwiftUI
            // does not feed it the full parent proposal and stretch the
            // bubble background to the 85% card column. The wrapper's
            // `sizeThatFits` already lays out at `hugContentMaxWidth` and
            // reports the measured glyph width as its ideal, so the
            // resulting bubble width is min(measured, cap) — short
            // messages hug, long messages wrap at the cap.
            //
            // Agent bubble keeps `fillsAvailableWidth = true` and the
            // horizontal axis unfixed so it continues to stretch to the
            // SwiftUI-allotted column. Macroscopic regression history:
            // commits 66cb4a0d and 23c2f321 fixed the wrapper's reported
            // size but not this axis override; on macOS 26.x the parent's
            // proposal still won, which is what the user reported in the
            // 2026-05-21 screenshot.
            PickyMarkdownInlineTextView(
                blocks: blocks,
                fillsAvailableWidth: fillsAvailableWidth,
                hugContentMaxWidth: hugContentMaxWidth,
                onOpenAsReport: onOpenAsReport
            )
            .fixedSize(horizontal: !fillsAvailableWidth, vertical: true)
        case .table(let headers, let rows):
            tableBlockView(headers: headers, rows: rows)
        case .codeBlock(let text):
            codeBlockView(text)
        }
    }

    @ViewBuilder
    private func tableBlockView(headers: [String], rows: [[String]]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(headers.joined(separator: " · "))
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundColor(DS.Colors.textPrimary)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                Text(row.joined(separator: " · "))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textPrimary.opacity(0.92))
            }
        }
        .padding(8)
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    @ViewBuilder
    private func codeBlockView(_ text: String) -> some View {
        let lines = text.components(separatedBy: "\n")
        let isTruncated = codeBlockMaxLines > 0 && lines.count > codeBlockMaxLines
        let displayText: String = isTruncated
            ? lines.prefix(codeBlockMaxLines).joined(separator: "\n")
            : text
        let omittedCount: Int = isTruncated ? lines.count - codeBlockMaxLines : 0

        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(displayText.isEmpty ? " " : displayText)
                    .font(PickyHUDTypography.supportingMonospaced)
                    .foregroundColor(DS.Colors.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if omittedCount > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "ellipsis")
                        .pickyFont(size: 8, weight: .bold)
                    Text("+\(omittedCount) more line\(omittedCount == 1 ? "" : "s")")
                        .font(PickyHUDTypography.metaMedium)
                }
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface3.opacity(0.55))
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(DS.Colors.borderSubtle.opacity(0.6))
                        .frame(height: 0.5)
                }
            }
        }
        .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
        )
    }
}
