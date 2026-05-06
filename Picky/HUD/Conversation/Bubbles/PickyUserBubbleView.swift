//
//  PickyUserBubbleView.swift
//  Picky
//
//  User-authored message bubble for conversation cards.
//

import SwiftUI

struct PickyUserBubbleView: View {
    let message: PickySessionMessage

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 4) {
                PickyConversationMarkdownText(
                    markdown: displayedMarkdownPreview,
                    lineLimit: PickyAgentResponsePreview.maxLines,
                    fillsAvailableWidth: false
                )
                .multilineTextAlignment(.leading)
                if let originLabel {
                    Text(originLabel)
                        .font(PickyHUDTypography.minimumMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(bubbleFill)
            )
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var displayedOriginLabel: String? { originLabel }
    var displayedMarkdownPreview: String {
        PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
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
            return "by main agent"
        case .piExtension:
            return "from Pi extension"
        case .user, nil:
            return nil
        }
    }
}
