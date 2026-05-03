//
//  CompanionPanelMessagesView.swift
//  Picky
//
//  Recent user/main-agent messages for the menu bar panel.
//

import SwiftUI

struct CompanionPanelMessagesView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if companionManager.mainAgentMessages.isEmpty {
                emptyState
            } else {
                LazyVStack(alignment: .leading, spacing: 9) {
                    ForEach(companionManager.mainAgentMessages) { message in
                        CompanionPanelMessageBubble(message: message)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Messages")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textPrimary)
            Text("Recent STT prompts and main-agent replies. Keeps the latest 100 messages.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
            Text("No messages yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Use push-to-talk and Picky will show your STT message plus the main agent reply here.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPanelCardBackground(tint: DS.Colors.accentText))
    }
}

private struct CompanionPanelMessageBubble: View {
    let message: PickyMainAgentMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .assistant { bubble }
            if message.role == .user { Spacer(minLength: 28) }
            if message.role == .user { bubble }
            if message.role == .assistant { Spacer(minLength: 28) }
        }
    }

    private var bubble: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 9.5, weight: .bold))
                Text(message.role == .user ? "You" : "Picky")
                    .font(.system(size: 10.5, weight: .semibold))
                Spacer(minLength: 8)
                Text(message.createdAt, formatter: Self.timeFormatter)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .foregroundColor(message.role == .user ? DS.Colors.accentText : DS.Colors.textSecondary)

            Text(message.text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(message.role == .user ? DS.Colors.accent.opacity(0.13) : DS.Colors.surface1.opacity(0.86))
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .stroke(DS.Colors.borderSubtle.opacity(0.68), lineWidth: 0.8)
                )
        )
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}
