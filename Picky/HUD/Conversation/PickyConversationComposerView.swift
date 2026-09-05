//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style Pickle card.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    let isOptionModifierPressed: Bool
    var onToggleUtilityPanel: () -> Void
    var onRequestRewind: () -> Void
    var onTransientHeightChange: (CGFloat) -> Void
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
    @State private var measuredEditorContentHeight: CGFloat = PickyComposerEditorHeightPolicy.minimumHeight
    @State private var isFocused: Bool = false
    @State private var queueActionInFlight: PickyQueueDockAction?
    @State private var queueActionError: String?
    @StateObject private var runtimeControls = PickyComposerRuntimeControlsModel()
    @State private var isAttachmentPickerPresented = false

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
        isOptionModifierPressed: Bool = false,
        onToggleUtilityPanel: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { },
        onTransientHeightChange: @escaping (CGFloat) -> Void = { _ in }
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
        self.isOptionModifierPressed = isOptionModifierPressed
        self.onToggleUtilityPanel = onToggleUtilityPanel
        self.onRequestRewind = onRequestRewind
        self.onTransientHeightChange = onTransientHeightChange
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
        isOptionModifierPressed: Bool = false,
        onToggleUtilityPanel: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { },
        onTransientHeightChange: @escaping (CGFloat) -> Void = { _ in }
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
            isOptionModifierPressed: isOptionModifierPressed,
            onToggleUtilityPanel: onToggleUtilityPanel,
            onRequestRewind: onRequestRewind,
            onTransientHeightChange: onTransientHeightChange
        )
    }

    var body: some View {
        let _ = PickyPerf.event("composer_body")
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            queueDock
            screenContextAttachmentChip
            // The custom layout reports only the composer's size, so opening
            // suggestions never reflows the card. It measures the popup itself
            // and places its bottom edge 4pt above the composer's top edge.
            PickyComposerAutocompleteOverlayLayout {
                composerSurface
                if autocompleteIsVisible {
                    autocompletePanel
                }
            }
            .zIndex(1)
        }
        .onAppear {
            commands.ensureSlashCommandsLoaded(sessionID: session.id)
            requestAutocompleteCapabilities()
            installKeyDownMonitorIfNeeded()
            restorePersistedDraftIfNeeded()
            restorePersistedAttachmentsIfNeeded()
            applyComposerDraftRequestIfNeeded(commands.composerDraftRequest(for: session.id))
            synchronizeAutocompleteInput(text: draft)
            runtimeControls.loadOptions(commands: commands, sessionID: session.id)
        }
        .onDisappear {
            commands.updateComposerDraft(draft, sessionID: session.id)
            persistAttachments()
            removeKeyDownMonitor()
            runtimeControls.cancelLoad()
            onTransientHeightChange(0)
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
                appendAttachmentPaths(paths)
            }
            droppedFilePaths = []
        }
        .onChange(of: session.id) { _, _ in
            attachments = commands.persistedComposerAttachmentPaths(for: session.id)
                .map { PickyComposerAttachment(path: $0) }
            measuredEditorContentHeight = PickyComposerEditorHeightPolicy.minimumHeight
            onTransientHeightChange(0)
            resetAutocompleteState()
            synchronizeAutocompleteInput(text: draft)
            requestAutocompleteCapabilities()
            runtimeControls.reset()
            runtimeControls.loadOptions(commands: commands, sessionID: session.id)
        }
        .onChange(of: attachments) { _, _ in
            persistAttachments()
        }
        .onReceive(commands.autocompleteEvents) { event in
            applyAutocompleteEvent(event)
        }
        .fileImporter(
            isPresented: $isAttachmentPickerPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            guard case let .success(urls) = result else { return }
            appendAttachmentPaths(urls.map(\.path))
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

    private var queueDock: some View {
        PickyConversationQueueDockView(
            presentation: PickyQueueDockPresentation(
                visibleQueue: session.visibleQueue,
                steeringMode: session.steeringMode,
                followUpMode: session.followUpMode
            ),
            layout: PickyQueueDockLayout(
                cardWidth: pickyHUDDetailWidth,
                heightTier: focusStackHeightTier
            ),
            actionInFlight: queueActionInFlight,
            actionError: queueActionError,
            onAction: performQueueAction
        )
    }

    private var runtimePresentation: PickyComposerRuntimePresentation {
        PickyComposerRuntimePresentation(assistantRun: session.currentAssistantRun)
    }

    private var runtimeControlsBar: some View {
        PickyConversationRuntimeControlsView(
            presentation: runtimePresentation,
            actionError: runtimeControls.actionError,
            sessionID: session.id,
            isModelPickerPresented: $runtimeControls.isModelPickerPresented,
            runtimeOptions: runtimeControls.runtimeOptions,
            modelPickerLoadState: runtimeControls.loadState,
            isModelActionInFlight: runtimeControls.isModelActionInFlight,
            isThinkingActionInFlight: runtimeControls.isThinkingActionInFlight,
            isGlobalScopeActionInFlight: runtimeControls.isGlobalScopeActionInFlight,
            pickleRuntimeDefaults: runtimeControls.pickleRuntimeDefaults,
            scopeStaging: runtimeControls.scopeStaging,
            globalScopeApplySuccess: runtimeControls.globalScopeApplySuccess,
            onOpenModelPicker: { runtimeControls.openModelPicker(commands: commands, sessionID: session.id) },
            onRetryRuntimeOptions: { runtimeControls.loadOptions(commands: commands, sessionID: session.id) },
            onSelectModel: { runtimeControls.selectModel($0, commands: commands, sessionID: session.id) },
            onSelectThinkingLevel: { runtimeControls.selectThinkingLevel($0, commands: commands, sessionID: session.id) },
            onSetNewPickleDefaultModel: { runtimeControls.setNewPickleDefaultModel($0, commands: commands, sessionID: session.id) },
            onSetNewPickleDefaultThinking: { runtimeControls.setNewPickleDefaultThinking($0, commands: commands, sessionID: session.id) },
            onBeginGlobalScopeEditing: { runtimeControls.beginGlobalScopeEditing() },
            onSetAllModelsEnabled: { runtimeControls.setAllModelsEnabled($0, firstAvailablePattern: $1) },
            onSetStagedScopePattern: { runtimeControls.setStagedScopePattern($0, selected: $1) },
            onReloadGlobalScope: { runtimeControls.reloadGlobalScope(commands: commands, sessionID: session.id) },
            onApplyGlobalScope: { runtimeControls.applyStagedGlobalScope(commands: commands, sessionID: session.id) }
        )
    }

    private var composerSurface: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            composerEditor
            attachmentChipsRow
            actionBar
        }
        .padding(.leading, DS.Spacing.space3)
        .padding(.trailing, DS.Spacing.space2)
        .padding(.top, DS.Spacing.space3)
        .padding(.bottom, DS.Spacing.sm)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(composerBackground)
    }

    private var actionBar: some View {
        HStack(alignment: .center, spacing: DS.Spacing.xs) {
            leadingActions
            Spacer(minLength: DS.Spacing.sm)
            trailingActions
        }
        .frame(height: PickyComposerToolbarMetrics.controlSize)
    }

    private var leadingActions: some View {
        HStack(spacing: DS.Spacing.space2) {
            HStack(spacing: DS.Spacing.space1) {
                attachmentButton
                if effectiveBashMode != .none {
                    bashModeBadge
                } else {
                    completionNotificationOrDropControls
                    terminalButton
                }
            }
            if runtimePresentation.hasControls || runtimeControls.actionError != nil {
                Divider()
                    .frame(height: 18) // design-token-exception: optical divider height inside the composer action row
                runtimeControlsBar
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var attachmentButton: some View {
        Button {
            isAttachmentPickerPresented = true
        } label: {
            toolbarIcon(systemName: "paperclip", color: DS.Colors.textSecondary)
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle())
        .help(L10n.t("hud.composer.attachment.help"))
        .accessibilityLabel(L10n.t("hud.composer.attachment.accessibilityLabel"))
    }

    /// Replaces the notify/terminal actions when the draft is in bash-execution
    /// mode. Keyboard shortcuts remain active while the horizontal badge keeps
    /// the editor's one-line minimum independent from action chrome.
    private var bashModeBadge: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 11, weight: .bold)
            Text(effectiveBashMode == .private ? "PRIVATE" : "BASH")
                .font(PickyHUDTypography.badgeMonospacedBold)
                .fixedSize()
        }
        .foregroundColor(bashAccentColor)
        .padding(.horizontal, DS.Spacing.space2)
        .frame(height: PickyComposerToolbarMetrics.controlSize)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .help(effectiveBashMode == .private
            ? "Bash execution · output hidden from Pi context"
            : "Bash execution · output added to Pi context")
        .accessibilityLabel(effectiveBashMode == .private ? "Bash private mode" : "Bash mode")
    }

    @ViewBuilder
    private var completionNotificationOrDropControls: some View {
        if isFileDropTargeted {
            toolbarIcon(
                systemName: "doc.badge.plus",
                color: DS.Colors.accentText
            )
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                        .fill(DS.Colors.accentSubtle)
                )
                .help(L10n.t("hud.composer.drop.help"))
                .accessibilityLabel(L10n.t("hud.composer.drop.accessibilityLabel"))
        } else {
            PickyCompletionNotificationControlsView(
                notifyMainOnCompletion: session.notifyMainOnCompletion == true,
                notifyMacOSOnCompletion: session.notifyMacOSOnCompletion == true,
                isCommandShortcutHintVisible: isCommandShortcutHintVisible,
                onToggleMain: toggleMainPickyCompletion,
                onToggleMacOS: toggleMacOSCompletionNotification
            )
        }
    }

    private var terminalButton: some View {
        Button(action: onToggleUtilityPanel) {
            toolbarIcon(
                systemName: "terminal.fill",
                color: isUtilityPanelOpen ? DS.Colors.accentText : DS.Colors.textSecondary
            )
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: isUtilityPanelOpen))
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
    }

    private func toolbarIcon(systemName: String, color: Color) -> some View {
        Image(systemName: systemName)
            .pickyFont(size: 10.5, weight: .semibold)
            .foregroundColor(color)
            .frame(
                width: PickyComposerToolbarMetrics.controlSize,
                height: PickyComposerToolbarMetrics.controlSize
            )
            .contentShape(Rectangle())
    }

    private func toggleMainPickyCompletion() {
        let enabled = !(session.notifyMainOnCompletion == true)
        Task { try? await commands.setNotifyMainOnCompletion(sessionID: session.id, enabled: enabled) }
    }

    private func toggleMacOSCompletionNotification() {
        let enabled = !(session.notifyMacOSOnCompletion == true)
        Task { try? await commands.setNotifyMacOSOnCompletion(sessionID: session.id, enabled: enabled) }
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
                onMeasuredContentHeight: handleMeasuredEditorContentHeight,
                onInputChange: applyAutocompleteInput,
                routesMarkedTextReturnToReturnHandler: true,
                onReturn: handleComposerReturnKey,
                onUpArrow: handleComposerUpArrowKey,
                onDownArrow: { moveAutocompleteSelection(.down) },
                onTab: handleComposerTabKey,
                onEscape: handleComposerEscapeKey,
                onControlP: { shiftPressed in runtimeControls.cycleModel(direction: shiftPressed ? .backward : .forward, commands: commands, sessionID: session.id) }
            )
            .frame(height: editorHeight)
            .onChange(of: draft) { _, newValue in
                commands.updateComposerDraft(newValue, sessionID: session.id)
                reportTransientHeightChange(forDraft: newValue)
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
            runtimeControls.cycleThinkingLevel(commands: commands, sessionID: session.id)
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
        max(
            Self.editorHeight(forMeasuredContentHeight: measuredEditorContentHeight),
            Self.editorHeight(for: draft)
        )
    }

    private func handleMeasuredEditorContentHeight(_ contentHeight: CGFloat) {
        measuredEditorContentHeight = contentHeight
        let resolvedEditorHeight = max(
            Self.editorHeight(forMeasuredContentHeight: contentHeight),
            Self.editorHeight(for: draft)
        )
        onTransientHeightChange(
            PickyComposerEditorHeightPolicy.transientGrowth(forEditorHeight: resolvedEditorHeight)
        )
    }

    private func reportTransientHeightChange(forDraft draft: String) {
        let resolvedEditorHeight = max(
            Self.editorHeight(forMeasuredContentHeight: measuredEditorContentHeight),
            Self.editorHeight(for: draft)
        )
        onTransientHeightChange(
            PickyComposerEditorHeightPolicy.transientGrowth(forEditorHeight: resolvedEditorHeight)
        )
    }

    private var composerNSFont: NSFont {
        effectiveBashMode != .none
            ? .monospacedSystemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular)
            : .systemFont(ofSize: PickyHUDTypography.Size.bodyCompact, weight: .regular)
    }

    static func editorHeight(forMeasuredContentHeight contentHeight: CGFloat) -> CGFloat {
        PickyComposerEditorHeightPolicy.height(forMeasuredContentHeight: contentHeight)
    }

    static func editorHeight(for text: String) -> CGFloat {
        PickyComposerEditorHeightPolicy.height(for: text)
    }

    private static let editorTextInsetHeight: CGFloat = 2

    private var trailingActions: some View {
        HStack(spacing: DS.Spacing.space2) {
            sendButton
            if isStopButtonVisible {
                stopButton
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sendButton: some View {
        let presentation = submitPresentation
        return Button(action: submitActiveKind) {
            ZStack {
                Image(systemName: presentation.iconName)
                    .id(presentation.iconName)
                    .transition(.opacity.combined(with: .scale(scale: 0.82)))
            }
            .pickyFont(size: 11, weight: .semibold)
            .foregroundColor(isSendDisabled ? DS.Colors.textTertiary : sendColor)
            .frame(
                width: PickyComposerToolbarMetrics.controlSize,
                height: PickyComposerToolbarMetrics.controlSize
            )
            .contentShape(Rectangle())
            .animation(.easeOut(duration: DS.Animation.fast), value: presentation.iconName)
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: !isSendDisabled))
        .disabled(isSendDisabled)
        .help(sendHelpText)
        .accessibilityLabel(presentation.accessibilityLabel)
        .accessibilityHint(sendHelpText)
    }

    private var stopButton: some View {
        Button(action: stopIfPossible) {
            toolbarIcon(systemName: "stop.fill", color: DS.Colors.destructiveText)
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle())
        .help(L10n.t("hud.composer.stop.help"))
        .accessibilityLabel(L10n.t("hud.composer.stop.accessibilityLabel"))
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

    var activeSubmitKind: PickyConversationComposerSubmitKind? {
        if isOptionModifierPressed, let optionReturnSubmitKind {
            return optionReturnSubmitKind
        }
        return defaultSubmitKind
    }

    private var submitPresentation: PickyComposerSubmitPresentation {
        PickyComposerSubmitPresentation(kind: activeSubmitKind, bashMode: effectiveBashMode)
    }

    var isComposerInputDisabled: Bool {
        // Compaction is a runtime submit barrier, not an editor lock: keep draft
        // typing/editing and persistence alive so in-progress text is not lost.
        false
    }

    private var isSendDisabled: Bool {
        activeSubmitKind == nil || (!hasDraftText && attachments.isEmpty)
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
        PickyComposerLabelPolicy.bashAccentColor(for: effectiveBashMode)
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

    private func appendAttachmentPaths(_ paths: [String]) {
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
        reportTransientHeightChange(forDraft: persistedDraft)
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
        PickyComposerLabelPolicy.placeholder(
            isCompacting: session.isCompacting,
            isFileDropTargeted: isFileDropTargeted,
            status: session.status
        )
    }

    var sendHelpText: String {
        PickyComposerLabelPolicy.sendHelpText(
            isCompacting: session.isCompacting,
            hasDefaultSubmitKind: defaultSubmitKind != nil,
            hasDraftText: hasDraftText,
            bashMode: effectiveBashMode,
            activeSubmitKind: activeSubmitKind
        )
    }

    private var sendColor: Color {
        if effectiveBashMode != .none { return bashAccentColor }
        // Send is an action, so it uses Action Blue for both follow-up and steer.
        // The submit kind is a function of session status (already conveyed by the
        // header status dot / running border) and the tooltip, so the button color
        // does not need to re-encode it with a status color.
        return DS.Colors.accentText
    }

    private func submitActiveKind() {
        submit(activeSubmitKind)
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
        guard PickyQueuedInputRestoreAvailability.resolve(
            visibleQueue: session.visibleQueue,
            kind: .all
        ) == .available else { return false }
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

    private func installKeyDownMonitorIfNeeded() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard isFocused, !isComposerInputDisabled else { return event }
            if event.keyCode == Self.tabKeyCode, event.modifierFlags.contains(.shift) {
                runtimeControls.cycleThinkingLevel(commands: commands, sessionID: session.id)
                return nil
            }
            if event.keyCode == Self.pKeyCode, event.modifierFlags.contains(.control) {
                runtimeControls.cycleModel(direction: event.modifierFlags.contains(.shift) ? .backward : .forward, commands: commands, sessionID: session.id)
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
