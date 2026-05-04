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
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 14) {
                    header

                    if companionManager.mainAgentMessages.isEmpty {
                        emptyState
                    } else {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            ForEach(companionManager.mainAgentMessages) { message in
                                CompanionPanelMessageRow(message: message)
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
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Messages")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text("Latest 100 prompts and replies.")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            Spacer(minLength: 8)

            // Plain text-link reset rather than a chip; the action is destructive-adjacent
            // (clears the visible thread) so it stays understated by default.
            Button(action: resetMainAgentSession) {
                HStack(spacing: 5) {
                    if companionManager.isResettingMainAgentSession {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 10, height: 10)
                    } else {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9.5, weight: .semibold))
                    }
                    Text("New session")
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(companionManager.isResettingMainAgentSession ? DS.Colors.textTertiary : DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .disabled(companionManager.isResettingMainAgentSession)
            .pointerCursor()
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No messages yet")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
            Text("Hold Control+Option or type below. Your prompt and the main agent reply will appear here.")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    /// Composer with no surrounding card. The text field and send glyph sit on the panel
    /// surface directly; only the input itself has a hairline outline. The send button
    /// becomes a tinted glyph rather than a filled disc to match the minimal aesthetic.
    private var directMessageComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField("Message Picky…", text: $draftMessage, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1...3)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                    )
                    .onSubmit { submitDirectMessage() }

                Button(action: submitDirectMessage) {
                    Group {
                        if companionManager.isSendingDirectMessage {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: "paperplane.fill")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .foregroundColor(isSubmitDisabled ? DS.Colors.textTertiary : DS.Colors.accent)
                }
                .buttonStyle(.plain)
                .disabled(isSubmitDisabled)
                .pointerCursor()
            }

            if let error = companionManager.directMessageError {
                Text(error)
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// Transcript-style message row — no bubble, no alignment swap. Both user and assistant
/// turns flow left-aligned with a coloured role label and a timestamp on the right.
/// The accent colour on "You" provides enough visual differentiation that we don't need
/// the prior right-aligned bubble + chrome.
private struct CompanionPanelMessageRow: View {
    let message: PickyMainAgentMessage

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(message.role == .user ? "You" : "Picky")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(message.role == .user ? DS.Colors.accentText : DS.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(message.createdAt, formatter: Self.timeFormatter)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
            }

            // Main-agent replies arrive as Markdown (bold, inline code, bullets, fenced
            // blocks). User prompts are plain text—rendering them through the renderer
            // would silently change formatting if the user ever typed `*` or `_`, so keep
            // user turns as-is and only parse markdown for assistant turns.
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
