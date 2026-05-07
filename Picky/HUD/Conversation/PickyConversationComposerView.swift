//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style side-agent card.
//

import AppKit
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
    @Binding private var droppedFilePaths: [String]
    let isFileDropTargeted: Bool
    @State private var draft: String = ""
    @State private var selectedSlashCommandIndex: Int = 0
    @State private var isSlashCommandAutocompleteDismissed: Bool = false
    @State private var keyDownMonitor: Any?
    @FocusState private var isFocused: Bool

    init(
        session: PickySessionListViewModel.SessionCard,
        viewModel: PickySessionListViewModel,
        droppedFilePaths: Binding<[String]> = .constant([]),
        isFileDropTargeted: Bool = false
    ) {
        self.session = session
        self.viewModel = viewModel
        self._droppedFilePaths = droppedFilePaths
        self.isFileDropTargeted = isFileDropTargeted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            slashCommandAutocomplete
            composerRow
        }
        .onAppear {
            viewModel.ensureSlashCommandsLoaded(sessionID: session.id)
            installKeyDownMonitorIfNeeded()
        }
        .onDisappear { removeKeyDownMonitor() }
        .onChange(of: droppedFilePaths) { _, paths in
            guard !paths.isEmpty else { return }
            if !isComposerInputDisabled {
                appendDroppedFilePaths(paths)
            }
            droppedFilePaths = []
        }
    }

    private var composerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            leadingAccessory
            composerEditor
            sendButton
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(composerBackground)
    }

    @ViewBuilder
    private var leadingAccessory: some View {
        if isFileDropTargeted {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 18, height: 18)
                .help("Drop files or screenshots anywhere to insert paths")
                .accessibilityLabel("File drop target")
        } else {
            Button {
                toggleNotifyOnCompletion()
            } label: {
                Image(systemName: notifyOnCompletionIconName)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(notifyOnCompletionColor)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help(notifyOnCompletionHelpText)
            .accessibilityLabel("Notify on completion")
            .accessibilityValue(session.notifyMainOnCompletion == true ? "On" : "Off")
        }
    }

    var notifyOnCompletionIconName: String {
        session.notifyMainOnCompletion == true ? "bell.fill" : "bell.slash"
    }

    var notifyOnCompletionHelpText: String {
        session.notifyMainOnCompletion == true ? "Notify main agent on completion" : "Do not notify main agent on completion"
    }

    private var notifyOnCompletionColor: Color {
        session.notifyMainOnCompletion == true ? DS.Colors.accentText : DS.Colors.textTertiary
    }

    private func toggleNotifyOnCompletion() {
        let enabled = !(session.notifyMainOnCompletion == true)
        Task { try? await viewModel.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
    }

    private var composerEditor: some View {
        ZStack(alignment: .topLeading) {
            if draft.isEmpty {
                Text(placeholder)
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.leading, 5)
                    .padding(.top, 4)
                    .allowsHitTesting(false)
            }
            TextEditor(text: $draft)
                .font(PickyHUDTypography.bodyCompact)
                .foregroundColor(isComposerInputDisabled ? DS.Colors.textTertiary : DS.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .focused($isFocused)
                .disabled(isComposerInputDisabled)
                .frame(height: editorHeight)
                .offset(y: 4)
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
                .onKeyPress(keys: [.tab], phases: .down) { keyPress in
                    if keyPress.modifiers.contains(.shift) {
                        cycleThinkingLevel()
                        return .handled
                    }
                    return acceptSelectedSlashCommand() ? .handled : .ignored
                }
                .onKeyPress(keys: ["p"], phases: .down) { keyPress in
                    guard keyPress.modifiers.contains(.control) else { return .ignored }
                    cycleModel(direction: keyPress.modifiers.contains(.shift) ? .backward : .forward)
                    return .handled
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
                .font(PickyHUDTypography.labelMonospacedSemibold)
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            Text(command.source.displayName)
                .font(PickyHUDTypography.minimumSemibold)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
            if let description = command.description, !description.isEmpty {
                Text(description)
                    .font(PickyHUDTypography.status)
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
            .font(PickyHUDTypography.status)
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
        return min(72, max(32, CGFloat(lineCount) * 18 + 12))
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

    var isComposerInputDisabled: Bool {
        session.isCompacting
    }

    private var isSendDisabled: Bool {
        isComposerInputDisabled || defaultSubmitKind == nil || !hasDraftText
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(composerBackgroundFill)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(isFileDropTargeted && !isComposerInputDisabled ? DS.Colors.accentText.opacity(0.85) : DS.Colors.borderSubtle, lineWidth: isFileDropTargeted && !isComposerInputDisabled ? 1 : 0.5)
            )
    }

    private var composerBackgroundFill: Color {
        if isComposerInputDisabled { return DS.Colors.surface2.opacity(0.38) }
        return isFileDropTargeted ? DS.Colors.accentSubtle.opacity(0.28) : DS.Colors.surface2.opacity(0.55)
    }

    static func draftText(afterAppendingDroppedFilePaths paths: [String], to draft: String) -> String {
        let normalizedPaths = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !normalizedPaths.isEmpty else { return draft }

        let droppedText = normalizedPaths.joined(separator: "\n")
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return droppedText
        }
        if draft.hasSuffix("\n") {
            return draft + droppedText
        }
        return "\(draft)\n\(droppedText)"
    }

    private func appendDroppedFilePaths(_ paths: [String]) {
        draft = Self.draftText(afterAppendingDroppedFilePaths: paths, to: draft)
        if !paths.isEmpty { isFocused = true }
    }

    var placeholderText: String { placeholder }
    var defaultSubmitKind: PickyConversationComposerSubmitKind? {
        switch session.status {
        case .running, .queued, .waiting_for_input, .cancelled, .failed:
            return .steer
        case .completed, .blocked:
            return .followUp
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
        if session.isCompacting { return "Compacting…" }
        if isFileDropTargeted { return "Drop files or screenshots anywhere to insert paths" }
        switch session.status {
        case .running, .queued, .waiting_for_input:
            return "Steer this agent · ⌥↵ Follow-up · esc Stop"
        case .completed, .blocked:
            return "Send a follow-up…"
        case .cancelled:
            return "Resume this agent with a steer…"
        case .failed:
            return "Send a recovery steer or open terminal"
        }
    }

    var sendHelpText: String {
        if isComposerInputDisabled {
            return "Session is compacting"
        }
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
        guard !isComposerInputDisabled else { return }
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
        let queued = (session.queuedSteers + session.queuedFollowUps).sorted { $0.enqueuedAt < $1.enqueuedAt }
        guard !queued.isEmpty else { return false }
        // Move the queued texts back into the composer so option+up acts as 'pop the queue back
        // into the editor for revision' instead of silently throwing away unsent input. Existing
        // composer text is preserved by appending the queued payload after it.
        let merged = queued.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n")
        if !merged.isEmpty {
            draft = draft.isEmpty ? merged : "\(draft)\n\n\(merged)"
            isFocused = true
        }
        Task { try? await viewModel.clearQueue(sessionID: session.id, kind: .all) }
        return true
    }

    private func cycleThinkingLevel() {
        Task { try? await viewModel.cycleThinkingLevel(sessionID: session.id) }
    }

    private func cycleModel(direction: PickyModelCycleDirection) {
        Task { try? await viewModel.cycleModel(sessionID: session.id, direction: direction) }
    }

    private func installKeyDownMonitorIfNeeded() {
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isFocused, !isComposerInputDisabled else { return event }
            if event.keyCode == Self.tabKeyCode, event.modifierFlags.contains(.shift) {
                cycleThinkingLevel()
                return nil
            }
            if event.keyCode == Self.pKeyCode, event.modifierFlags.contains(.control) {
                cycleModel(direction: event.modifierFlags.contains(.shift) ? .backward : .forward)
                return nil
            }
            return event
        }
    }

    private func removeKeyDownMonitor() {
        guard let keyDownMonitor else { return }
        NSEvent.removeMonitor(keyDownMonitor)
        self.keyDownMonitor = nil
    }

    private static let tabKeyCode: UInt16 = 48
    private static let pKeyCode: UInt16 = 35

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await viewModel.abort(sessionID: session.id) }
    }
}
