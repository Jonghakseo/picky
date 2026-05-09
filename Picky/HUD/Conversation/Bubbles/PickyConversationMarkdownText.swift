//
//  PickyConversationMarkdownText.swift
//  Picky
//
//  Compact Markdown renderer for Pickle conversation bubbles.
//

import SwiftUI

struct PickyConversationMarkdownText: View {
    let markdown: String
    var lineLimit: Int? = nil
    var fillsAvailableWidth = true

    private let renderer = PickyReportMarkdownRenderer()

    var body: some View {
        if fillsAvailableWidth {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            content
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
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(PickyHUDTypography.body)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(PickyHUDTypography.bodySemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(PickyHUDTypography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(lineLimit)
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
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(PickyHUDTypography.supportingMonospaced)
                    .foregroundColor(DS.Colors.codeText)
                    .lineLimit(lineLimit)
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
        PickyHUDTypography.heading(level: level)
    }
}
