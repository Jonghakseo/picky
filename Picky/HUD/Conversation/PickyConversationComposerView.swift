//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style side-agent card.
//

import SwiftUI

struct PickyConversationComposerView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var draft: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
            TextField(placeholder, text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .focused($isFocused)
                .onSubmit { submitSteer() }
            sendButton
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(composerBackground)
        .background {
            Button(action: submitFollowUp) { EmptyView() }
                .keyboardShortcut(.return, modifiers: .option)
                .opacity(0)
                .frame(width: 0, height: 0)
            Button(action: stopIfPossible) { EmptyView() }
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0)
                .frame(width: 0, height: 0)
                .disabled(!draft.isEmpty)
        }
    }

    // Voice input is intentionally not exposed in the composer.
    // Voice steering uses the existing hover + global PTT shortcut flow
    // (CompanionManager.setVoiceFollowUpSessionIDForCurrentUtterance via
    // selectionStore.hoveredVoiceFollowUpSessionID). The header already shows
    // the active voice target with a mic.fill indicator.

    private var sendButton: some View {
        Button(action: submitSteer) {
            if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("↵")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                    )
            } else {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(sendColor)
                    .frame(width: 18, height: 18)
            }
        }
        .buttonStyle(.plain)
        .help("Send steering message")
    }

    private var composerBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DS.Colors.surface2.opacity(0.55))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }

    var placeholderText: String { placeholder }

    private var placeholder: String {
        switch session.status {
        case .running, .queued, .waiting_for_input:
            return "Steer this agent · ⌥↵ Follow-up · esc Stop"
        case .completed, .blocked, .cancelled:
            return "Send a follow-up… · ⌥↵ Follow-up"
        case .failed:
            return "원인 알려주거나 다른 방법 제안… · ⌥↵ Follow-up"
        }
    }

    private var sendColor: Color {
        switch session.status {
        case .completed, .cancelled:
            return DS.Colors.success
        case .running, .queued, .waiting_for_input, .failed, .blocked:
            return DS.Colors.overlayCursorBlue
        }
    }

    private func submitSteer() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = trimmed
        draft = ""
        Task { try? await viewModel.steer(text: text, sessionID: session.id) }
    }

    private func submitFollowUp() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let text = trimmed
        draft = ""
        Task { try? await viewModel.followUp(text: text, sessionID: session.id) }
    }

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await viewModel.abort(sessionID: session.id) }
    }
}
