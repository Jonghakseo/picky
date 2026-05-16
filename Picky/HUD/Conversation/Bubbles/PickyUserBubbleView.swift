//
//  PickyUserBubbleView.swift
//  Picky
//
//  User-authored message bubble for conversation cards.
//

import SwiftUI

struct PickyUserBubbleView: View {
    let message: PickySessionMessage
    var onOpenAsReport: (() -> Void)? = nil
    var onCopyText: ((String) -> Void)? = nil
    var onEditText: ((String) -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 4) {
                PickyConversationMarkdownText(
                    markdown: displayedMarkdownPreview,
                    fillsAvailableWidth: false
                )
                .multilineTextAlignment(.leading)
                if let displayedAttachedImagesLabel {
                    Text(displayedAttachedImagesLabel)
                        .font(PickyHUDTypography.minimumMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .help("Screenshots from the current display were attached to this message as model context.")
                }
                if let originLabel {
                    Text(originLabel)
                        .font(PickyHUDTypography.minimumMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                userBubbleShape
                    .fill(bubbleFill)
            )
            // Clip content to the bubble shape so that any text-selection focus
            // re-measurement (`.textSelection(.enabled)` can ignore SwiftUI line
            // limits on macOS) can't visibly overflow the rounded background.
            .clipShape(userBubbleShape)
            .contextMenu { contextMenuItems }
            .frame(maxWidth: pickyHUDDetailWidth * 0.85, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var userBubbleShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: 12,
            bottomLeadingRadius: 12,
            bottomTrailingRadius: 4,
            topTrailingRadius: 12,
            style: .continuous
        )
    }

    var displayedOriginLabel: String? { originLabel }
    var displayedMarkdownPreview: String {
        PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
    }

    private var actionText: String? {
        let text = message.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let actionText, let onCopyText {
            Button("Copy Text") { onCopyText(actionText) }
        }
        if let actionText, let onEditText {
            Button("Edit in Composer") { onEditText(actionText) }
        }
        if let onOpenAsReport, PickyAgentResponsePreview.isTruncated(message.text ?? "") {
            Button("Open as Report", action: onOpenAsReport)
        }
    }

    private var isPiExtensionMessage: Bool {
        message.originatedBy == .piExtension
    }

    private var bubbleFill: Color {
        if isPiExtensionMessage { return DS.Colors.surface2.opacity(0.92) }
        return DS.Colors.accentSubtle.opacity(0.95)
    }

    private var originLabel: String? {
        switch message.originatedBy {
        case .mainAgent:
            return "by Picky"
        case .piExtension:
            return "from Pi terminal"
        case .user, nil:
            return nil
        }
    }

    var displayedAttachedImagesLabel: String? {
        guard let count = message.attachedImagesCount, count > 0 else { return nil }
        return "🖥️ \(count) attached"
    }
}
