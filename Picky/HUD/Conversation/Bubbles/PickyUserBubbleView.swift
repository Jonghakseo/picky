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
            // User bubble is right-aligned; show the hover icon on the OUTWARD
            // (leading) corner so it floats toward the agent side rather than
            // pinning against the card edge. Only show when the source text is
            // long enough to be truncated by the preview — short messages don't
            // need an "expand" affordance.
            .openAsReportHoverIcon(onOpen: hoverIconAction, alignment: .topLeading)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var displayedOriginLabel: String? { originLabel }
    var displayedMarkdownPreview: String {
        PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
    }

    private var hoverIconAction: (() -> Void)? {
        guard let onOpenAsReport, PickyAgentResponsePreview.isTruncated(message.text ?? "") else { return nil }
        return onOpenAsReport
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
