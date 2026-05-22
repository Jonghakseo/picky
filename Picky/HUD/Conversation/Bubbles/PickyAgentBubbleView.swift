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
    var onCopyText: ((String) -> Void)? = nil
    var isLatestResponseShortcutHintVisible = false

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            PickyAgentBubbleSurfaceView(
                markdown: previewText,
                maxBubbleWidth: bubbleMaxWidth,
                showsShortcutBadge: isLatestResponseShortcutHintVisible,
                onOpenAsReport: hoverIconAction,
                onCopyText: copyTextAction
            )
            .frame(width: bubbleMaxWidth, alignment: .leading)
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bubbleMaxWidth: CGFloat {
        PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth)
    }

    private var previewText: String {
        let text = displayText
        guard message.kind == .agentText else { return text }
        return PickyAgentResponsePreview.truncatedMarkdown(text)
    }

    private var copyTextAction: (() -> Void)? {
        let text = displayText
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let onCopyText else { return nil }
        return { onCopyText(text) }
    }

    /// Only expose the hover icon when the bubble's full text wouldn't fit in
    /// the card preview — i.e., the user is currently looking at a truncated
    /// view and might want to open the message in the markdown viewer.
    private var hoverIconAction: (() -> Void)? {
        guard let onOpenAsReport, PickyAgentResponsePreview.isTruncated(displayText) else { return nil }
        return onOpenAsReport
    }

    private var displayText: String {
        if let text = message.text, !text.isEmpty { return text }
        if let errorMessage = message.errorMessage, !errorMessage.isEmpty { return errorMessage }
        if let question = message.question { return question.prompt ?? question.title ?? "Input requested" }
        return ""
    }
}

struct PickyNotifyBubbleView: View {
    let message: PickySessionMessage
    var onOpenAsReport: (() -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Image(systemName: notifyType.iconName)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(notifyType.tintColor)
                    Text("Pi extension")
                        .font(PickyHUDTypography.minimumSemibold)
                        .foregroundColor(DS.Colors.textSecondary)
                    Text(notifyType.label)
                        .font(PickyHUDTypography.minimumSemibold)
                        .foregroundColor(notifyType.tintColor)
                        .padding(.horizontal, 5)
                        .frame(height: 15)
                        .background(Capsule(style: .continuous).fill(notifyType.tintColor.opacity(0.12)))
                        .overlay(Capsule(style: .continuous).strokeBorder(notifyType.tintColor.opacity(0.28), lineWidth: 0.6))
                }
                PickyConversationMarkdownText(
                    markdown: previewMarkdown,
                    onOpenAsReport: hoverIconAction
                )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth), alignment: .leading)
            .background(
                notifyBubbleShape
                    .fill(DS.Colors.surface3.opacity(0.86))
            )
            .overlay(
                notifyBubbleShape
                    .fill(notifyType.tintColor.opacity(0.055))
            )
            .overlay(
                notifyBubbleShape
                    .stroke(notifyType.tintColor.opacity(0.34), lineWidth: 0.7)
            )
            .clipShape(notifyBubbleShape)
            .openAsReportHoverIcon(onOpen: hoverIconAction, alignment: .topTrailing)
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    var previewMarkdown: String {
        PickyAgentResponsePreview.truncatedMarkdown(displayText)
    }

    var shouldOfferReport: Bool {
        PickyAgentResponsePreview.isTruncated(displayText)
    }

    private var hoverIconAction: (() -> Void)? {
        guard shouldOfferReport else { return nil }
        return onOpenAsReport
    }

    private var displayText: String {
        PickyAnsiEscapeSanitizer.stripped(message.text ?? "")
    }

    private var notifyType: PickyExtensionNotifyType {
        message.notifyType ?? .info
    }

    private var notifyBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: 4,
            bottomTrailingRadius: 12,
            topTrailingRadius: 12,
            style: .continuous
        )
    }
}

private extension PickyExtensionNotifyType {
    var label: String {
        switch self {
        case .info: return "Info"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }

    var iconName: String {
        switch self {
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var tintColor: Color {
        switch self {
        case .info: return DS.Colors.info
        case .warning: return DS.Colors.warningText
        case .error: return DS.Colors.destructiveText
        }
    }
}

enum PickyAgentResponsePreview {
    static let maxLines = 8
    static let maxCharacters = 500
    /// Mirrors `PickyConversationMarkdownText.codeBlockMaxLines`. Centralizing
    /// the constant here lets `isTruncated` predict the renderer's per-block
    /// truncation so the hover "open as report" gate matches what the user
    /// actually sees on screen.
    static let codeBlockMaxLines = 4

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

    /// Whether the given source text would be visibly truncated when rendered
    /// in a conversation bubble. Used by message bubbles to gate the
    /// hover-revealed open-as-report icon — short messages that fit fully in
    /// the card don't need an "expand" affordance.
    ///
    /// Three independent truncation paths must be considered together,
    /// because the bubble shows the result of all three:
    ///   1. Outer character cap (`maxCharacters`) applied by `truncatedMarkdown`.
    ///   2. Outer line cap (`maxLines`) applied by `truncatedMarkdown`.
    ///   3. Per-fenced-code-block cap (`codeBlockMaxLines`) applied inside
    ///      `PickyConversationMarkdownText.codeBlockView`, which renders a
    ///      "+N more lines" footer when an individual block is too tall.
    /// Previously only (1) and (2) were checked, which left short messages
    /// containing a long code block without the affordance even though the
    /// renderer was clearly truncating their preview.
    static func isTruncated(
        _ text: String,
        maxLines: Int = maxLines,
        maxCharacters: Int = maxCharacters,
        codeBlockMaxLines: Int = codeBlockMaxLines
    ) -> Bool {
        guard maxLines > 0, maxCharacters > 0 else { return false }
        if text.count > maxCharacters { return true }
        if text.split(separator: "\n", omittingEmptySubsequences: false).count > maxLines {
            return true
        }
        guard codeBlockMaxLines > 0 else { return false }
        for block in PickyReportMarkdownRenderer().blocks(from: text) {
            if case .codeBlock(let body) = block,
               body.components(separatedBy: "\n").count > codeBlockMaxLines {
                return true
            }
        }
        return false
    }
}
