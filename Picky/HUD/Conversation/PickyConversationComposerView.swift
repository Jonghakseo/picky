//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style Pickle card.
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

enum PickyComposerBorderState: Equatable {
    case fileDrop
    case bash
    case running
    case focused
    case rest
}

enum PickyComposerAutocompletePlacementPolicy {
    static func popupOrigin(
        composerBounds: CGRect,
        popupSize: CGSize,
        spacing: CGFloat = DS.Spacing.xs
    ) -> CGPoint {
        CGPoint(
            x: composerBounds.minX,
            y: composerBounds.minY - popupSize.height - spacing
        )
    }
}

/// Places the autocomplete popup outside the composer's measured bounds. This
/// keeps the composer/card height stable while avoiding SwiftUI alignment-guide
/// behavior that can place conditional overlay content below the editor.
private struct PickyComposerAutocompleteOverlayLayout: Layout {
    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        subviews.first?.sizeThatFits(proposal) ?? .zero
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        guard let composer = subviews.first else { return }
        composer.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: bounds.height)
        )

        guard subviews.count > 1 else { return }
        let popup = subviews[1]
        let popupProposal = ProposedViewSize(width: bounds.width, height: nil)
        let popupSize = popup.sizeThatFits(popupProposal)
        let origin = PickyComposerAutocompletePlacementPolicy.popupOrigin(
            composerBounds: bounds,
            popupSize: popupSize
        )
        popup.place(at: origin, anchor: .topLeading, proposal: popupProposal)
    }
}

struct PickyConversationComposerView: View {
    /// Composer reads only metadata, message journal, and queue state needed
    /// for its own controls; it never receives a materialized SessionCard.
    let metaStore: PickySessionMetaStore
    let conversationStore: PickyConversationStore
    let queueStore: PickySessionQueueStore
    let commands: any PickySessionCommands
    private var session: PickyConversationComposerProjection {
        PickyConversationComposerProjection(
            metaStore: metaStore,
            conversationStore: conversationStore,
            queueStore: queueStore
        )
    }
    @Binding private var droppedFilePaths: [String]
    let isFileDropTargeted: Bool
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    let focusRequestID: Int
    let focusStackHeightTier: PickyConversationFocusStackHeightTier
    let isUtilityPanelOpen: Bool
    let isCommandShortcutHintVisible: Bool
    var onToggleUtilityPanel: () -> Void
    var onRequestRewind: () -> Void
    @State private var draft: String = ""
    @State private var attachments: [PickyComposerAttachment] = []
    @State private var attachmentContentWidth: CGFloat = 0
    @State private var attachmentViewportWidth: CGFloat = 0
    @State private var selectedAutocompleteIndex: Int = 0
    @State private var isAutocompleteDismissed: Bool = false
    @State private var autocompleteCapabilities: PickyAutocompleteCapabilitiesSnapshot?
    @State private var autocompleteSuggestions: PickyAutocompleteSuggestionsSnapshot?
    @State private var autocompleteCapabilitiesRequestID: String?
    @State private var autocompleteQueryRequestID: String?
    @State private var autocompleteApplyRequestID: String?
    /// TextKit reports text, selection, and IME marked-text changes separately.
    /// This is the one coalesced value allowed to restart the query task.
    @State private var autocompleteInput = PickyComposerAutocompleteInput.empty
    @State private var composerSelectionOverride: NSRange?
    @State private var appliedComposerDraftRequestID: String?
    @State private var keyDownMonitor: Any?
    @State private var measuredEditorContentHeight: CGFloat = Self.minimumEditorHeight
    @State private var isFocused: Bool = false
    @State private var queueActionInFlight: PickyQueueDockAction?
    @State private var queueActionError: String?
    @State private var runtimeActionError: String?

    init(
        metaStore: PickySessionMetaStore,
        conversationStore: PickyConversationStore,
        queueStore: PickySessionQueueStore,
        viewModel: any PickySessionCommands,
        droppedFilePaths: Binding<[String]> = .constant([]),
        isFileDropTargeted: Bool = false,
        focusRequestID: Int = 0,
        focusStackHeightTier: PickyConversationFocusStackHeightTier = .regular,
        isUtilityPanelOpen: Bool = false,
        isCommandShortcutHintVisible: Bool = false,
        onToggleUtilityPanel: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { }
    ) {
        self.metaStore = metaStore
        self.conversationStore = conversationStore
        self.queueStore = queueStore
        self.commands = viewModel
        self._droppedFilePaths = droppedFilePaths
        self.isFileDropTargeted = isFileDropTargeted
        self.focusRequestID = focusRequestID
        self.focusStackHeightTier = focusStackHeightTier
        self.isUtilityPanelOpen = isUtilityPanelOpen
        self.isCommandShortcutHintVisible = isCommandShortcutHintVisible
        self.onToggleUtilityPanel = onToggleUtilityPanel
        self.onRequestRewind = onRequestRewind
    }

    /// Compatibility entry point for focused policy tests and previews.
    init(
        session: PickyConversationSessionCard,
        viewModel: any PickySessionCommands,
        droppedFilePaths: Binding<[String]> = .constant([]),
        isFileDropTargeted: Bool = false,
        focusRequestID: Int = 0,
        focusStackHeightTier: PickyConversationFocusStackHeightTier = .regular,
        isUtilityPanelOpen: Bool = false,
        isCommandShortcutHintVisible: Bool = false,
        onToggleUtilityPanel: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { }
    ) {
        let metaStore = PickySessionMetaStore()
        metaStore.replace(PickySessionMetadata(card: session))
        let conversationStore = PickyConversationStore()
        conversationStore.replaceMessages(session.messages)
        let queueStore = PickySessionQueueStore()
        queueStore.replace(
            steers: session.queuedSteers,
            followUps: session.queuedFollowUps,
            steeringMode: session.steeringMode,
            followUpMode: session.followUpMode
        )
        self.init(
            metaStore: metaStore,
            conversationStore: conversationStore,
            queueStore: queueStore,
            viewModel: viewModel,
            droppedFilePaths: droppedFilePaths,
            isFileDropTargeted: isFileDropTargeted,
            focusRequestID: focusRequestID,
            focusStackHeightTier: focusStackHeightTier,
            isUtilityPanelOpen: isUtilityPanelOpen,
            isCommandShortcutHintVisible: isCommandShortcutHintVisible,
            onToggleUtilityPanel: onToggleUtilityPanel,
            onRequestRewind: onRequestRewind
        )
    }

    var body: some View {
        let _ = PickyPerf.event("composer_body")
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            queueDock
            screenContextAttachmentChip
            attachmentChipsRow
            // The custom layout reports only the composer's size, so opening
            // suggestions never reflows the card. It measures the popup itself
            // and places its bottom edge 4pt above the composer's top edge.
            PickyComposerAutocompleteOverlayLayout {
                composerRow
                if autocompleteIsVisible {
                    autocompletePanel
                }
            }
            .zIndex(1)
            runtimeFooter
        }
        .onAppear {
            commands.ensureSlashCommandsLoaded(sessionID: session.id)
            requestAutocompleteCapabilities()
            installKeyDownMonitorIfNeeded()
            restorePersistedDraftIfNeeded()
            restorePersistedAttachmentsIfNeeded()
            applyComposerDraftRequestIfNeeded(commands.composerDraftRequest(for: session.id))
            synchronizeAutocompleteInput(text: draft)
        }
        .onDisappear {
            commands.updateComposerDraft(draft, sessionID: session.id)
            persistAttachments()
            removeKeyDownMonitor()
        }
        .onChange(of: commands.composerDraftRequest(for: session.id)) { _, request in
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
            attachments = commands.persistedComposerAttachmentPaths(for: session.id)
                .map { PickyComposerAttachment(path: $0) }
            resetAutocompleteState()
            synchronizeAutocompleteInput(text: draft)
            requestAutocompleteCapabilities()
        }
        .onChange(of: attachments) { _, _ in
            persistAttachments()
        }
        .onReceive(commands.autocompleteEvents) { event in
            applyAutocompleteEvent(event)
        }
        .task(id: AutocompleteQueryKey(
            sessionID: session.id,
            input: autocompleteInput,
            generation: autocompleteCapabilities?.generation,
            triggerCharacters: autocompleteCapabilities?.triggerCharacters ?? [],
            isDismissed: isAutocompleteDismissed
        )) {
            let input = autocompleteInput
            guard let capabilities = autocompleteCapabilities,
                  capabilities.generation > 0,
                  !input.isComposing,
                  !isAutocompleteDismissed,
                  PickyComposerAutocompletePolicy.shouldQuery(
                    text: input.text,
                    cursorLocation: input.cursorLocation,
                    triggerCharacters: capabilities.triggerCharacters
                  )
            else { return }
            PickyPerf.event("composer_autocomplete_query_task_started")
            do {
                try await Task.sleep(nanoseconds: Self.autocompleteDebounceNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let position = PickyComposerAutocompletePolicy.cursorPosition(
                    in: input.text,
                    utf16Offset: input.cursorLocation
                  )
            else { return }
            PickyPerf.event("composer_autocomplete_query_sent")
            autocompleteQueryRequestID = commands.queryAutocomplete(
                sessionID: session.id,
                generation: capabilities.generation,
                lines: position.lines,
                cursorLine: position.line,
                cursorCol: position.column,
                draftRevision: input.revision,
                draftFingerprint: input.fingerprint,
                force: false
            )
        }
    }

    private struct AutocompleteQueryKey: Equatable {
        let sessionID: String
        let input: PickyComposerAutocompleteInput
        let generation: Int?
        let triggerCharacters: [String]
        let isDismissed: Bool
    }

    @ViewBuilder
    private var queueDock: some View {
        let presentation = PickyQueueDockPresentation(
            visibleQueue: session.visibleQueue,
            steeringMode: session.steeringMode,
            followUpMode: session.followUpMode
        )
        let layout = PickyQueueDockLayout(
            cardWidth: pickyHUDDetailWidth,
            heightTier: focusStackHeightTier
        )
        if presentation.isVisible {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if layout == .inline {
                    queueDockInlineHeader
                    queueDockKinds(presentation.kinds, layout: layout)
                } else {
                    if layout == .stacked {
                        queueDockTitle
                    }
                    // Compact geometry always presents counts before mutation.
                    queueDockKinds(presentation.kinds, layout: layout)
                    queueDockActions
                }
                if let queueActionError {
                    Text(queueActionError)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.destructiveText)
                        .accessibilityLabel(L10n.t("hud.queue.actionFailed", queueActionError))
                }
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("hud.queue.title"))
            .accessibilityValue(presentation.accessibilityValue)
        }
    }

    private var queueDockInlineHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            queueDockTitle
            Spacer(minLength: 0)
            queueDockActions
        }
    }

    @ViewBuilder
    private func queueDockKinds(
        _ kinds: [PickyQueueDockKindPresentation],
        layout: PickyQueueDockLayout
    ) -> some View {
        if layout == .stacked {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                queueDockKindLabels(kinds)
            }
        } else {
            HStack(spacing: DS.Spacing.sm) {
                queueDockKindLabels(kinds)
            }
        }
    }

    private var queueDockTitle: some View {
        Label(L10n.t("hud.queue.title"), systemImage: "tray.full")
            .font(PickyHUDTypography.statusSemibold)
            .foregroundColor(DS.Colors.textSecondary)
    }

    @ViewBuilder
    private func queueDockKindLabels(_ kinds: [PickyQueueDockKindPresentation]) -> some View {
        ForEach(kinds) { item in
            Text(L10n.t("hud.queue.kindSummary", item.kind.label, Int64(item.count), item.modeLabel))
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var queueDockActions: some View {
        HStack(spacing: DS.Spacing.sm) {
            queueDockActionButton(.restore, title: L10n.t("hud.queue.restore"), color: DS.Colors.accentText)
            queueDockActionButton(.clear, title: L10n.t("hud.queue.clear"), color: DS.Colors.textSecondary)
        }
    }

    private func queueDockActionButton(
        _ action: PickyQueueDockAction,
        title: String,
        color: Color
    ) -> some View {
        Button(queueActionInFlight == action ? action.inFlightLabel : title) {
            performQueueAction(action)
        }
        .buttonStyle(.plain)
        .font(PickyHUDTypography.statusSemibold)
        .foregroundColor(color)
        .disabled(queueActionInFlight != nil)
        .help(L10n.t(action == .restore ? "hud.queue.restore.help" : "hud.queue.clear.help"))
        .accessibilityLabel(L10n.t(
            action == .restore ? "hud.queue.restore.accessibilityLabel" : "hud.queue.clear.accessibilityLabel"
        ))
        .hoverAffordance()
    }

    private var runtimeFooter: some View {
        let presentation = PickyComposerRuntimePresentation(assistantRun: session.currentAssistantRun)
        return Group {
            if presentation.hasControls {
                HStack(spacing: DS.Spacing.sm) {
                    if let modelLabel = presentation.modelLabel {
                        Button(action: { cycleModel(direction: .forward) }) {
                            runtimeFooterLabel(icon: "cpu", text: modelLabel)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("hud.composer.runtime.model.help"))
                        .accessibilityLabel(modelLabel)
                        .accessibilityHint(L10n.t("hud.composer.runtime.model.accessibilityHint"))
                        .hoverAffordance()
                    }
                    if let thinkingLabel = presentation.thinkingLabel {
                        Button(action: cycleThinkingLevel) {
                            runtimeFooterLabel(icon: "brain", text: thinkingLabel)
                        }
                        .buttonStyle(.plain)
                        .help(L10n.t("hud.composer.runtime.thinking.help"))
                        .accessibilityLabel(thinkingLabel)
                        .accessibilityHint(L10n.t("hud.composer.runtime.thinking.accessibilityHint"))
                        .hoverAffordance()
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, DS.Spacing.xs)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.t("hud.composer.runtime.accessibilityLabel"))
                if let runtimeActionError {
                    Text(runtimeActionError)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.destructiveText)
                        .padding(.horizontal, DS.Spacing.xs)
                        .accessibilityLabel(L10n.t("hud.composer.runtime.failed", runtimeActionError))
                }
            }
        }
    }

    private func runtimeFooterLabel(icon: String, text: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(PickyHUDTypography.statusSemibold)
            if focusStackHeightTier == .regular {
                Text(text)
                    .font(PickyHUDTypography.metaMedium)
                    .lineLimit(1)
            }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .contentShape(Rectangle())
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
                .font(PickyHUDTypography.badgeMonospacedBold)
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
                .help(L10n.t("hud.composer.drop.help"))
                .accessibilityLabel(L10n.t("hud.composer.drop.accessibilityLabel"))
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
            .overlay(alignment: .topTrailing) {
                PickyShortcutKeyBadge(label: "N")
                    .fixedSize()
                    .offset(x: 9, y: -7)
                    .opacity(isCommandShortcutHintVisible ? 1 : 0)
                    .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                    .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                    .allowsHitTesting(false)
            }
            .help(notifyOnCompletionHelpText)
            .accessibilityLabel(L10n.t("hud.composer.notify.accessibilityLabel"))
            .accessibilityValue(session.notifyMainOnCompletion == true ? "On" : "Off")
            .hoverAffordance()
        }
    }

    private var terminalButton: some View {
        Button(action: onToggleUtilityPanel) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(isUtilityPanelOpen ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
                .background(terminalButtonBackground)
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            PickyShortcutKeyBadge(label: "E")
                .fixedSize()
                .offset(x: 9, y: -7)
                .opacity(isCommandShortcutHintVisible ? 1 : 0)
                .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                .allowsHitTesting(false)
        }
        .help(L10n.t("hud.utilityPanel.toggle.help"))
        .accessibilityLabel(L10n.t("hud.utilityPanel.accessibilityLabel"))
        .accessibilityValue(L10n.t(isUtilityPanelOpen ? "hud.utilityPanel.state.open" : "hud.utilityPanel.state.closed"))
        .hoverAffordance()
    }

    private var terminalButtonBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
            .fill(isUtilityPanelOpen ? DS.Colors.accentSubtle.opacity(0.24) : Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                    .stroke(isUtilityPanelOpen ? DS.Colors.accentText.opacity(0.28) : Color.clear, lineWidth: 0.5)
            )
    }

    var notifyOnCompletionIconName: String {
        session.notifyMainOnCompletion == true ? "bell.fill" : "bell.slash"
    }

    var notifyOnCompletionHelpText: String {
        L10n.t(session.notifyMainOnCompletion == true
            ? "hud.composer.notify.on.help"
            : "hud.composer.notify.off.help")
    }

    private var notifyOnCompletionColor: Color {
        session.notifyMainOnCompletion == true ? DS.Colors.accentText : DS.Colors.textTertiary
    }

    private func toggleNotifyOnCompletion() {
        let enabled = !(session.notifyMainOnCompletion == true)
        Task { try? await commands.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
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
                temporaryHighlightRange: autocompleteHighlightRange,
                temporaryHighlightColor: NSColor(DS.Colors.accentText),
                onMeasuredContentHeight: { measuredEditorContentHeight = $0 },
                onInputChange: applyAutocompleteInput,
                onReturn: handleComposerReturnKey,
                onUpArrow: handleComposerUpArrowKey,
                onDownArrow: { moveAutocompleteSelection(.down) },
                onTab: handleComposerTabKey,
                onEscape: handleComposerEscapeKey,
                onControlP: { shiftPressed in cycleModel(direction: shiftPressed ? .backward : .forward) }
            )
            .frame(height: editorHeight)
            .onChange(of: draft) { _, newValue in
                commands.updateComposerDraft(newValue, sessionID: session.id)
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
                    commands.clearScreenContextTarget(sessionID: session.id)
                } label: {
                    Image(systemName: "xmark")
                        .pickyFont(size: 8.5, weight: .bold)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .help(L10n.t("hud.composer.screenContext.cancel"))
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
        commands.screenContextTargetSessionID == session.id
    }

    // MARK: - Autocomplete

    /// Pi's composed provider is the single source for slash, path, and extension
    /// completions. Keeping one surface preserves wrapper fallback and custom
    /// applyCompletion semantics instead of racing three independent providers.
    @ViewBuilder
    private var autocompletePanel: some View {
        if let snapshot = autocompleteSuggestions, !snapshot.items.isEmpty {
            let selectedIndex = selectedAutocompleteClampedIndex(for: snapshot.items)
            autocompleteSuggestionList(
                selectedID: selectedIndex,
                suggestionCount: snapshot.items.count
            ) {
                ForEach(Array(snapshot.items.enumerated()), id: \.offset) { index, item in
                    Button {
                        acceptAutocomplete(item, snapshot: snapshot)
                    } label: {
                        autocompleteRow(item, prefix: snapshot.prefix, isSelected: index == selectedIndex)
                    }
                    .buttonStyle(.plain)
                    .id(index)
                }
            }
        }
    }

    private var autocompleteIsVisible: Bool {
        !isComposerInputDisabled
            && !autocompleteInput.isComposing
            && !isAutocompleteDismissed
            && autocompleteSuggestions?.items.isEmpty == false
    }

    /// Keeps the full result set available to keyboard and pointer navigation
    /// while constraining the floating panel to four dense rows. ScrollViewReader
    /// reveals the keyboard-selected item without resizing the composer.
    private func autocompleteSuggestionList<SelectionID: Hashable, Content: View>(
        selectedID: SelectionID,
        suggestionCount: Int,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: suggestionCount > PickySlashCommandAutocompletePolicy.maxVisibleRows) {
                LazyVStack(alignment: .leading, spacing: 1, content: content)
            }
            .scrollDisabled(suggestionCount <= PickySlashCommandAutocompletePolicy.maxVisibleRows)
            .frame(maxHeight: .infinity)
            .onAppear {
                proxy.scrollTo(selectedID, anchor: .center)
            }
            .onChange(of: selectedID) { _, newSelectedID in
                proxy.scrollTo(newSelectedID, anchor: .center)
            }
        }
        .padding(DS.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.autocompletePanelHeight(forSuggestionCount: suggestionCount), alignment: .top)
        .background(autocompletePanelBackground)
    }

    private func autocompleteRow(_ item: PickyAutocompleteItem, prefix: String?, isSelected: Bool) -> some View {
        let command = matchingSlashCommand(for: item, prefix: prefix)
        let isFile = prefix?.hasPrefix("@") == true
        let isDirectory = isFile && item.label.hasSuffix("/")
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if isFile {
                Image(systemName: isDirectory ? "folder.fill" : "doc.text")
                    .pickyFont(size: 10, weight: .semibold)
                    .foregroundColor(isDirectory ? DS.Colors.accentText : DS.Colors.textTertiary)
                    .frame(width: 14)
            }
            Text(command.map { "/\($0.name)" } ?? item.label)
                .font(PickyHUDTypography.labelMonospacedSemibold)
                .foregroundColor(DS.Colors.accentText)
                .lineLimit(1)
            if let command {
                Text(command.source.displayName)
                    .font(PickyHUDTypography.minimumSemibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DS.Colors.surface2.opacity(0.75)))
            }
            if let description = item.description, !description.isEmpty {
                Text(description)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .frame(minHeight: Self.autocompleteRowMinimumHeight)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous)
                .fill(isSelected ? DS.Colors.accentSubtle.opacity(0.55) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func matchingSlashCommand(for item: PickyAutocompleteItem, prefix: String?) -> PickySlashCommand? {
        guard prefix?.hasPrefix("/") == true else { return nil }
        return commands.slashCommandsIncludingRewindTreeCommand(
            commands.slashCommandsBySessionID[session.id] ?? [],
            sessionID: session.id
        ).first { $0.name == item.value }
    }

    private var autocompletePanelBackground: some View {
        let shape = RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
        return PickyHUDMaterialFill(shape: shape, fallback: DS.Colors.surface1)
            .overlay(
                shape.stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 0.8)
            )
            .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 8)
    }

    private var autocompleteHighlightRange: NSRange? {
        guard !autocompleteInput.isComposing else { return nil }
        return PickyComposerAutocompletePolicy.highlightRange(
            prefix: autocompleteSuggestions?.prefix,
            cursorLocation: autocompleteInput.cursorLocation ?? autocompleteInput.text.utf16.count,
            text: autocompleteInput.text
        )
    }

    private func selectedAutocompleteClampedIndex(for suggestions: [PickyAutocompleteItem]) -> Int {
        PickySlashCommandAutocompletePolicy.clampedSelectionIndex(
            selectedAutocompleteIndex,
            suggestionCount: suggestions.count
        )
    }

    private func moveAutocompleteSelection(_ direction: PickySlashCommandNavigationDirection) -> Bool {
        guard autocompleteIsVisible, let items = autocompleteSuggestions?.items, !items.isEmpty else { return false }
        selectedAutocompleteIndex = PickySlashCommandAutocompletePolicy.movedSelectionIndex(
            current: selectedAutocompleteIndex,
            suggestionCount: items.count,
            direction: direction
        )
        return true
    }

    @discardableResult
    private func acceptSelectedAutocomplete() -> Bool {
        guard autocompleteApplyRequestID == nil,
              autocompleteIsVisible,
              let snapshot = autocompleteSuggestions,
              !snapshot.items.isEmpty
        else { return autocompleteApplyRequestID != nil }
        acceptAutocomplete(
            snapshot.items[selectedAutocompleteClampedIndex(for: snapshot.items)],
            snapshot: snapshot
        )
        return true
    }

    private func acceptAutocomplete(_ item: PickyAutocompleteItem, snapshot: PickyAutocompleteSuggestionsSnapshot) {
        guard autocompleteApplyRequestID == nil,
              let prefix = snapshot.prefix,
              let position = PickyComposerAutocompletePolicy.cursorPosition(
                in: autocompleteInput.text,
                utf16Offset: autocompleteInput.cursorLocation
              )
        else { return }
        autocompleteApplyRequestID = commands.applyAutocomplete(
            sessionID: session.id,
            generation: snapshot.generation,
            lines: position.lines,
            cursorLine: position.line,
            cursorCol: position.column,
            draftRevision: autocompleteInput.revision,
            draftFingerprint: autocompleteInput.fingerprint,
            item: item,
            prefix: prefix
        )
    }

    @discardableResult
    private func dismissAutocomplete() -> Bool {
        guard autocompleteIsVisible else { return false }
        isAutocompleteDismissed = true
        autocompleteSuggestions = nil
        autocompleteQueryRequestID = nil
        return true
    }

    private func requestAutocompleteCapabilities() {
        autocompleteCapabilitiesRequestID = commands.requestAutocompleteCapabilities(sessionID: session.id)
    }

    private func applyAutocompleteInput(_ input: PickyIMETextInput) {
        let nextInput = autocompleteInput.updating(
            text: input.text,
            cursorLocation: input.selection.location,
            isComposing: input.hasMarkedText,
            fingerprint: UUID().uuidString
        )
        guard nextInput != autocompleteInput else { return }

        autocompleteInput = nextInput
        selectedAutocompleteIndex = 0
        isAutocompleteDismissed = false
        autocompleteSuggestions = nil
        autocompleteQueryRequestID = nil
        autocompleteApplyRequestID = nil
        PickyPerf.event("composer_autocomplete_input_changed")
    }

    private func synchronizeAutocompleteInput(text: String, cursorLocation: Int? = nil) {
        applyAutocompleteInput(PickyIMETextInput(
            text: text,
            selection: NSRange(location: cursorLocation ?? text.utf16.count, length: 0),
            hasMarkedText: false
        ))
    }

    private func resetAutocompleteState() {
        autocompleteCapabilities = nil
        autocompleteSuggestions = nil
        autocompleteCapabilitiesRequestID = nil
        autocompleteQueryRequestID = nil
        autocompleteApplyRequestID = nil
        selectedAutocompleteIndex = 0
        isAutocompleteDismissed = false
        autocompleteInput = .empty
    }

    private func applyAutocompleteEvent(_ event: PickyAutocompleteClientEvent) {
        switch event {
        case .reconnected:
            resetAutocompleteState()
            requestAutocompleteCapabilities()
        case .resourcesReloaded(let sessionID):
            guard sessionID == session.id else { return }
            resetAutocompleteState()
            requestAutocompleteCapabilities()
        case .capabilities(let snapshot):
            guard snapshot.sessionId == session.id,
                  snapshot.requestId == autocompleteCapabilitiesRequestID else { return }
            autocompleteCapabilities = snapshot
            autocompleteCapabilitiesRequestID = nil
            autocompleteSuggestions = nil
            autocompleteQueryRequestID = nil
        case .suggestions(let snapshot):
            guard snapshot.sessionId == session.id,
                  snapshot.requestId == autocompleteQueryRequestID,
                  snapshot.generation == autocompleteCapabilities?.generation,
                  snapshot.draftRevision == autocompleteInput.revision,
                  snapshot.draftFingerprint == autocompleteInput.fingerprint,
                  let position = PickyComposerAutocompletePolicy.cursorPosition(
                    in: autocompleteInput.text,
                    utf16Offset: autocompleteInput.cursorLocation
                  ),
                  position.line == snapshot.cursorLine,
                  position.column == snapshot.cursorCol,
                  !autocompleteInput.isComposing
            else { return }
            autocompleteQueryRequestID = nil
            autocompleteSuggestions = snapshot.items.isEmpty ? nil : snapshot
            selectedAutocompleteIndex = 0
        case .completion(let completion):
            guard completion.sessionId == session.id,
                  completion.requestId == autocompleteApplyRequestID,
                  completion.generation == autocompleteCapabilities?.generation,
                  completion.draftRevision == autocompleteInput.revision,
                  completion.draftFingerprint == autocompleteInput.fingerprint,
                  let cursorOffset = PickyComposerAutocompletePolicy.utf16Offset(
                    lines: completion.lines,
                    line: completion.cursorLine,
                    column: completion.cursorCol
                  ),
                  !autocompleteInput.isComposing
            else { return }
            autocompleteApplyRequestID = nil
            autocompleteSuggestions = nil
            selectedAutocompleteIndex = 0
            let completedText = PickyComposerAutocompletePolicy.text(from: completion.lines)
            draft = completedText
            synchronizeAutocompleteInput(text: completedText, cursorLocation: cursorOffset)
            composerSelectionOverride = NSRange(location: cursorOffset, length: 0)
            isFocused = true
        }
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
        if acceptSelectedAutocomplete() { return true }
        return requestForcedAutocomplete()
    }

    /// Tab is the only entry point for path completion, matching Pi's editor.
    /// Pi sends forced requests without its natural-trigger debounce, so this
    /// queries directly instead of going through the debounced query task.
    private func requestForcedAutocomplete() -> Bool {
        guard !isComposerInputDisabled,
              let capabilities = autocompleteCapabilities,
              capabilities.generation > 0,
              autocompleteApplyRequestID == nil,
              !autocompleteInput.isComposing,
              let position = PickyComposerAutocompletePolicy.cursorPosition(
                in: autocompleteInput.text,
                utf16Offset: autocompleteInput.cursorLocation
              )
        else { return false }
        isAutocompleteDismissed = false
        autocompleteQueryRequestID = commands.queryAutocomplete(
            sessionID: session.id,
            generation: capabilities.generation,
            lines: position.lines,
            cursorLine: position.line,
            cursorCol: position.column,
            draftRevision: autocompleteInput.revision,
            draftFingerprint: autocompleteInput.fingerprint,
            force: true
        )
        return true
    }

    private func handleComposerEscapeKey() -> Bool {
        if dismissAutocomplete() { return true }
        if isScreenContextArmed {
            commands.clearScreenContextTarget(sessionID: session.id)
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

    // Voice input is intentionally not exposed in the composer. Global PTT
    // resolves the live card under the pointer at press time; SwiftUI hover is
    // presentation-only. The header shows the captured target with mic.fill.

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
        VStack(alignment: .trailing, spacing: 4) {
            sendButton
            if isStopButtonVisible {
                stopButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sendButton: some View {
        let presentation = submitPresentation
        return Button(action: submitDefault) {
            HStack(spacing: DS.Spacing.xs) {
                Image(systemName: presentation.iconName)
                    .pickyFont(size: 11, weight: .semibold)
                Text(presentation.label)
                    .font(PickyHUDTypography.statusSemibold)
                    .lineLimit(1)
            }
            .foregroundColor(isSendDisabled ? DS.Colors.textTertiary : sendColor)
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isSendDisabled)
        .help(sendHelpText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(sendHelpText)
        .hoverAffordance()
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
        .help(L10n.t("hud.composer.stop.help"))
        .accessibilityLabel(L10n.t("hud.composer.stop.accessibilityLabel"))
        .hoverAffordance()
    }

    var isStopButtonVisible: Bool {
        switch session.status {
        case .running:
            return true
        case .waiting_for_input:
            // A fresh manual Pickle parks on `waiting_for_input` with no
            // messages yet; there is nothing to stop until the user submits.
            return session.messageContext.hasAnyMessage
        default:
            return false
        }
    }

    private var submitPresentation: PickyComposerSubmitPresentation {
        PickyComposerSubmitPresentation(kind: defaultSubmitKind, bashMode: effectiveBashMode)
    }

    var isComposerInputDisabled: Bool {
        // Compaction is a runtime submit barrier, not an editor lock: keep draft
        // typing/editing and persistence alive so in-progress text is not lost.
        false
    }

    private var isSendDisabled: Bool {
        defaultSubmitKind == nil || (!hasDraftText && attachments.isEmpty)
    }

    private var hasDraftText: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var composerBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .fill(composerBackgroundFill)
            .overlay {
                // Priority: drag-hover beats everything because that's the
                // action the user is currently performing. Bash mode beats
                // the running animation so the "this submit will execute,
                // not converse" cue stays unambiguous even on a live session.
                switch Self.composerBorderState(
                    isDropTargeted: isFileDropTargeted && !isComposerInputDisabled,
                    bashMode: effectiveBashMode,
                    isRunning: session.status == .running,
                    isFocused: isFocused
                ) {
                case .fileDrop:
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.accentText.opacity(0.85), lineWidth: 1)
                case .bash:
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(bashAccentColor.opacity(0.9), lineWidth: 1)
                case .running:
                    PickyRunningComposerBorder()
                case .focused:
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderStrong, lineWidth: 1)
                case .rest:
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                }
            }
    }

    static func composerBorderState(
        isDropTargeted: Bool,
        bashMode: PickyComposerBashMode,
        isRunning: Bool,
        isFocused: Bool
    ) -> PickyComposerBorderState {
        if isDropTargeted { return .fileDrop }
        if bashMode != .none { return .bash }
        if isRunning { return .running }
        if isFocused { return .focused }
        return .rest
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
        let persistedDraft = commands.persistedComposerDraft(for: session.id)
        guard !persistedDraft.isEmpty else { return }
        draft = persistedDraft
        synchronizeAutocompleteInput(text: persistedDraft)
    }

    private func restorePersistedAttachmentsIfNeeded() {
        guard attachments.isEmpty else { return }
        let persistedPaths = commands.persistedComposerAttachmentPaths(for: session.id)
        guard !persistedPaths.isEmpty else { return }
        attachments = persistedPaths.map { PickyComposerAttachment(path: $0) }
    }

    private func persistAttachments() {
        commands.updateComposerAttachmentPaths(attachments.map(\.path), sessionID: session.id)
    }

    private func applyComposerDraftRequestIfNeeded(_ request: PickyComposerDraftRequest?) {
        guard let request, appliedComposerDraftRequestID != request.id else { return }
        draft = request.text
        synchronizeAutocompleteInput(text: request.text)
        commands.updateComposerDraft(request.text, sessionID: session.id)
        selectedAutocompleteIndex = 0
        autocompleteSuggestions = nil
        autocompleteQueryRequestID = nil
        autocompleteApplyRequestID = nil
        isAutocompleteDismissed = true
        appliedComposerDraftRequestID = request.id
        focusComposerIfPossible()
        commands.consumeComposerDraftRequest(sessionID: session.id, requestID: request.id)
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
        if session.isCompacting { return L10n.t("hud.composer.placeholder.compacting") }
        if isFileDropTargeted { return L10n.t("hud.composer.placeholder.drop") }
        switch session.status {
        case .running, .queued, .waiting_for_input:
            return L10n.t("hud.composer.placeholder.steer")
        case .completed, .blocked:
            return L10n.t("hud.composer.placeholder.followUp")
        case .cancelled:
            return L10n.t("hud.composer.placeholder.resume")
        case .failed:
            return L10n.t("hud.composer.placeholder.recovery")
        }
    }

    var sendHelpText: String {
        if session.isCompacting {
            return L10n.t("hud.composer.send.compacting")
        }
        guard defaultSubmitKind != nil else {
            return L10n.t("hud.composer.send.unavailable")
        }
        guard hasDraftText else {
            return L10n.t("hud.composer.send.empty")
        }

        switch effectiveBashMode {
        case .visible:
            return L10n.t("hud.composer.send.bashVisible")
        case .private:
            return L10n.t("hud.composer.send.bashPrivate")
        case .none:
            switch defaultSubmitKind {
            case .steer:
                return L10n.t("hud.composer.send.steer")
            case .followUp:
                return L10n.t("hud.composer.send.followUp")
            case nil:
                return L10n.t("hud.composer.send.unavailable")
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
        let submittedSessionID = session.id
        let submittedAttachmentIDs = Set(attachments.map(\.id))
        let attachmentPaths = attachments.map(\.path)
        let text = Self.submissionText(draft: draft, attachmentPaths: attachmentPaths)
        if attachmentPaths.isEmpty && draft.trimmingCharacters(in: .whitespacesAndNewlines) == "/tree" {
            onRequestRewind()
            draft = ""
            synchronizeAutocompleteInput(text: "")
            commands.clearComposerDraft(sessionID: submittedSessionID)
            return
        }
        guard !text.isEmpty, let kind else { return }
        let originalDraft = draft
        Task {
            do {
                switch kind {
                case .steer:
                    try await commands.steer(text: text, sessionID: submittedSessionID)
                case .followUp:
                    try await commands.followUp(text: text, sessionID: submittedSessionID)
                }
                let shouldClearSubmittedDraft = draft == originalDraft
                if shouldClearSubmittedDraft {
                    draft = ""
                    synchronizeAutocompleteInput(text: "")
                }
                attachments.removeAll { attachment in
                    submittedAttachmentIDs.contains(attachment.id)
                }
                if shouldClearSubmittedDraft && attachments.isEmpty {
                    commands.clearComposerDraft(sessionID: submittedSessionID)
                } else {
                    if shouldClearSubmittedDraft {
                        commands.updateComposerDraft("", sessionID: submittedSessionID)
                    }
                    commands.updateComposerAttachmentPaths(attachments.map(\.path), sessionID: submittedSessionID)
                }
            } catch {
                // Command failures preserve the draft and attachments for retry.
            }
        }
    }

    @discardableResult
    private func recallPreviousSubmittedMessage() -> Bool {
        guard draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let previousText = Self.previousUserMessageText(in: session.messageContext) else { return false }
        draft = previousText
        synchronizeAutocompleteInput(text: previousText)
        isFocused = true
        return true
    }

    static func previousUserMessageText(in context: PickyComposerMessageContext) -> String? {
        context.submittedUserMessages.last?.text
    }

    @discardableResult
    private func clearQueuedMessages() -> Bool {
        guard PickyQueuedInputDraftPolicy.queuedInputText(
            visibleQueue: session.visibleQueue,
            kind: .all
        ) != nil else { return false }
        performQueueAction(.restore)
        return true
    }

    private func performQueueAction(_ action: PickyQueueDockAction) {
        guard queueActionInFlight == nil else { return }
        queueActionInFlight = action
        queueActionError = nil
        Task {
            do {
                switch action.command {
                case .restoreThenClear(let kind):
                    try await commands.clearQueueRestoringQueuedInputs(sessionID: session.id, kind: kind)
                case .clearOnly(let kind):
                    try await commands.clearQueue(sessionID: session.id, kind: kind)
                }
            } catch {
                queueActionError = error.localizedDescription
            }
            queueActionInFlight = nil
        }
    }

    static func draftRestoringQueuedMessages(
        draft: String,
        queuedSteers: [PickyQueueItem],
        queuedFollowUps: [PickyQueueItem]
    ) -> String? {
        PickyQueuedInputDraftPolicy.draftRestoringQueuedInputs(
            draft: draft,
            visibleQueue: PickyVisibleQueue(
                queuedSteers: queuedSteers,
                queuedFollowUps: queuedFollowUps,
                committedUserMessages: []
            ),
            kind: .all
        )
    }

    private func cycleThinkingLevel() {
        Task {
            do {
                try await commands.cycleThinkingLevel(sessionID: session.id)
                runtimeActionError = nil
            } catch {
                runtimeActionError = error.localizedDescription
            }
        }
    }

    private func cycleModel(direction: PickyModelCycleDirection) {
        Task {
            do {
                try await commands.cycleModel(sessionID: session.id, direction: direction)
                runtimeActionError = nil
            } catch {
                runtimeActionError = error.localizedDescription
            }
        }
    }

    private func installKeyDownMonitorIfNeeded() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
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
    /// Each autocomplete row has a 24pt minimum height, separated by 1pt.
    /// The panel adds a 4pt inset above and below the scrollable rows.
    private static let autocompleteRowMinimumHeight: CGFloat = DS.Spacing.xxl
    private static let autocompleteRowSpacing: CGFloat = 1
    private static let autocompletePanelVerticalInset: CGFloat = DS.Spacing.xs

    static func autocompletePanelHeight(forSuggestionCount suggestionCount: Int) -> CGFloat {
        let visibleRows = min(max(suggestionCount, 0), PickySlashCommandAutocompletePolicy.maxVisibleRows)
        guard visibleRows > 0 else { return 0 }
        return CGFloat(visibleRows) * autocompleteRowMinimumHeight
            + CGFloat(visibleRows - 1) * autocompleteRowSpacing
            + 2 * autocompletePanelVerticalInset
    }
    private static let autocompleteDebounceNanoseconds: UInt64 = 80_000_000

    private func stopIfPossible() {
        guard [.running, .queued, .waiting_for_input].contains(session.status) else { return }
        Task { try? await commands.abortRestoringQueuedInputs(sessionID: session.id) }
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
