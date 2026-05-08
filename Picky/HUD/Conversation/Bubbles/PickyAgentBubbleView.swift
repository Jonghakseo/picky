//
//  PickyAgentBubbleView.swift
//  Picky
//
//  Markdown-aware agent message bubble for conversation cards.
//

import SwiftUI

struct PickyAgentBubbleView: View {
    let message: PickySessionMessage
    var onOpenAsReport: (() -> Void)? = nil

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                PickyConversationMarkdownText(markdown: previewText, lineLimit: PickyAgentResponsePreview.maxLines)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .leading)
            .background(
                agentBubbleShape
                    .fill(DS.Colors.surface3.opacity(0.84))
            )
            .overlay(
                agentBubbleShape
                    .stroke(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7)
            )
            .openAsReportHoverIcon(onOpen: onOpenAsReport, alignment: .topTrailing)
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var agentBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: 4,
            bottomTrailingRadius: 12,
            topTrailingRadius: 12,
            style: .continuous
        )
    }

    private var previewText: String {
        let text = displayText
        guard message.kind == .agentText else { return text }
        return PickyAgentResponsePreview.truncatedMarkdown(text)
    }

    private var displayText: String {
        if let text = message.text, !text.isEmpty { return text }
        if let errorMessage = message.errorMessage, !errorMessage.isEmpty { return errorMessage }
        if let question = message.question { return question.prompt ?? question.title ?? "Input requested" }
        return ""
    }
}

enum PickyAgentResponsePreview {
    static let maxLines = 8
    static let maxCharacters = 500

    static func truncatedMarkdown(_ text: String, maxLines: Int = maxLines, maxCharacters: Int = maxCharacters) -> String {
        guard maxLines > 0, maxCharacters > 0 else { return "..." }
        var candidate = text
        var didTruncate = false

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if lines.count > maxLines {
            candidate = lines.prefix(maxLines).joined(separator: "\n")
            didTruncate = true
        }

        if candidate.count > maxCharacters {
            let endIndex = candidate.index(candidate.startIndex, offsetBy: maxCharacters)
            candidate = String(candidate[..<endIndex])
            didTruncate = true
        }

        guard didTruncate else { return text }
        return candidate.trimmingCharacters(in: .whitespacesAndNewlines) + "..."
    }
}
