//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style side-agent card.
//

import SwiftUI

enum PickyConversationComposerSubmitKind: Equatable {
    case steer
    case followUp
}

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
                .onSubmit { submitDefault() }
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(EventModifiers.option) {
                        submitOptionReturn()
                        return .handled
                    }
                    return .ignored
                }
                .onKeyPress(keys: [.escape], phases: .down) { _ in
                    if draft.isEmpty {
                        stopIfPossible()
                        return .handled
                    }
                    return .ignored
                }
            sendButton
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(composerBackground)
    }

    // Voice input is intentionally not exposed in the composer.
    // Voice steering uses the existing hover + global PTT shortcut flow
    // (CompanionManager.setVoiceFollowUpSessionIDForCurrentUtterance via
    // selectionStore.hoveredVoiceFollowUpSessionID). The header already shows
    // the active voice target with a mic.fill indicator.

    private var sendButton: some View {
        Button(action: submitDefault) {
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
        .disabled(defaultSubmitKind == nil)
        .help(sendHelpText)
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
    var defaultSubmitKind: PickyConversationComposerSubmitKind? {
        switch session.status {
        case .running, .queued, .waiting_for_input, .cancelled:
            return .steer
        case .completed, .blocked:
            return .followUp
        case .failed:
            return nil
        }
    }

    var optionReturnSubmitKind: PickyConversationComposerSubmitKind? {
        switch session.status {
        case .running, .queued, .waiting_for_input, .completed, .blocked:
            return .followUp
        case .cancelled, .failed:
            return nil
        }
    }

    private var placeholder: String {
        switch session.status {
        case .running, .queued, .waiting_for_input:
            return "Steer this agent · ⌥↵ Follow-up · esc Stop"
        case .completed, .blocked:
            return "Send a follow-up…"
        case .cancelled:
            return "Resume this agent with a steer…"
        case .failed:
            return "Open terminal/logs or start a new task"
        }
    }

    private var sendHelpText: String {
        switch defaultSubmitKind {
        case .steer:
            return "Send steering message"
        case .followUp:
            return "Send follow-up message"
        case nil:
            return "This session cannot accept composer input"
        }
    }

    private var sendColor: Color {
        switch defaultSubmitKind {
        case .followUp:
            return DS.Colors.success
        case .steer, nil:
            return DS.Colors.overlayCursorBlue
        }
    }

    private func submitDefault() {
        submit(defaultSubmitKind)
    }

    private func submitOptionReturn() {
        submit(optionReturnSubmitKind)
    }

    private func submit(_ kind: PickyConversationComposerSubmitKind?) {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let kind else { return }
        let text = trimmed
        Task {
            do {
                switch kind {
                case .steer:
                    try await viewModel.steer(text: text, sessionID: session.id)
                case .followUp:
                    try await viewModel.followUp(text: text, sessionID: session.id)
                }
                draft = ""
            } catch {
                // PickySessionListViewModel surfaces command failures through lastError.
            }
        }
    }

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await viewModel.abort(sessionID: session.id) }
    }
}
