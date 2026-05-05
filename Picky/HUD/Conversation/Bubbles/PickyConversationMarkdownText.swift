//
//  PickyConversationMarkdownText.swift
//  Picky
//
//  Compact Markdown renderer for side-agent conversation bubbles.
//

import SwiftUI

struct PickyConversationMarkdownText: View {
    let markdown: String

    private let renderer = PickyReportMarkdownRenderer()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(renderer.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 4) {
                Text(headers.joined(separator: " · "))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.joined(separator: " · "))
                        .font(.system(size: 11, weight: .regular))
                        .foregroundColor(DS.Colors.textPrimary.opacity(0.92))
                }
            }
            .padding(8)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
                    .foregroundColor(DS.Colors.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
        }
    }

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: return .system(size: 14, weight: .semibold)
        case 2: return .system(size: 13, weight: .semibold)
        default: return .system(size: 12.5, weight: .semibold)
        }
    }
}
