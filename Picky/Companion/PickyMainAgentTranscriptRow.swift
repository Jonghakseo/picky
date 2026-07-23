//
//  PickyMainAgentTranscriptRow.swift
//  Picky
//
//  Shared transcript row for the main-agent Messages panel and Quick Input
//  history card. Both surfaces intentionally use the same no-bubble reading
//  treatment so a recent turn looks identical wherever it is revisited.
//

import SwiftUI

/// Transcript-style message row — no bubble, no alignment swap. Both user and assistant
/// turns flow left-aligned with a coloured role label and a timestamp on the right.
/// The accent colour on "You" provides enough visual differentiation that we don't need
/// the prior right-aligned bubble + chrome.
struct PickyMainAgentTranscriptRow: View {
    let message: PickyMainAgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.role == .user ? "You" : "Picky")
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(message.role == .user ? DS.Colors.accentText : DS.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(message.createdAt, formatter: Self.timeFormatter)
                    .font(PickyHUDTypography.minimumMedium)
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Main-agent replies arrive as Markdown (bold, inline code, bullets, fenced
            // blocks). User prompts are plain text—rendering them through the renderer
            // would silently change formatting if the user ever typed `*` or `_`, so keep
            // user turns as-is and only parse markdown for assistant turns.
            if message.role == .assistant {
                PickyMainAgentMarkdownText(markdown: message.text)
                    .textSelection(.enabled)
            } else {
                Text(message.text)
                    .pickyFont(size: 11.5, weight: .medium)
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

/// Compact markdown renderer for a main-agent transcript. Reuses
/// `PickyReportMarkdownRenderer` for parsing so heading / paragraph / bullet /
/// fenced-code blocks all render without raw `**`, backticks, or leading dashes
/// leaking through the way they did in plain `Text`. Fonts are sized for the
/// compact Messages and Quick Input surfaces, not the larger report viewer.
struct PickyMainAgentMarkdownText: View {
    let markdown: String
    private let renderer = PickyReportMarkdownRenderer()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(renderer.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            // Same `picky://` interception as the HUD bubble renderer: a
            // deep link in the main-agent reply opens the right companion
            // panel screen instead of falling through to the browser.
            PickyDeepLinkDispatcher.shared.handle(url) ? .handled : .systemAction
        })
    }

    @ViewBuilder
    private func blockView(_ block: PickyReportMarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(font(forHeadingLevel: level))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .pickyFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .pickyFont(size: 11.5, weight: .medium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 4) {
                Text(headers.joined(separator: " · "))
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.joined(separator: " · "))
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                }
            }
            .padding(8)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .pickyFont(size: 10.5, weight: .regular, design: .monospaced)
                    .foregroundStyle(DS.Colors.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
        }
    }

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: return .system(size: 13.5, weight: .semibold)
        case 2: return .system(size: 12.5, weight: .semibold)
        default: return .system(size: 12, weight: .semibold)
        }
    }
}
