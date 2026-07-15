//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style Pickle card.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    case recallPreviousMessage
}

/// Mirrors agentd's `parseUserBashInput` (session-supervisor.ts): `!` invokes
/// bash with the command's output added to Pi's context on the next turn,
/// `!!` invokes bash with the output excluded. The composer uses this state
/// to recolor its border, swap the send icon, and surface a corner badge so
/// the user can see at a glance that pressing return will execute, not chat.
enum PickyComposerBashMode: Equatable {
    case none
    case visible
    case `private`
}

struct PickyConversationComposerView: View {
    let session: PickySessionListViewModel.SessionCard
    @ObservedObject var viewModel: PickySessionListViewModel
    @Binding private var droppedFilePaths: [String]
    let isFileDropTargeted: Bool
    let focusRequestID: Int
    let isExtendedTerminalOpen: Bool
    let isCommandShortcutHintVisible: Bool
    var onToggleExtendedTerminal: () -> Void
    var onRequestRewind: () -> Void
    @State private var draft: String = ""
    @State private var attachments: [PickyComposerAttachment] = []
    @State private var attachmentContentWidth: CGFloat = 0
    @State private var attachmentViewportWidth: CGFloat = 0
    @State private var selectedSlashCommandIndex: Int = 0
    @State private var isSlashCommandAutocompleteDismissed: Bool = false
    @State private var acceptedSlashCommandDraft: String?
    @State private var composerCursorLocation: Int?
    @State private var composerSelectionOverride: NSRange?
    @State private var selectedFileMentionIndex: Int = 0
    @State private var isFileMentionAutocompleteDismissed: Bool = false
    @State private var fileMentionSuggestions: [PickyFileMentionAutocompletePolicy.Suggestion] = []
    @State private var fileMentionSearchDraft: String?
    @State private var appliedComposerDraftRequestID: String?
    @State private var keyDownMonitor: Any?
    @State private var measuredEditorContentHeight: CGFloat = Self.minimumEditorHeight
    @State private var isFocused: Bool = false

    init(
        session: PickySessionListViewModel.SessionCard,
        viewModel: PickySessionListViewModel,
        droppedFilePaths: Binding<[String]> = .constant([]),
        isFileDropTargeted: Bool = false,
        focusRequestID: Int = 0,
        isExtendedTerminalOpen: Bool = false,
        isCommandShortcutHintVisible: Bool = false,
        onToggleExtendedTerminal: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { }
    ) {
        self.session = session
        self.viewModel = viewModel
        self._droppedFilePaths = droppedFilePaths
        self.isFileDropTargeted = isFileDropTargeted
        self.focusRequestID = focusRequestID
        self.isExtendedTerminalOpen = isExtendedTerminalOpen
        self.isCommandShortcutHintVisible = isCommandShortcutHintVisible
        self.onToggleExtendedTerminal = onToggleExtendedTerminal
        self.onRequestRewind = onRequestRewind
    }

    var body: some View {
        let _ = PickyPerf.event("composer_body")
        VStack(alignment: .leading, spacing: 4) {
            slashCommandAutocomplete
            fileMentionAutocomplete
            screenContextAttachmentChip
            attachmentChipsRow
            composerRow
        }
        .onAppear {
            viewModel.ensureSlashCommandsLoaded(sessionID: session.id)
            installKeyDownMonitorIfNeeded()
            restorePersistedDraftIfNeeded()
            restorePersistedAttachmentsIfNeeded()
            applyComposerDraftRequestIfNeeded(viewModel.composerDraftRequest(for: session.id))
        }
        .onDisappear {
            viewModel.updateComposerDraft(draft, sessionID: session.id)
            persistAttachments()
            removeKeyDownMonitor()
        }
        .onChange(of: viewModel.composerDraftRequest(for: session.id)) { _, request in
            applyComposerDraftRequestIfNeeded(request)
        }
        .onChange(of: focusRequestID) { _, _ in
            focusComposerIfPossible()
        }
        .onChange(of: droppedFilePaths) { _, paths in
            guard !paths.isEmpty else { return }
            if !isComposerInputDisabled {
                appendDroppedFilePaths(paths)
            }
            droppedFilePaths = []
        }
        .onChange(of: session.id) { _, _ in
            attachments = viewModel.persistedComposerAttachmentPaths(for: session.id)
                .map { PickyComposerAttachment(path: $0) }
        }
        .onChange(of: attachments) { _, _ in
            persistAttachments()
        }
        // Safety-net polling: when the autocomplete is open and commands have not loaded yet,
        // periodically re-request so we recover even if the first response was dropped (epoch
        // mismatch after a concurrent invalidation, transport loss, etc.). The .task body exits
        // immediately once commands are loaded or the autocomplete is dismissed, and re-spawns
        // when those conditions change because they are part of the task id.
        .task(id: SlashCommandPollingKey(
            sessionID: session.id,
            isVisible: slashCommandAutocompleteIsVisible,
            isLoaded: viewModel.hasLoadedSlashCommands(sessionID: session.id)
        )) {
            guard slashCommandAutocompleteIsVisible,
                  !viewModel.hasLoadedSlashCommands(sessionID: session.id) else { return }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: Self.slashCommandLoadingRetryIntervalNanoseconds)
                } catch {
                    return
                }
                if Task.isCancelled { return }
                if viewModel.hasLoadedSlashCommands(sessionID: session.id) { return }
                if !slashCommandAutocompleteIsVisible { return }
                viewModel.refreshSlashCommandsIfStillLoading(sessionID: session.id)
            }
        }
        .task(id: FileMentionSearchKey(
            draft: draft,
            cwd: session.cwd,
            isVisible: fileMentionAutocompleteIsVisible
        )) {
            let searchDraft = draft
            guard fileMentionAutocompleteIsVisible,
                  PickyFileMentionAutocompletePolicy.query(in: searchDraft) != nil else {
                fileMentionSuggestions = []
                fileMentionSearchDraft = nil
                return
            }
            let suggestions = await PickyFileMentionSearchService.suggestions(for: searchDraft, cwd: session.cwd)
            guard !Task.isCancelled else { return }
            fileMentionSuggestions = suggestions
            fileMentionSearchDraft = searchDraft
        }
    }

    private struct SlashCommandPollingKey: Equatable {
        let sessionID: String
        let isVisible: Bool
        let isLoaded: Bool
    }

    private struct FileMentionSearchKey: Equatable {
        let draft: String
        let cwd: String?
        let isVisible: Bool
    }

    private var composerRow: some View {
        HStack(alignment: .center, spacing: 8) {
            leadingActions
                .zIndex(2)
            composerEditor
                .zIndex(0)
            trailingActions
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(composerBackground)
    }

    @ViewBuilder
    private var leadingActions: some View {
        if effectiveBashMode != .none {
            bashModeBadge
        } else {
            VStack(spacing: 4) {
                notifyOrDropButton
                terminalButton
            }
            .frame(width: 24)
        }
    }

    /// Replaces the notify/terminal column when the draft is in bash-execution
    /// mode. The notify/terminal shortcuts (⌘N / ⌘E) still work from the
    /// keyboard — they're just out of sight while the user is composing a
    /// shell command, which is itself a short-lived state.
    private var bashModeBadge: some View {
        VStack(spacing: 2) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 12, weight: .bold)
                .foregroundColor(bashAccentColor)
            Text(effectiveBashMode == .private ? "PRIVATE" : "BASH")
                .pickyFont(size: 7, weight: .heavy, design: .monospaced)
                .foregroundColor(bashAccentColor)
                .fixedSize()
        }
        .frame(minWidth: 24)
        .help(effectiveBashMode == .private
            ? "Bash execution · output hidden from Pi context"
            : "Bash execution · output added to Pi context")
        .accessibilityLabel(effectiveBashMode == .private ? "Bash private mode" : "Bash mode")
    }

    @ViewBuilder
    private var notifyOrDropButton: some View {
        if isFileDropTargeted {
            Image(systemName: "doc.badge.plus")
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.accentText)
                .frame(width: 22, height: 22)
                .help("Drop files or screenshots anywhere to insert paths")
                .accessibilityLabel("File drop target")
        } else {
            Button {
                toggleNotifyOnCompletion()
            } label: {
                Image(systemName: notifyOnCompletionIconName)
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(notifyOnCompletionColor)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .overlay(alignment: .topTrailing) {
                shortcutBadge("N")
                    .fixedSize()
                    .offset(x: 9, y: -7)
                    .opacity(isCommandShortcutHintVisible ? 1 : 0)
                    .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                    .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                    .allowsHitTesting(false)
            }
            .help(notifyOnCompletionHelpText)
            .accessibilityLabel("Notify on completion")
            .accessibilityValue(session.notifyMainOnCompletion == true ? "On" : "Off")
        }
    }

    private var terminalButton: some View {
        Button(action: onToggleExtendedTerminal) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(isExtendedTerminalOpen ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(terminalButtonBackground)
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .overlay(alignment: .topTrailing) {
            shortcutBadge("E")
                .fixedSize()
                .offset(x: 9, y: -7)
                .opacity(isCommandShortcutHintVisible ? 1 : 0)
                .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                .allowsHitTesting(false)
        }
        .help("Extended terminal (⌘E)")
        .accessibilityLabel("Extended terminal")
        .accessibilityValue(isExtendedTerminalOpen ? "Open" : "Closed")
    }

    private func shortcutBadge(_ letter: String) -> some View {
        HStack(spacing: 1.5) {
            Image(systemName: "command")
                .pickyFont(size: 6.5, weight: .bold)
            Text(letter)
                .pickyFont(size: 7.5, weight: .bold, design: .rounded)
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(Capsule(style: .continuous).fill(.ultraThinMaterial))
        .overlay(Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.70)))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }

    private var terminalButtonBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(isExtendedTerminalOpen ? DS.Colors.accentSubtle.opacity(0.24) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(isExtendedTerminalOpen ? DS.Colors.accentText.opacity(0.28) : Color.clear, lineWidth: 0.5)
            )
    }

    var notifyOnCompletionIconName: String {
        session.notifyMainOnCompletion == true ? "bell.fill" : "bell.slash"
    }

    var notifyOnCompletionHelpText: String {
        session.notifyMainOnCompletion == true ? "Notify Picky on completion (⌘N)" : "Do not notify Picky on completion (⌘N)"
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
                    .padding(.top, Self.editorTextInsetHeight)
                    .allowsHitTesting(false)
            }
            PickyIMETextView(
                text: $draft,
                isFocused: $isFocused,
                isEditable: !isComposerInputDisabled,
                font: composerNSFont,
                textColor: isComposerInputDisabled ? .secondaryLabelColor : .labelColor,
                textContainerInsetHeight: Self.editorTextInsetHeight,
                selectionOverride: $composerSelectionOverride,
                onSelectionChange: { composerCursorLocation = $0.location },
                onMeasuredContentHeight: { measuredEditorContentHeight = $0 },
                onReturn: handleComposerReturnKey,
                onUpArrow: handleComposerUpArrowKey,
                onDownArrow: { moveAutocompleteSelection(.down) },
                onTab: handleComposerTabKey,
                onEscape: handleComposerEscapeKey,
                onControlP: { shiftPressed in cycleModel(direction: shiftPressed ? .backward : .forward) }
            )
            .frame(height: editorHeight)
            .onChange(of: draft) { _, newValue in
                selectedSlashCommandIndex = 0
                let shouldResetSlashCommandDismissal = Self.shouldResetSlashCommandDismissal(
                    newDraft: newValue,
                    acceptedDraft: acceptedSlashCommandDraft
                )
                acceptedSlashCommandDraft = nil
                if shouldResetSlashCommandDismissal {
                    isSlashCommandAutocompleteDismissed = false
                }
                selectedFileMentionIndex = 0
                isFileMentionAutocompleteDismissed = false
                viewModel.updateComposerDraft(newValue, sessionID: session.id)
            }
        }
    }

    @ViewBuilder
    private var screenContextAttachmentChip: some View {
        if isScreenContextArmed {
            HStack(spacing: 6) {
                Image(systemName: "camera.viewfinder")
                    .pickyFont(size: 10, weight: .semibold)
                Text("hud.composer.steerTarget")
                    .font(PickyHUDTypography.status)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button {
                    viewModel.clearScreenContextTarget(sessionID: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .pickyFont(size: 8.5, weight: .bold)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help("Cancel screen context")
            }
            .foregroundColor(DS.Colors.accentText)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Capsule().fill(DS.Colors.accentSubtle.opacity(0.34)))
            .overlay(Capsule().stroke(DS.Colors.accentText.opacity(0.28), lineWidth: 0.7))
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var isScreenContextArmed: Bool {
        viewModel.screenContextTargetSessionID == session.id
    }

    // MARK: - Slash command autocomplete

    @ViewBuilder
    private var slashCommandAutocomplete: some View {
        if slashCommandAutocompleteIsVisible {
            let suggestions = slashCommandSuggestions
            if !suggestions.isEmpty {
                let selectedIndex = selectedSlashCommandClampedIndex(for: suggestions)
                let visibleRange = PickySlashCommandAutocompletePolicy.visibleRange(
                    selectedIndex: selectedIndex,
                    suggestionCount: suggestions.count,
                    maxVisible: Self.maxVisibleAutocompleteSuggestions
                )
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions[visibleRange].enumerated()), id: \.element.id) { offset, command in
                        let index = visibleRange.lowerBound + offset
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
            .background(autocompletePanelBackground(opacity: 0.90, strokeOpacity: 0.45))
    }

    // MARK: - File mention autocomplete

    @ViewBuilder
    private var fileMentionAutocomplete: some View {
        if fileMentionAutocompleteIsVisible {
            let suggestions = fileMentionSuggestions
            if !suggestions.isEmpty {
                let selectedIndex = selectedFileMentionClampedIndex(for: suggestions)
                let visibleRange = PickySlashCommandAutocompletePolicy.visibleRange(
                    selectedIndex: selectedIndex,
                    suggestionCount: suggestions.count,
                    maxVisible: Self.maxVisibleAutocompleteSuggestions
                )
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(suggestions[visibleRange].enumerated()), id: \.element.displayPath) { offset, suggestion in
                        let index = visibleRange.lowerBound + offset
                        Button {
                            acceptFileMention(suggestion)
                        } label: {
                            fileMentionRow(suggestion, isSelected: index == selectedIndex)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(4)
                .background(autocompletePanelBackground(opacity: 0.96, strokeOpacity: 0.55))
            } else {
                slashCommandStatus(fileMentionStatusText)
            }
        }
    }

    private func fileMentionRow(_ suggestion: PickyFileMentionAutocompletePolicy.Suggestion, isSelected: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: suggestion.isDirectory ? "folder.fill" : "doc.text")
                .pickyFont(size: 10, weight: .semibold)
                .foregroundColor(suggestion.isDirectory ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 14)
            Text(suggestion.label)
                .font(PickyHUDTypography.labelMonospacedSemibold)
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            Text(suggestion.displayPath)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
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

    private var fileMentionStatusText: String {
        let cwd = session.cwd?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if cwd.isEmpty { return "No working directory for file mentions" }
        if !PickyFileMentionSearchService.isAvailable { return "File search requires fd (not installed)" }
        return "No matching files"
    }

    private func autocompletePanelBackground(opacity: Double, strokeOpacity: Double) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(DS.Colors.surface1.opacity(opacity))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(strokeOpacity), lineWidth: 0.8)
            )
    }

    var slashCommandAutocompleteIsVisible: Bool {
        !isComposerInputDisabled
            && PickySlashCommandAutocompletePolicy.query(in: draft, cursorLocation: composerCursorLocation) != nil
            && !isSlashCommandAutocompleteDismissed
    }

    var slashCommandSuggestions: [PickySlashCommand] {
        guard PickySlashCommandAutocompletePolicy.query(in: draft, cursorLocation: composerCursorLocation) != nil else { return [] }
        return viewModel.slashCommandSuggestions(
            for: draft,
            cursorLocation: composerCursorLocation,
            sessionID: session.id
        )
    }

    var fileMentionAutocompleteIsVisible: Bool {
        !slashCommandAutocompleteIsVisible
            && !isComposerInputDisabled
            && PickyFileMentionAutocompletePolicy.query(in: draft) != nil
            && !isFileMentionAutocompleteDismissed
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
        let completion = PickySlashCommandAutocompletePolicy.completedText(
            in: draft,
            cursorLocation: composerCursorLocation,
            command: command
        )
        acceptedSlashCommandDraft = completion.text
        draft = completion.text
        composerSelectionOverride = NSRange(location: completion.cursorLocation, length: 0)
        selectedSlashCommandIndex = 0
        isSlashCommandAutocompleteDismissed = true
    }

    private func selectedFileMentionClampedIndex(for suggestions: [PickyFileMentionAutocompletePolicy.Suggestion]) -> Int {
        PickySlashCommandAutocompletePolicy.clampedSelectionIndex(selectedFileMentionIndex, suggestionCount: suggestions.count)
    }

    private func moveFileMentionSelection(_ direction: PickySlashCommandNavigationDirection) -> Bool {
        let suggestions = fileMentionSuggestions
        guard fileMentionAutocompleteIsVisible, !suggestions.isEmpty else { return false }
        selectedFileMentionIndex = PickySlashCommandAutocompletePolicy.movedSelectionIndex(
            current: selectedFileMentionIndex,
            suggestionCount: suggestions.count,
            direction: direction
        )
        return true
    }

    private func moveAutocompleteSelection(_ direction: PickySlashCommandNavigationDirection) -> Bool {
        if moveSlashCommandSelection(direction) { return true }
        return moveFileMentionSelection(direction)
    }

    @discardableResult
    private func acceptSelectedFileMention() -> Bool {
        let suggestions = fileMentionSuggestions
        switch PickyFileMentionAutocompletePolicy.acceptDecision(
            isVisible: fileMentionAutocompleteIsVisible,
            searchDraft: fileMentionSearchDraft,
            draft: draft,
            hasSuggestions: !suggestions.isEmpty
        ) {
        case .consume:
            return true
        case .accept:
            acceptFileMention(suggestions[selectedFileMentionClampedIndex(for: suggestions)])
            return true
        case .passthrough:
            return false
        }
    }

    private func acceptFileMention(_ suggestion: PickyFileMentionAutocompletePolicy.Suggestion) {
        draft = PickyFileMentionAutocompletePolicy.completedText(in: draft, with: suggestion)
        selectedFileMentionIndex = 0
        isFileMentionAutocompleteDismissed = !suggestion.isDirectory
        isFocused = true
    }

    private func acceptSelectedAutocomplete() -> Bool {
        if acceptSelectedSlashCommand() { return true }
        return acceptSelectedFileMention()
    }

    @discardableResult
    private func dismissSlashCommandAutocomplete() -> Bool {
        guard slashCommandAutocompleteIsVisible else { return false }
        isSlashCommandAutocompleteDismissed = true
        return true
    }

    @discardableResult
    private func dismissFileMentionAutocomplete() -> Bool {
        guard fileMentionAutocompleteIsVisible else { return false }
        isFileMentionAutocompleteDismissed = true
        return true
    }

    @discardableResult
    private func dismissAutocomplete() -> Bool {
        if dismissSlashCommandAutocomplete() { return true }
        return dismissFileMentionAutocomplete()
    }

    private func handleReplySubmitKey() {
        if acceptSelectedAutocomplete() { return }
        submitDefault()
    }

    private func handleComposerReturnKey(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch Self.returnKeyAction(for: Self.eventModifiers(from: modifiers)) {
        case .insertNewline:
            return false
        case .submitDefault:
            handleReplySubmitKey()
            return true
        case .submitOptionReturn:
            submitOptionReturn()
            return true
        }
    }

    private func handleComposerUpArrowKey(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        switch Self.upArrowKeyAction(for: Self.eventModifiers(from: modifiers)) {
        case .clearQueue:
            return clearQueuedMessages()
        case .navigateAutocomplete:
            return moveAutocompleteSelection(.up)
        case .recallPreviousMessage:
            if moveAutocompleteSelection(.up) { return true }
            return recallPreviousSubmittedMessage()
        }
    }

    private func handleComposerTabKey(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        if modifiers.contains(.shift) {
            cycleThinkingLevel()
            return true
        }
        return acceptSelectedAutocomplete()
    }

    private func handleComposerEscapeKey() -> Bool {
        if dismissAutocomplete() { return true }
        if isScreenContextArmed {
            viewModel.clearScreenContextTarget(sessionID: session.id)
            return true
        }
        if draft.isEmpty {
            stopIfPossible()
            return true
        }
        return false
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers = EventModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    // Voice input is intentionally not exposed in the composer.
    // Voice steering uses the existing hover + global PTT shortcut flow
    // (CompanionManager.setVoiceFollowUpSessionIDForCurrentUtterance via
    // selectionStore.hoveredVoiceFollowUpSessionID). The header already shows
    // the active voice target with a mic.fill indicator.

    private var editorHeight: CGFloat {
        Self.editorHeight(forMeasuredContentHeight: measuredEditorContentHeight)
    }

    private var composerNSFont: NSFont {
        effectiveBashMode != .none
            ? .monospacedSystemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular)
            : .systemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular)
    }

    static func editorHeight(forMeasuredContentHeight contentHeight: CGFloat) -> CGFloat {
        min(maximumEditorHeight, max(minimumEditorHeight, ceil(contentHeight)))
    }

    static func editorHeight(for text: String) -> CGFloat {
        let lineCount = text.split(separator: "\n", omittingEmptySubsequences: false).count
        return editorHeight(forMeasuredContentHeight: CGFloat(lineCount) * estimatedEditorLineHeight + 2 * editorTextInsetHeight)
    }

    private static let minimumEditorHeight: CGFloat = 50
    private static let maximumEditorHeight: CGFloat = 72
    private static let estimatedEditorLineHeight: CGFloat = 18
    private static let editorTextInsetHeight: CGFloat = 2

    private var trailingActions: some View {
        VStack(spacing: 4) {
            sendButton
            if isStopButtonVisible {
                stopButton
            }
        }
        .frame(width: 24)
    }

    private var sendButton: some View {
        Button(action: submitDefault) {
            Image(systemName: sendButtonIconName)
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(isSendDisabled ? DS.Colors.textTertiary : sendColor)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSendDisabled)
        .pointerCursor()
        .help(sendHelpText)
    }

    private var stopButton: some View {
        Button(action: stopIfPossible) {
            Image(systemName: "stop.fill")
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(DS.Colors.destructiveText)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
        .help("Stop this Pickle")
        .accessibilityLabel("Stop Pickle")
    }

    var isStopButtonVisible: Bool {
        switch session.status {
        case .running:
            return true
        case .waiting_for_input:
            // A fresh manual Pickle parks on `waiting_for_input` with no
            // messages yet; there is nothing to stop until the user submits.
            return !session.messages.isEmpty
        default:
            return false
        }
    }

    private var sendButtonIconName: String {
        effectiveBashMode != .none ? "play.fill" : "paperplane.fill"
    }

    var isComposerInputDisabled: Bool {
        // Compaction is a runtime submit barrier, not an editor lock: keep draft
        // typing/editing and persistence alive so in-progress text is not lost.
        false
    }

    private var isComposerSubmissionBlocked: Bool {
        session.isCompacting
    }

    private var isSendDisabled: Bool {
        isComposerSubmissionBlocked || defaultSubmitKind == nil || (!hasDraftText && attachments.isEmpty)
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(composerBackgroundFill)
            .overlay {
                // Priority: drag-hover beats everything because that's the
                // action the user is currently performing. Bash mode beats
                // the running animation so the "this submit will execute,
                // not converse" cue stays unambiguous even on a live session.
                if isFileDropTargeted && !isComposerInputDisabled {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.accentText.opacity(0.85), lineWidth: 1)
                } else if effectiveBashMode != .none {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(bashAccentColor.opacity(0.9), lineWidth: 1)
                } else if session.status == .running {
                    PickyRunningComposerBorder()
                } else {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                }
            }
    }

    private var composerBackgroundFill: Color {
        if isComposerInputDisabled { return DS.Colors.surface2.opacity(0.38) }
        return isFileDropTargeted ? DS.Colors.accentSubtle.opacity(0.28) : DS.Colors.surface2.opacity(0.55)
    }

    /// `.visible`/`.private` is only reported when there are no attachments;
    /// attachments are appended to the message body as plain paths and would
    /// be passed as bash arguments otherwise, which is never what the user
    /// wants. The two states are kept separate from the raw parser so tests
    /// can verify the prefix detection independently from attachment policy.
    var effectiveBashMode: PickyComposerBashMode {
        guard attachments.isEmpty else { return .none }
        return Self.bashMode(in: draft)
    }

    private var bashAccentColor: Color {
        switch effectiveBashMode {
        case .visible: return DS.Colors.successText
        case .private: return DS.Colors.warningText
        case .none: return DS.Colors.borderSubtle
        }
    }

    /// Mirror of `parseUserBashInput` in agentd's session supervisor. Kept in
    /// sync intentionally: if the parser there changes, this needs to change
    /// too, otherwise the composer will lie about the submit action.
    static func bashMode(in text: String) -> PickyComposerBashMode {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("!") else { return .none }
        let isPrivate = trimmed.hasPrefix("!!")
        let body = isPrivate ? trimmed.dropFirst(2) : trimmed.dropFirst(1)
        let command = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return .none }
        return isPrivate ? .private : .visible
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

    static func shouldResetSlashCommandDismissal(newDraft: String, acceptedDraft: String?) -> Bool {
        newDraft != acceptedDraft
    }

    static func submissionText(draft: String, attachmentPaths: [String]) -> String {
        let trimmedDraft = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let merged = draftText(afterAppendingDroppedFilePaths: attachmentPaths, to: trimmedDraft)
        // With attachments present we intentionally do NOT let the message
        // trigger agentd's `!`/`!!` bash shortcut: the appended file paths
        // would be silently glued onto the command line and either run as
        // arguments to whatever bash command the user typed, or break out
        // of the prompt entirely. Prepending a single space defeats the
        // prefix check in `parseUserBashInput` without altering how Pi
        // reads the message body, so the user gets a regular prompt with
        // the attachments intact.
        if !attachmentPaths.isEmpty && merged.hasPrefix("!") {
            return " " + merged
        }
        return merged
    }

    private func appendDroppedFilePaths(_ paths: [String]) {
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        attachments.append(contentsOf: cleaned.map { PickyComposerAttachment(path: $0) })
        isFocused = true
    }

    @ViewBuilder
    private var attachmentChipsRow: some View {
        if !attachments.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(attachments) { attachment in
                        PickyComposerAttachmentChipView(attachment: attachment) {
                            attachments.removeAll { $0.id == attachment.id }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .background(
                    GeometryReader { proxy in
                        Color.clear.preference(
                            key: AttachmentContentWidthKey.self,
                            value: proxy.size.width
                        )
                    }
                )
            }
            .frame(height: 24)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: AttachmentViewportWidthKey.self,
                        value: proxy.size.width
                    )
                }
            )
            .onPreferenceChange(AttachmentContentWidthKey.self) { attachmentContentWidth = $0 }
            .onPreferenceChange(AttachmentViewportWidthKey.self) { attachmentViewportWidth = $0 }
            .mask(attachmentScrollMask)
        }
    }

    /// True when the chip row would clip on the right. Drives a small fade
    /// mask at the trailing edge so users see there are more attachments to
    /// scroll into view; collapses to a no-op mask when everything fits.
    private var attachmentRowHasOverflow: Bool {
        attachmentContentWidth > attachmentViewportWidth + 0.5
    }

    private var attachmentScrollMask: LinearGradient {
        let fadeStart: Double = attachmentRowHasOverflow ? 0.88 : 1.0
        let trailingOpacity: Double = attachmentRowHasOverflow ? 0 : 1
        return LinearGradient(
            gradient: Gradient(stops: [
                .init(color: .black, location: 0.0),
                .init(color: .black, location: fadeStart),
                .init(color: .black.opacity(trailingOpacity), location: 1.0),
            ]),
            startPoint: .leading,
            endPoint: .trailing
        )
    }

    private func restorePersistedDraftIfNeeded() {
        guard draft.isEmpty else { return }
        let persistedDraft = viewModel.persistedComposerDraft(for: session.id)
        guard !persistedDraft.isEmpty else { return }
        draft = persistedDraft
    }

    private func restorePersistedAttachmentsIfNeeded() {
        guard attachments.isEmpty else { return }
        let persistedPaths = viewModel.persistedComposerAttachmentPaths(for: session.id)
        guard !persistedPaths.isEmpty else { return }
        attachments = persistedPaths.map { PickyComposerAttachment(path: $0) }
    }

    private func persistAttachments() {
        viewModel.updateComposerAttachmentPaths(attachments.map(\.path), sessionID: session.id)
    }

    private func applyComposerDraftRequestIfNeeded(_ request: PickyComposerDraftRequest?) {
        guard let request, appliedComposerDraftRequestID != request.id else { return }
        draft = request.text
        viewModel.updateComposerDraft(request.text, sessionID: session.id)
        selectedSlashCommandIndex = 0
        isSlashCommandAutocompleteDismissed = true
        selectedFileMentionIndex = 0
        isFileMentionAutocompleteDismissed = true
        appliedComposerDraftRequestID = request.id
        focusComposerIfPossible()
        viewModel.consumeComposerDraftRequest(sessionID: session.id, requestID: request.id)
    }

    private func focusComposerIfPossible() {
        guard !isComposerInputDisabled else { return }
        isFocused = true
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
        if modifiers.contains(.option) { return .clearQueue }
        if modifiers.isEmpty { return .recallPreviousMessage }
        return .navigateAutocomplete
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
        if isComposerSubmissionBlocked {
            return "Session is compacting"
        }
        guard defaultSubmitKind != nil else {
            return "This session cannot accept composer input"
        }
        guard hasDraftText else {
            return "Enter a message to send"
        }

        switch effectiveBashMode {
        case .visible:
            return "Run bash · output added to Pi context"
        case .private:
            return "Run bash · output hidden from Pi context"
        case .none:
            switch defaultSubmitKind {
            case .steer:
                return "Send steering message"
            case .followUp:
                return "Send follow-up message"
            case nil:
                return "This session cannot accept composer input"
            }
        }
    }

    private var sendColor: Color {
        if effectiveBashMode != .none { return bashAccentColor }
        // Send is an action, so it uses Action Blue for both follow-up and steer.
        // The submit kind is a function of session status (already conveyed by the
        // header status dot / running border) and the tooltip, so the button color
        // does not need to re-encode it with a status color.
        return DS.Colors.accentText
    }

    private func submitDefault() {
        submit(defaultSubmitKind)
    }

    private func submitOptionReturn() {
        submit(optionReturnSubmitKind)
    }

    private func submit(_ kind: PickyConversationComposerSubmitKind?) {
        guard !isComposerSubmissionBlocked else { return }
        let submittedSessionID = session.id
        let submittedAttachmentIDs = Set(attachments.map(\.id))
        let attachmentPaths = attachments.map(\.path)
        let text = Self.submissionText(draft: draft, attachmentPaths: attachmentPaths)
        if attachmentPaths.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/tree" {
            onRequestRewind()
            draft = ""
            viewModel.clearComposerDraft(sessionID: submittedSessionID)
            return
        }
        guard !text.isEmpty, let kind else { return }
        let originalDraft = draft
        Task {
            do {
                switch kind {
                case .steer:
                    try await viewModel.steer(text: text, sessionID: submittedSessionID)
                case .followUp:
                    try await viewModel.followUp(text: text, sessionID: submittedSessionID)
                }
                let shouldClearSubmittedDraft = draft == originalDraft
                if shouldClearSubmittedDraft {
                    draft = ""
                }
                attachments.removeAll { attachment in
                    submittedAttachmentIDs.contains(attachment.id)
                }
                if shouldClearSubmittedDraft && attachments.isEmpty {
                    viewModel.clearComposerDraft(sessionID: submittedSessionID)
                } else {
                    if shouldClearSubmittedDraft {
                        viewModel.updateComposerDraft("", sessionID: submittedSessionID)
                    }
                    viewModel.updateComposerAttachmentPaths(attachments.map(\.path), sessionID: submittedSessionID)
                }
            } catch {
                // PickySessionListViewModel surfaces command failures through lastError.
            }
        }
    }

    @discardableResult
    private func recallPreviousSubmittedMessage() -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let previousText = Self.previousUserMessageText(in: session.messages) else { return false }
        draft = previousText
        isFocused = true
        return true
    }

    static func previousUserMessageText(in messages: [PickySessionMessage]) -> String? {
        messages.reversed().first { message in
            guard message.kind == .userText else { return false }
            return !(message.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }?.text
    }

    @discardableResult
    private func clearQueuedMessages() -> Bool {
        guard PickyQueuedInputDraftPolicy.queuedInputText(
            queuedSteers: session.queuedSteers,
            queuedFollowUps: session.queuedFollowUps,
            kind: .all
        ) != nil else { return false }
        Task { try? await viewModel.clearQueueRestoringQueuedInputs(sessionID: session.id, kind: .all) }
        return true
    }

    static func draftRestoringQueuedMessages(
        draft: String,
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem]
    ) -> String? {
        PickyQueuedInputDraftPolicy.draftRestoringQueuedInputs(
            draft: draft,
            queuedSteers: queuedSteers,
            queuedFollowUps: queuedFollowUps,
            kind: .all
        )
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
    private static let maxVisibleAutocompleteSuggestions = 4
    private static let slashCommandLoadingRetryIntervalNanoseconds: UInt64 = 1_000_000_000

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await viewModel.abortRestoringQueuedInputs(sessionID: session.id) }
    }
}

/// Composer-only attachment representation. The path is still appended to the
/// outgoing message text at submit time so Pi sees the same payload as before;
/// chips just keep paths out of the editor so they can't be split or corrupted
/// by intervening keystrokes.
struct PickyComposerAttachment: Identifiable, Equatable {
    let id: UUID
    let path: String

    init(id: UUID = UUID(), path: String) {
        self.id = id
        self.path = path
    }

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.lastPathComponent }

    var isImage: Bool {
        Self.isImagePath(path)
    }

    static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .image)
    }
}

/// Width of the chip's HStack contentSize, used to detect horizontal overflow
/// so the trailing fade hint only shows when more chips lie offscreen.
struct AttachmentContentWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Width of the ScrollView viewport. Paired with AttachmentContentWidthKey.
struct AttachmentViewportWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct PickyComposerAttachmentChipView: View {
    let attachment: PickyComposerAttachment
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            leading
            Text(attachment.displayName)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 140)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .pickyFont(size: 8, weight: .bold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .help("Remove attachment")
            .accessibilityLabel("Remove attachment \(attachment.displayName)")
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
        .padding(.vertical, 3)
        .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
        .overlay(Capsule().stroke(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5))
        .help(attachment.path)
    }

    @ViewBuilder
    private var leading: some View {
        if attachment.isImage, let image = NSImage(contentsOf: attachment.url) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.medium)
                .aspectRatio(contentMode: .fill)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
        } else {
            Image(systemName: attachment.isImage ? "photo" : "doc.text")
                .pickyFont(size: 10, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(width: 16, height: 16)
        }
    }
}

/// Static tinted border used as the "this Pickle is live" signal on the
/// composer of a running Pickle. The running state is already conveyed by the
/// header status dot and the card status border; this is a steady peripheral
/// cue exactly where the user next acts, without decorative motion.
private struct PickyRunningComposerBorder: View {
    var body: some View {
        let _ = PickyPerf.event("running_composer_border_body")
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .strokeBorder(DS.Colors.info.opacity(0.7), lineWidth: 1.0)
            .accessibilityHidden(true)
    }
}
