//
//  CompanionPanelMessagesView.swift
//  Picky
//
//  Recent user/main-agent messages for the menu bar panel.
//

import SwiftUI

struct CompanionPanelMessagesView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var draftMessage = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.vertical, showsIndicators: true) {
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
                .padding(.bottom, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            directMessageComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 8) {
                Text("Messages")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)

                Spacer(minLength: 8)

                Button(action: resetMainAgentSession) {
                    HStack(spacing: 5) {
                        if companionManager.isResettingMainAgentSession {
                            ProgressView()
                                .controlSize(.small)
                                .frame(width: 11, height: 11)
                        } else {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 9.5, weight: .bold))
                        }
                        Text("New Session")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundColor(companionManager.isResettingMainAgentSession ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DS.Colors.surface2.opacity(0.86))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.8)
                            )
                    )
                }
                .buttonStyle(.plain)
                .disabled(companionManager.isResettingMainAgentSession)
                .pointerCursor()
            }

            Text("Recent prompts and main-agent replies. Keeps the latest 100 messages.")
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
            Text("Use push-to-talk or type a direct message below. Picky will show your prompt plus the main agent reply here.")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompanionPanelCardBackground(tint: DS.Colors.accentText))
    }

    private var directMessageComposer: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Picky…", text: $draftMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...3)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(DS.Colors.surface2.opacity(0.88))
                            .overlay(
                                RoundedRectangle(cornerRadius: 11, style: .continuous)
                                    .stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.8)
                            )
                    )
                    .onSubmit { submitDirectMessage() }

                Button(action: submitDirectMessage) {
                    Group {
                        if companionManager.isSendingDirectMessage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .frame(width: 30, height: 30)
                    .foregroundColor(isSubmitDisabled ? DS.Colors.textTertiary : DS.Colors.textOnAccent)
                    .background(
                        Circle()
                            .fill(isSubmitDisabled ? DS.Colors.surface3.opacity(0.7) : DS.Colors.accent)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isSubmitDisabled)
                .pointerCursor()
            }

            if let error = companionManager.directMessageError {
                Text(error)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(CompanionPanelCardBackground(tint: DS.Colors.accentText))
    }

    private var isSubmitDisabled: Bool {
        companionManager.isSendingDirectMessage || draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func submitDirectMessage() {
        let message = draftMessage
        Task { @MainActor in
            if await companionManager.sendDirectMessage(message) {
                draftMessage = ""
            }
        }
    }

    private func resetMainAgentSession() {
        Task { @MainActor in
            _ = await companionManager.resetMainAgentSession()
        }
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

            // Main-agent replies arrive as Markdown (bold, inline code, bullets, fenced
            // blocks). User prompts are plain text—rendering them through the renderer
            // would silently change formatting if the user ever typed `*` or `_`, so keep
            // user bubbles as-is and only parse markdown for assistant turns.
            if message.role == .assistant {
                CompanionPanelMarkdownText(markdown: message.text)
                    .textSelection(.enabled)
            } else {
                Text(message.text)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
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

/// Compact markdown renderer for the companion message bubble. Reuses
/// `PickyReportMarkdownRenderer` for parsing so heading / paragraph / bullet /
/// fenced-code blocks all render without raw `**`, backticks, or leading dashes
/// leaking through the way they did in plain `Text`. Fonts are sized for the
/// 11.5pt chat surface, not the larger report viewer.
private struct CompanionPanelMarkdownText: View {
    let markdown: String
    private let renderer = PickyReportMarkdownRenderer()

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(renderer.blocks(from: markdown).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: PickyReportMarkdownRenderer.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(font(forHeadingLevel: level))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .paragraph(let text):
            Text(renderer.inlineAttributedString(for: text))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(DS.Colors.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.8)
            )
        }
    }

    private func font(forHeadingLevel level: Int) -> Font {
        switch level {
        case 1: return .system(size: 13.5, weight: .semibold)
        case 2: return .system(size: 12.5, weight: .semibold)
        default: return .system(size: 12, weight: .semibold)
        }
    }
}
