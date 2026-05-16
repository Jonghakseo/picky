//
//  PickyConversationMarkdownText.swift
//  Picky
//
//  Compact Markdown renderer for Pickle conversation bubbles.
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
    private var pickyDeepLinkOpenURL: OpenURLAction {
        OpenURLAction { url in
            if PickyDeepLinkDispatcher.shared.handle(url) {
                return .handled
            }
            return .systemAction
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(renderer.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: PickyReportMarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(font(forHeadingLevel: level))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(PickyHUDTypography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(PickyHUDTypography.bodySemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(PickyHUDTypography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
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
        case .codeBlock(let text):
            codeBlockView(text)
        }
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
                        .font(.system(size: 8, weight: .bold))
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

    private func font(forHeadingLevel level: Int) -> Font {
        PickyHUDTypography.heading(level: level)
    }
}
