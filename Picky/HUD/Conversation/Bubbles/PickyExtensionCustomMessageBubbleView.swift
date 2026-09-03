//
//  PickyExtensionCustomMessageBubbleView.swift
//  Picky
//
//  Labeled, collapsible bubble for Pi `role="custom"` extension messages.
//

import SwiftUI

/// Mirrors Pi's terminal treatment of custom messages: the `customType` label
/// stays visible and the payload folds down to a bounded preview so a long
/// extension notification cannot swallow the transcript.
struct PickyExtensionCustomMessageBubbleView: View {
    let presentation: PickyExtensionCustomMessagePresentation
    var onOpenAsReport: (() -> Void)? = nil
    var onCopyText: ((String) -> Void)? = nil

    @State private var isExpanded = false
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        let _ = PickyPerf.event("extension_custom_message_bubble_body")
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                header
                body(for: isExpanded ? presentation.fullText : presentation.previewLines.joined(separator: "\n"))
            }
            .padding(.horizontal, 10) // design-token-exception: matches the agent and notify bubble inset so text aligns down the conversation column
            .padding(.vertical, DS.Spacing.space2)
            .frame(
                maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth),
                alignment: .leading
            )
            .background(bubbleShape.fill(DS.Colors.surface3.opacity(0.86)))
            .overlay(bubbleShape.stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.7))
            .clipShape(bubbleShape)
            .contextMenu { contextMenuItems }
            .openAsReportHoverIcon(onOpen: onOpenAsReport, alignment: .topTrailing)
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.easeOut(duration: DS.Animation.fast), value: isExpanded)
    }

    @ViewBuilder
    private var header: some View {
        if presentation.isCollapsible {
            Button {
                isExpanded.toggle()
            } label: {
                headerLabel
            }
            .buttonStyle(.plain)
            .accessibilityLabel(presentation.customType)
            .accessibilityValue(L10n.t(isExpanded ? "hud.conversation.turn.expanded" : "hud.conversation.turn.collapsed"))
            .help(L10n.t(isExpanded ? "hud.extensionMessage.collapse" : "hud.extensionMessage.expand"))
            .hoverAffordance()
        } else {
            headerLabel
        }
    }

    private var headerLabel: some View {
        HStack(spacing: DS.Spacing.space1) {
            if presentation.isCollapsible {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .pickyFont(size: 8.5, weight: .semibold)
            }
            Text(presentation.customType)
                .font(PickyHUDTypography.metaMonospacedMedium)
            if presentation.isCollapsible, !isExpanded {
                Text(L10n.t("hud.extensionMessage.moreLines", Int64(presentation.hiddenLineCount)))
                    .font(PickyHUDTypography.metaMedium)
            }
        }
        .foregroundColor(DS.Colors.textTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func body(for text: String) -> some View {
        Text(text)
            .pickyFont(size: 11, design: .monospaced)
            .foregroundStyle(DS.Colors.textSecondary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var contextMenuItems: some View {
        if let onCopyText {
            Button(L10n.t("hud.extensionMessage.copy")) { onCopyText(presentation.fullText) }
        }
        if let onOpenAsReport {
            Button(L10n.t("hud.extensionMessage.openAsReport")) { onOpenAsReport() }
        }
    }

    private var bubbleShape: UnevenRoundedRectangle {
        PickyConversationBubbleLayout.bubbleShape(side: .agent)
    }
}
