//
//  PickyAgentBubbleView.swift
//  Picky
//
//  Markdown-aware agent message bubble for conversation cards.
//

import SwiftUI

struct PickyAgentBubbleView: View {
    let message: PickySessionMessage
    var contextUsage: PickyContextUsage? = nil
    var showsOpenAsReportAction = false
    var onOpenAsReport: (() -> Void)?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                PickyConversationMarkdownText(markdown: previewText, lineLimit: PickyAgentResponsePreview.maxLines)
                if showsFooter {
                    HStack(alignment: .center, spacing: 7) {
                        if showsOpenAsReportAction, let onOpenAsReport {
                            PickyOpenAsReportButton(action: onOpenAsReport)
                        }
                        if let assistantRunText {
                            PickyAssistantRunMetadataLabel(text: assistantRunText)
                            if let contextUsageDisplay {
                                PickyContextUsageChip(display: contextUsageDisplay)
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(DS.Colors.surface2.opacity(0.85))
            )
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var showsFooter: Bool {
        (showsOpenAsReportAction && onOpenAsReport != nil) || assistantRunText != nil
    }

    private var assistantRunText: String? {
        message.assistantRun?.displayText
    }

    private var contextUsageDisplay: ContextUsageBatteryDisplay? {
        guard assistantRunText != nil, let contextUsage else { return nil }
        return ContextUsageBatteryDisplay(usage: contextUsage)
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

struct PickyAssistantRunMetadataLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .medium, design: .monospaced))
            .foregroundColor(DS.Colors.textTertiary.opacity(0.72))
            .lineLimit(1)
            .truncationMode(.middle)
            .help("Model and reasoning level: \(text)")
    }
}

struct PickyOpenAsReportButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 8.5, weight: .semibold))
                Text("Open as report")
                    .font(.system(size: 9.5, weight: .semibold))
                Text("⌘R")
                    .font(.system(size: 8.5, weight: .bold, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.Colors.surface1.opacity(0.9)))
            }
            .foregroundColor(DS.Colors.accentText)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.28)))
            .overlay(Capsule().stroke(DS.Colors.accentText.opacity(0.24), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open this response in the report viewer (⌘R)")
        .pointerCursor()
    }
}
