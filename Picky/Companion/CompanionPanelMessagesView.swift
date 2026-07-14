//
//  CompanionPanelMessagesView.swift
//  Picky
//
//  Recent user/Picky messages for the menu bar panel.
//

import AppKit
import SwiftUI

struct CompanionPanelMessagesView: View {
    @ObservedObject var companionManager: CompanionManager
    @State private var draftMessage = ""
    /// Brief checkmark on the "Copy resume command" button after a successful
    /// copy, so the user gets visible feedback without needing a toast.
    @State private var didCopyResumeCommand = false

    /// Stable id for the invisible spacer pinned to the end of the scroll content.
    /// Scrolling to a fixed anchor keeps "start at bottom / stick to bottom" working
    /// even when the list is empty or the last message id changes mid-render.
    private let bottomAnchorID = "messages.bottomAnchor"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header sits outside the ScrollView so the title, "새 세션", and the
            // Pi terminal/resume command row stay pinned while only the message
            // list scrolls.
            header

            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        if companionManager.mainAgentMessages.isEmpty {
                            emptyState
                        } else {
                            LazyVStack(alignment: .leading, spacing: 14) {
                                ForEach(companionManager.mainAgentMessages) { message in
                                    CompanionPanelMessageRow(message: message)
                                }
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    // Initial render — newest message is at the bottom of the list,
                    // so jump there without animation so the tab opens already scrolled
                    // down rather than flashing the oldest message first.
                    scrollToBottom(proxy: proxy, animated: false)
                }
                .onChange(of: companionManager.mainAgentMessages.count) { _ in
                    scrollToBottom(proxy: proxy, animated: true)
                }
                .onChange(of: companionManager.mainAgentMessages.last?.id) { _ in
                    // Catches in-place edits to the trailing message (e.g. streaming
                    // updates that keep the count the same but mutate the last entry).
                    scrollToBottom(proxy: proxy, animated: true)
                }
            }

            directMessageComposer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        // Defer one runloop so LazyVStack has the new row laid out before we
        // ask the proxy to scroll, otherwise the anchor can resolve to the
        // previous content size and leave a gap above the composer.
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("messages.title")
                        .pickyFont(size: 12, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("messages.subtitle")
                        .pickyFont(size: 10.5, weight: .medium)
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
                                .pickyFont(size: 9.5, weight: .semibold)
                        }
                        Text("messages.newSession")
                            .pickyFont(size: 11, weight: .medium)
                    }
                    .foregroundColor(companionManager.isResettingMainAgentSession ? DS.Colors.textTertiary : DS.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(companionManager.isResettingMainAgentSession)
                .pointerCursor()
            }

            if companionManager.mainAgentSessionInfo.canOpenInPi {
                mainAgentEscapeRow
            }
        }
    }

    /// Two understated text-link buttons that let the user pop the always-on
    /// Picky main agent's Pi session into the in-app terminal overlay or copy
    /// the equivalent `pi --session ...` resume command. Hidden when the
    /// daemon hasn't reported a session file yet (e.g. before the first turn,
    /// after a `/new`, or while a model/runtime switch is in flight).
    private var mainAgentEscapeRow: some View {
        HStack(spacing: 12) {
            Button(action: openMainAgentInPi) {
                Label("messages.mainAgent.openInPi", systemImage: "terminal")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Button(action: copyMainAgentResumeCommand) {
                Label(copyButtonLabelKey, systemImage: copyButtonIconName)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
            }
            .buttonStyle(.plain)
            .pointerCursor()

            Spacer(minLength: 0)
        }
    }

    private var copyButtonIconName: String {
        didCopyResumeCommand ? "checkmark" : "doc.on.doc"
    }

    private var copyButtonLabelKey: LocalizedStringKey {
        didCopyResumeCommand ? "messages.mainAgent.copyResume.copied" : "messages.mainAgent.copyResume"
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("messages.empty.title")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
            Text("messages.empty.body")
                .pickyFont(size: 11, weight: .medium)
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
                    .pickyFont(size: 11.5, weight: .medium)
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
                                .pickyFont(size: 12, weight: .semibold)
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
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func openMainAgentInPi() {
        let info = companionManager.mainAgentSessionInfo
        guard let path = info.sessionFilePath, !path.isEmpty else { return }
        do {
            try PickyTerminalOverlayPresenter.shared.openTerminal(
                sessionID: "picky-main",
                title: "Picky",
                sessionFilePath: path,
                cwd: info.cwd,
                onClose: {}
            )
        } catch {
            NSSound.beep()
            print("⚠️ Picky main agent terminal open failed: \(error.localizedDescription)")
        }
    }

    private func copyMainAgentResumeCommand() {
        let info = companionManager.mainAgentSessionInfo
        guard let path = info.sessionFilePath, !path.isEmpty else { return }
        let command = PickyPiTerminalCommand.makeCliResumeCommand(sessionFilePath: path, cwd: info.cwd)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        didCopyResumeCommand = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            didCopyResumeCommand = false
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
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(message.role == .user ? DS.Colors.accentText : DS.Colors.textSecondary)
                Spacer(minLength: 8)
                Text(message.createdAt, formatter: Self.timeFormatter)
                    .pickyFont(size: 9.5, weight: .medium)
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
                    .pickyFont(size: 11.5, weight: .medium)
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
        .environment(\.openURL, OpenURLAction { url in
            // Same `picky://` interception as the HUD bubble renderer: a
            // deep link in the main-agent reply opens the right companion
            // panel screen instead of falling through to the browser.
            PickyDeepLinkDispatcher.shared.handle(url) ? .handled : .systemAction
        })
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
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundStyle(DS.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        case .bullet(let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                    .pickyFont(size: 11.5, weight: .semibold)
                    .foregroundStyle(DS.Colors.textSecondary)
                Text(renderer.inlineAttributedString(for: text))
                    .pickyFont(size: 11.5, weight: .medium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .table(let headers, let rows):
            VStack(alignment: .leading, spacing: 4) {
                Text(headers.joined(separator: " · "))
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Text(row.joined(separator: " · "))
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundStyle(DS.Colors.textPrimary.opacity(0.92))
                }
            }
            .padding(8)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        case .codeBlock(let text):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(text.isEmpty ? " " : text)
                    .pickyFont(size: 10.5, weight: .regular, design: .monospaced)
                    .foregroundStyle(DS.Colors.codeText)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
