//
//  PickyTypingBubbleView.swift
//  Picky
//
//  Thinking bubble for active agent reasoning previews.
//

import SwiftUI

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
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .pickyFont(size: 8.5, weight: .bold)
                        Text("⌁ thinking")
                            .font(PickyHUDTypography.metaSemibold)
                    }
                    .foregroundColor(DS.Colors.info)
                    if !isCollapsed, let text = message.text, !text.isEmpty {
                        PickyConversationMarkdownText(markdown: text)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth), alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    PickyConversationBubbleLayout.bubbleShape(side: .agent)
                        .fill(DS.Colors.info.opacity(0.10))
                )
                .overlay(
                    PickyConversationBubbleLayout.bubbleShape(side: .agent)
                        .stroke(DS.Colors.info.opacity(0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thinking")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .help(isCollapsed ? "Expand thinking" : "Collapse thinking")
            .pointerCursor()
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: externallyCollapsed) { _, newValue in
            isCollapsed = newValue
        }
    }
}
