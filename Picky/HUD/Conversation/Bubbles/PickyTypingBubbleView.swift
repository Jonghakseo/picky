//
//  PickyTypingBubbleView.swift
//  Picky
//
//  Thinking bubble for active agent reasoning previews.
//

import SwiftUI

enum PickyThinkingBlockPresentation {
    static var title: String { L10n.t("hud.thinking.title") }

    static func state(isCollapsed: Bool) -> String {
        L10n.t(isCollapsed ? "hud.conversation.turn.collapsed" : "hud.conversation.turn.expanded")
    }

    static func help(isCollapsed: Bool) -> String {
        L10n.t(isCollapsed ? "hud.thinking.expand" : "hud.thinking.collapse")
    }
}

struct PickyTypingBubbleView: View {
    let message: PickySessionMessage
    let externallyCollapsed: Bool
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @State private var isCollapsed: Bool

    init(message: PickySessionMessage, initiallyCollapsed: Bool = false) {
        self.message = message
        self.externallyCollapsed = initiallyCollapsed
        _isCollapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        let _ = PickyPerf.event("typing_bubble_body")
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Button {
                isCollapsed.toggle()
            } label: {
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    HStack(spacing: DS.Spacing.space1) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .pickyFont(size: 8.5, weight: .semibold)
                        Text(PickyThinkingBlockPresentation.title)
                            .font(PickyHUDTypography.metaMedium)
                    }
                    .foregroundColor(DS.Colors.textTertiary)
                    if !isCollapsed, let text = message.text, !text.isEmpty {
                        PickyConversationMarkdownText(markdown: text)
                    }
                }
                .padding(.horizontal, DS.Spacing.space2)
                .padding(.vertical, DS.Spacing.space1)
                .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth), alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(PickyThinkingBlockPresentation.title)
            .accessibilityValue(PickyThinkingBlockPresentation.state(isCollapsed: isCollapsed))
            .help(PickyThinkingBlockPresentation.help(isCollapsed: isCollapsed))
            .hoverAffordance()
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: externallyCollapsed) { _, newValue in
            isCollapsed = newValue
        }
    }
}
