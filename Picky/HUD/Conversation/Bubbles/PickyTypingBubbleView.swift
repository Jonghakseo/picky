//
//  PickyTypingBubbleView.swift
//  Picky
//
//  Thinking bubble for active agent reasoning previews.
//

import SwiftUI

struct PickyTypingBubbleView: View {
    let message: PickySessionMessage
    @State private var isAnimating = false
    @State private var isCollapsed: Bool

    init(message: PickySessionMessage, initiallyCollapsed: Bool = false) {
        self.message = message
        _isCollapsed = State(initialValue: initiallyCollapsed)
    }

    var body: some View {
        HStack {
            Button {
                isCollapsed.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 5) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 8.5, weight: .bold))
                        Text("⌁ thinking")
                            .font(.system(size: 9.5, weight: .semibold))
                        HStack(spacing: 3) {
                            ForEach(0..<3, id: \.self) { index in
                                Circle()
                                    .fill(DS.Colors.info)
                                    .frame(width: 3.5, height: 3.5)
                                    .opacity(isAnimating ? 1.0 : 0.25)
                                    .animation(
                                        .easeInOut(duration: 0.6)
                                            .repeatForever(autoreverses: true)
                                            .delay(Double(index) * 0.18),
                                        value: isAnimating
                                    )
                            }
                        }
                    }
                    .foregroundColor(DS.Colors.info)
                    if !isCollapsed, let text = message.text, !text.isEmpty {
                        PickyConversationMarkdownText(markdown: text)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .leading)
                .contentShape(Rectangle())
                .background(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12,
                        style: .continuous
                    )
                    .fill(DS.Colors.info.opacity(0.10))
                )
                .overlay(
                    UnevenRoundedRectangle(
                        topLeadingRadius: 12,
                        bottomLeadingRadius: 4,
                        bottomTrailingRadius: 12,
                        topTrailingRadius: 12,
                        style: .continuous
                    )
                    .stroke(DS.Colors.info.opacity(0.30), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thinking")
            .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
            .help(isCollapsed ? "Expand thinking" : "Collapse thinking")
            .pointerCursor()
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { isAnimating = true }
    }
}
