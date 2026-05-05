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

enum PickyConversationComposerReturnKeyAction: Equatable {
    case insertNewline
    case submitDefault
    case submitOptionReturn
}

enum PickyConversationComposerUpArrowKeyAction: Equatable {
    case clearQueue
    case navigateAutocomplete
}

struct PickyConversationComposerView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var draft: String = ""
    @State private var selectedSlashCommandIndex: Int = 0
    @State private var isSlashCommandAutocompleteDismissed: Bool = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            slashCommandAutocomplete
            composerRow
        }
        .onAppear { viewModel.ensureSlashCommandsLoaded(sessionID: session.id) }
    }

    private var composerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "text.bubble")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.top, 3)
            composerEditor
            sendButton
                .padding(.top, 1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity)
        .background(composerBackground)
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(placeholder)
                    .font(.system(size: 11.5))
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .font(.system(size: 11.5))
                .foregroundColor(DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($isFocused)
                .frame(height: editorHeight)
                .onChange(of: draft) { _, _ in
                    selectedSlashCommandIndex = 0
                    isSlashCommandAutocompleteDismissed = false
                }
                .onKeyPress(keys: [.return], phases: .down) { keyPress in
                    switch returnKeyAction(for: keyPress.modifiers) {
                    case .insertNewline:
                        return .ignored
                    case .submitDefault:
                        handleReplySubmitKey()
                        return .handled
                    case .submitOptionReturn:
                        submitOptionReturn()
                        return .handled
                    }
                }
                .onKeyPress(keys: [.upArrow], phases: .down) { keyPress in
                    switch upArrowKeyAction(for: keyPress.modifiers) {
                    case .clearQueue:
                        return clearQueuedMessages() ? .handled : .ignored
                    case .navigateAutocomplete:
                        return moveSlashCommandSelection(.up) ? .handled : .ignored
                    }
                }
                .onKeyPress(keys: [.downArrow], phases: .down) { _ in
                    moveSlashCommandSelection(.down) ? .handled : .ignored
                }
                .onKeyPress(keys: [.tab], phases: .down) { _ in
                    acceptSelectedSlashCommand() ? .handled : .ignored
                }
                .onKeyPress(keys: [.escape], phases: .down) { _ in
                    if dismissSlashCommandAutocomplete() {
                        return .handled
                    }
                    if draft.isEmpty {
                        stopIfPossible()
                        return .handled
                    }
                    return .ignored
                }
        }
    }

    // MARK: - Slash command autocomplete

    @ViewBuilder
    private var slashCommandAutocomplete: some View {
        if slashCommandAutocompleteIsVisible {
            let suggestions = slashCommandSuggestions
            if !suggestions.isEmpty {
                let selectedIndex = selectedSlashCommandClampedIndex(for: suggestions)
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, command in
                        Button {
                            acceptSlashCommand(command)
                        } label: {
                            slashCommandRow(command, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.96))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8)
                        )
                )
            } else if !viewModel.hasLoadedSlashCommands(sessionID: session.id) {
                slashCommandStatus("Loading commands…")
            } else {
                slashCommandStatus("No matching commands")
            }
        }
    }

    private func slashCommandRow(_ command: PickySlashCommand, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("/\(command.name)")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            Text(command.source.displayName)
                .font(.system(size: 8.5, weight: .semibold))
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
            if let description = command.description, !description.isEmpty {
                Text(description)
                    .font(.system(size: 10))
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func slashCommandStatus(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundColor(DS.Colors.textTertiary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(DS.Colors.surface1.opacity(0.90))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8)
                    )
            )
    }

    var slashCommandAutocompleteIsVisible: Bool {
        PickySlashCommandAutocompletePolicy.query(in: draft) != nil && !isSlashCommandAutocompleteDismissed
    }

    var slashCommandSuggestions: [PickySlashCommand] {
        guard PickySlashCommandAutocompletePolicy.query(in: draft) != nil else { return [] }
        return viewModel.slashCommandSuggestions(for: draft, sessionID: session.id)
    }

    private func selectedSlashCommandClampedIndex(for suggestions: [PickySlashCommand]) -> Int {
        PickySlashCommandAutocompletePolicy.clampedSelectionIndex(selectedSlashCommandIndex, suggestionCount: suggestions.count)
    }

    private func moveSlashCommandSelection(_ direction: PickySlashCommandNavigationDirection) -> Bool {
        let suggestions = slashCommandSuggestions
        guard slashCommandAutocompleteIsVisible, !suggestions.isEmpty else { return false }
        selectedSlashCommandIndex = PickySlashCommandAutocompletePolicy.movedSelectionIndex(
            current: selectedSlashCommandIndex,
            suggestionCount: suggestions.count,
            direction: direction
        )
        return true
    }

    @discardableResult
    private func acceptSelectedSlashCommand() -> Bool {
        let suggestions = slashCommandSuggestions
        guard slashCommandAutocompleteIsVisible, !suggestions.isEmpty else { return false }
        acceptSlashCommand(suggestions[selectedSlashCommandClampedIndex(for: suggestions)])
        return true
    }

    private func acceptSlashCommand(_ command: PickySlashCommand) {
        draft = PickySlashCommandAutocompletePolicy.completionText(for: command)
        selectedSlashCommandIndex = 0
        isSlashCommandAutocompleteDismissed = true
    }

    @discardableResult
    private func dismissSlashCommandAutocomplete() -> Bool {
        guard slashCommandAutocompleteIsVisible else { return false }
        isSlashCommandAutocompleteDismissed = true
        return true
    }

    private func handleReplySubmitKey() {
        if acceptSelectedSlashCommand() { return }
        submitDefault()
    }

    // Voice input is intentionally not exposed in the composer.
    // Voice steering uses the existing hover + global PTT shortcut flow
    // (CompanionManager.setVoiceFollowUpSessionIDForCurrentUtterance via
    // selectionStore.hoveredVoiceFollowUpSessionID). The header already shows
    // the active voice target with a mic.fill indicator.

    private var editorHeight: CGFloat {
        Self.editorHeight(for: draft)
    }

    static func editorHeight(for text: String) -> CGFloat {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return min(48, max(20, CGFloat(lineCount) * 16 + 4))
    }

    private var sendButton: some View {
        Button(action: submitDefault) {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(isSendDisabled ? DS.Colors.textTertiary : sendColor)
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.plain)
        .disabled(isSendDisabled)
        .help(sendHelpText)
    }

    private var isSendDisabled: Bool {
        defaultSubmitKind == nil || !hasDraftText
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    func returnKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerReturnKeyAction {
        Self.returnKeyAction(for: modifiers)
    }

    static func returnKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerReturnKeyAction {
        if modifiers.contains(.shift) { return .insertNewline }
        if modifiers.contains(.option) { return .submitOptionReturn }
        return .submitDefault
    }

    func upArrowKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerUpArrowKeyAction {
        Self.upArrowKeyAction(for: modifiers)
    }

    static func upArrowKeyAction(for modifiers: EventModifiers) -> PickyConversationComposerUpArrowKeyAction {
        modifiers.contains(.option) ? .clearQueue : .navigateAutocomplete
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
        guard defaultSubmitKind != nil else {
            return "This session cannot accept composer input"
        }
        guard hasDraftText else {
            return "Enter a message to send"
        }

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

    @discardableResult
    private func clearQueuedMessages() -> Bool {
        guard !session.queuedSteers.isEmpty || !session.queuedFollowUps.isEmpty else { return false }
        Task { try? await viewModel.clearQueue(sessionID: session.id, kind: .all) }
        return true
    }

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await viewModel.abort(sessionID: session.id) }
    }
}
