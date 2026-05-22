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
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            PickyUserBubbleSurfaceView(
                markdown: displayedMarkdownPreview,
                attachedImagesLabel: displayedAttachedImagesLabel,
                originLabel: originLabel,
                isPiExtensionMessage: isPiExtensionMessage,
                maxBubbleWidth: bubbleMaxWidth,
                onOpenAsReport: textViewOpenAsReportAction,
                onCopyText: copyTextAction,
                onEditText: editTextAction
            )
            .frame(width: bubbleMaxWidth, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var displayedOriginLabel: String? { originLabel }
    var displayedMarkdownPreview: String {
        PickyAgentResponsePreview.truncatedMarkdown(message.text ?? "")
    }

    private var actionText: String? {
        let text = message.text ?? ""
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    private var copyTextAction: (() -> Void)? {
        guard let actionText, let onCopyText else { return nil }
        return { onCopyText(actionText) }
    }

    private var editTextAction: (() -> Void)? {
        guard let actionText, let onEditText else { return nil }
        return { onEditText(actionText) }
    }

    private var bubbleMaxWidth: CGFloat {
        PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth)
    }

    /// Mirrors the SwiftUI `.contextMenu` "Open as Report" gate so the
    /// in-text right-click menu only offers the action when the bubble's
    /// content is actually truncated in the preview.
    private var textViewOpenAsReportAction: (() -> Void)? {
        guard let onOpenAsReport,
              PickyAgentResponsePreview.isTruncated(message.text ?? "") else { return nil }
        return onOpenAsReport
    }

    private var isPiExtensionMessage: Bool {
        message.originatedBy == .piExtension
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
