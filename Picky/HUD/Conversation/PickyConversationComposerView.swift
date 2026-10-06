//
//  PickyConversationComposerView.swift
//  Picky
//
//  Composer for the conversation-style Pickle card.
//

import AppKit
import Combine
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
    let focusRequestID: Int
    /// Bumped by the HUD when Esc outside this editor should stop the run.
    let stopRequestID: Int
    let focusStackHeightTier: PickyConversationFocusStackHeightTier
    let isUtilityPanelOpen: Bool
    let isCommandShortcutHintVisible: Bool
    let isOptionModifierPressed: Bool
    var onToggleUtilityPanel: () -> Void
    var onRequestRewind: () -> Void
    var onTransientHeightChange: (CGFloat) -> Void
    /// Ceiling for the floating scheduled panel, roughly 40% of the card.
    let scheduledPanelMaxHeight: CGFloat
    @State private var draft: String = ""
    @State private var attachments: [PickyComposerAttachment] = []
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
    @State private var isRestoringQueue = false
    @StateObject private var scheduled = PickyComposerScheduledModel()
    @State private var localStopError: String?
    private var sharedStopError: Binding<String?>?
    var stopErrorInShelf = false
    private var stopError: String? { get { sharedStopError?.wrappedValue ?? localStopError }
        nonmutating set { if let sharedStopError { sharedStopError.wrappedValue = newValue } else { localStopError = newValue } }
    }
    @State private var isStopping = false
    @State private var stopChoiceRequest: PickyStopChoiceRequest?
    @StateObject private var runtimeControls = PickyComposerRuntimeControlsModel()
    /// Nil outside the live HUD; the mic button and voice status are hidden then.
    @Environment(\.pickyComposerDictation) private var composerDictation
    /// Last dictation result appended, so a re-delivered event is ignored.
    @State private var appliedDictationTranscriptID: UUID?
    @State private var isAttachmentPickerPresented = false

    init(
        metaStore: PickySessionMetaStore,
        conversationStore: PickyConversationStore,
        queueStore: PickySessionQueueStore,
        viewModel: any PickySessionCommands,
        droppedFilePaths: Binding<[String]> = .constant([]),
        isFileDropTargeted: Bool = false,
        focusRequestID: Int = 0,
        stopRequestID: Int = 0,
        focusStackHeightTier: PickyConversationFocusStackHeightTier = .regular,
        isUtilityPanelOpen: Bool = false,
        isCommandShortcutHintVisible: Bool = false,
        isOptionModifierPressed: Bool = false,
        sharedStopError: Binding<String?>? = nil,
        stopErrorInShelf: Bool = false,
        scheduledPanelMaxHeight: CGFloat = Self.defaultScheduledPanelMaxHeight,
        onToggleUtilityPanel: @escaping () -> Void = { },
        onRequestRewind: @escaping () -> Void = { },
        onTransientHeightChange: @escaping (CGFloat) -> Void = { _ in }
    ) {
        self.scheduledPanelMaxHeight = scheduledPanelMaxHeight
        self.metaStore = metaStore
        self.conversationStore = conversationStore
        self.queueStore = queueStore
        self.commands = viewModel
        self._droppedFilePaths = droppedFilePaths
        self.isFileDropTargeted = isFileDropTargeted
        self.focusRequestID = focusRequestID
        self.stopRequestID = stopRequestID
        self.focusStackHeightTier = focusStackHeightTier
        self.isUtilityPanelOpen = isUtilityPanelOpen
        self.isCommandShortcutHintVisible = isCommandShortcutHintVisible
        self.isOptionModifierPressed = isOptionModifierPressed
        self.sharedStopError = sharedStopError
        self.stopErrorInShelf = stopErrorInShelf
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
        scheduledPanelMaxHeight: CGFloat = Self.defaultScheduledPanelMaxHeight,
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
            scheduled: session.scheduledMessages,
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
            scheduledPanelMaxHeight: scheduledPanelMaxHeight,
            onToggleUtilityPanel: onToggleUtilityPanel,
            onRequestRewind: onRequestRewind,
            onTransientHeightChange: onTransientHeightChange
        )
    }

    var body: some View {
        let _ = PickyPerf.event("composer_body")
        let scheduledNow = scheduledPresentation
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            scheduledSection(scheduledNow)
            if scheduled.editing != nil {
                PickyScheduledMessageEditBarView(onCancel: cancelScheduledEdit)
            }
            if let scheduledError = scheduled.composerVisibleError(isSurfaceVisible: scheduledNow.isVisible) {
                Label(scheduledError, systemImage: "exclamationmark.triangle")
                    .font(PickyHUDTypography.status)
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let stopError, !stopErrorInShelf {
                Label(L10n.t("hud.asyncTasks.stopError", stopError), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            screenContextAttachmentChip
            if let composerDictation {
                PickyComposerVoiceStatusRow(controller: composerDictation, sessionID: session.id)
            }
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
        .onReceive(composerDictationTranscripts) { transcript in
            appendDictatedTranscript(transcript)
        }
        .onDisappear {
            composerDictation?.cancel(sessionID: session.id)
            commands.updateComposerDraft(draft, sessionID: session.id)
            persistAttachments()
            removeKeyDownMonitor()
            runtimeControls.cancelLoad()
            onTransientHeightChange(0)
        }
        .onReceive(commands.composerDraftRequestPublisher(for: session.id)) { request in
            applyComposerDraftRequestIfNeeded(request)
        }
        .onChange(of: focusRequestID) { _, _ in
            focusComposerIfPossible()
        }
        .onChange(of: stopRequestID) { _, _ in
            stopIfPossible()
        }
        .onChange(of: scheduledNow) { _, presentation in
            scheduled.reconcile(with: presentation)
        }
        .onChange(of: droppedFilePaths) { _, paths in
            guard !paths.isEmpty else { return }
            if !isComposerInputDisabled {
                appendAttachmentPaths(paths)
            }
            droppedFilePaths = []
        }
        .onChange(of: session.id) { _, _ in
            scheduled.reset()
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
        .pickyStopChoiceAlert($stopChoiceRequest) { sessionID, scope in
            guard sessionID == session.id else { return }
            stop(scope: scope)
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

    /// Both pending surfaces live here: queued follow-ups and delayed-action
    /// timed messages. The expanded list floats so the transcript keeps its
    /// height and scroll position.
    var scheduledPresentation: PickyScheduledMessagesPresentation {
        let followUps = session.visibleQueue.followUps
        let scheduledMessages = session.scheduledMessages
        // The composer re-renders on every keystroke; with nothing pending there is
        // no locale, calendar, or relative-time work worth doing on that path.
        guard !followUps.isEmpty || !scheduledMessages.isEmpty else { return .empty }
        return PickyScheduledMessagesPresentation(
            followUps: followUps,
            scheduledMessages: scheduledMessages,
            now: PickyScheduledMessagesPresentation.currentMinute()
        )
    }

    private func scheduledSection(_ presentation: PickyScheduledMessagesPresentation) -> some View {
        PickyComposerScheduledSurface(
            presentation: presentation,
            model: scheduled,
            commands: commands,
            sessionID: session.id,
            maxHeight: resolvedScheduledPanelMaxHeight,
            currentDraft: draft,
            applyDraft: applyEditedDraft
        )
    }

    private var resolvedScheduledPanelMaxHeight: CGFloat {
        focusStackHeightTier == .constrained
            ? min(scheduledPanelMaxHeight, Self.constrainedScheduledPanelMaxHeight)
            : scheduledPanelMaxHeight
    }

    /// Entering, leaving, or saving an edit all replace the editor's text.
    private func applyEditedDraft(_ text: String) {
        draft = text
        synchronizeAutocompleteInput(text: text)
        isFocused = true
    }

    private func cancelScheduledEdit() {
        scheduled.cancelEdit(commands: commands, sessionID: session.id, applyDraft: applyEditedDraft)
    }

    static let defaultScheduledPanelMaxHeight: CGFloat = 240
    private static let constrainedScheduledPanelMaxHeight: CGFloat = 150

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
            onApplyGlobalScope: { runtimeControls.applyStagedGlobalScope(commands: commands, sessionID: session.id) },
            fastMode: PickyComposerFastModeControlState(
                enabled: session.fastMode,
                supported: session.fastModeSupported,
                isUpdating: runtimeControls.isFastModeActionInFlight
            ),
            onToggleFastMode: { runtimeControls.setFastMode(!session.fastMode, commands: commands, sessionID: session.id) },
            completionNotifications: PickyComposerCompletionNotificationState(
                notifyMain: session.notifyMainOnCompletion == true,
                notifyMacOS: session.notifyMacOSOnCompletion == true
            ),
            onToggleNotifyMain: toggleMainPickyCompletion,
            onToggleNotifyMacOS: toggleMacOSCompletionNotification
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

    /// Left: what goes into the message, then this Pickle's settings chip.
    /// It yields width first (the chip's model name shrinks) so the trailing
    /// send/stop actions are never clipped.
    private var leadingActions: some View {
        HStack(spacing: DS.Spacing.space1) {
            attachmentButton
            if effectiveBashMode != .none {
                PickyComposerBashModeBadge(mode: effectiveBashMode)
            }
            runtimeControlsBar
        }
        .layoutPriority(-1)
    }

    private var attachmentButton: some View {
        Button {
            isAttachmentPickerPresented = true
        } label: {
            // While a file is dragged over the card, the attach button doubles
            // as the drop indicator.
            toolbarIcon(
                systemName: isFileDropTargeted ? "doc.badge.plus" : "paperclip",
                color: isFileDropTargeted ? DS.Colors.accentText : DS.Colors.textSecondary
            )
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: isFileDropTargeted))
        .help(L10n.t(isFileDropTargeted ? "hud.composer.drop.help" : "hud.composer.attachment.help"))
        .accessibilityLabel(L10n.t(isFileDropTargeted ? "hud.composer.drop.accessibilityLabel" : "hud.composer.attachment.accessibilityLabel"))
    }

    private func toolbarIcon(systemName: String, color: Color) -> some View {
        PickyComposerToolbarIcon(systemName: systemName, color: color)
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
                onControlP: { shiftPressed in runtimeControls.cycleModel(direction: shiftPressed ? .backward : .forward, commands: commands, sessionID: session.id) },
                onCommandD: composerDictation.map { controller in
                    { controller.toggle(sessionID: session.id) }
                }
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
            PickyComposerAutocompletePanelView(
                snapshot: snapshot,
                selectedIndex: PickySlashCommandAutocompletePolicy.clampedSelectionIndex(
                    selectedAutocompleteIndex,
                    suggestionCount: snapshot.items.count
                ),
                slashCommands: commands.slashCommandsIncludingRewindTreeCommand(
                    commands.slashCommandsBySessionID[session.id] ?? [],
                    sessionID: session.id
                ),
                onAccept: { acceptAutocomplete($0, snapshot: snapshot) }
            )
        }
    }

    private var autocompleteIsVisible: Bool {
        !isComposerInputDisabled
            && !autocompleteInput.isComposing
            && !isAutocompleteDismissed
            && autocompleteSuggestions?.items.isEmpty == false
    }

    private var autocompleteHighlightRange: NSRange? {
        guard !autocompleteInput.isComposing else { return nil }
        return PickyComposerAutocompletePolicy.highlightRange(
            prefix: autocompleteSuggestions?.prefix,
            cursorLocation: autocompleteInput.cursorLocation ?? autocompleteInput.text.utf16.count,
            text: autocompleteInput.text
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
        let selectedIndex = PickySlashCommandAutocompletePolicy.clampedSelectionIndex(
            selectedAutocompleteIndex,
            suggestionCount: snapshot.items.count
        )
        acceptAutocomplete(snapshot.items[selectedIndex], snapshot: snapshot)
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
        case .restoreQueue:
            return restoreQueuedMessages()
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
        if scheduled.editing != nil {
            cancelScheduledEdit()
            return true
        }
        if isScreenContextArmed {
            commands.clearScreenContextTarget(sessionID: session.id)
            return true
        }
        // Esc in the composer never falls through to the panel's
        // cancelOperation (which would close the card mid-sentence). It stops a
        // running Pickle, keeping the draft, and is a no-op otherwise.
        stopIfPossible()
        return true
    }

    private static func eventModifiers(from flags: NSEvent.ModifierFlags) -> EventModifiers {
        var modifiers = EventModifiers()
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        return modifiers
    }

    /// Finished transcripts for this composer's Pickle. Other Pickles' results
    /// are filtered out here so they never touch this draft.
    private var composerDictationTranscripts: AnyPublisher<PickyComposerDictationTranscript, Never> {
        guard let composerDictation else { return Empty().eraseToAnyPublisher() }
        let sessionID = session.id
        return composerDictation.transcripts
            .filter { $0.sessionID == sessionID }
            .eraseToAnyPublisher()
    }

    /// Dictation never sends: the transcript is appended to the draft so the
    /// user can review and edit it first.
    private func appendDictatedTranscript(_ transcript: PickyComposerDictationTranscript) {
        guard appliedDictationTranscriptID != transcript.id else { return }
        appliedDictationTranscriptID = transcript.id
        let updated = PickyComposerDictationDraftPolicy.draft(draft, appending: transcript.text)
        guard updated != draft else { return }
        draft = updated
        composerSelectionOverride = NSRange(location: (updated as NSString).length, length: 0)
        synchronizeAutocompleteInput(text: updated)
        focusComposerIfPossible()
    }

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

    private static let editorTextInsetHeight: CGFloat = 2

    /// Right: panel toggle and voice, then the primary send/stop actions.
    private var trailingActions: some View {
        HStack(spacing: DS.Spacing.space1) {
            HStack(spacing: DS.Spacing.space1) {
                PickyComposerUtilityPanelButton(isOpen: isUtilityPanelOpen,
                    isShortcutHintVisible: isCommandShortcutHintVisible, action: onToggleUtilityPanel)
                if let composerDictation {
                    PickyComposerMicButton(
                        controller: composerDictation,
                        sessionID: session.id,
                        isShortcutHintVisible: isCommandShortcutHintVisible
                    )
                }
            }
            .padding(.trailing, DS.Spacing.space1)
            HStack(spacing: DS.Spacing.space2) {
                sendButton
                if isStopButtonVisible {
                    stopButton
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var sendButton: some View {
        let presentation = submitPresentation
        return PickyComposerSplitSendButton(
            iconName: presentation.iconName,
            accessibilityLabel: presentation.accessibilityLabel,
            helpText: sendHelpText,
            isEnabled: !isSendDisabled,
            tint: sendColor,
            isMenuOpen: scheduled.isSendTimingMenuPresented,
            isMenuEnabled: isSendTimingMenuEnabled,
            onSend: submitActiveKind,
            onToggleMenu: {
                guard isSendTimingMenuEnabled else { return }
                scheduled.openSendTimingMenu(
                    canSendAfterCurrentReply: optionReturnSubmitKind == .followUp,
                    carriesScreenContext: carriesScreenContext,
                    commands: commands
                )
            }
        )
        .pickyInstantPopover(isPresented: $scheduled.isSendTimingMenuPresented, arrowEdge: .top) {
            PickyComposerSendTimingMenuHost(
                scheduled: scheduled,
                commands: commands,
                canSendAfterCurrentReply: optionReturnSubmitKind == .followUp,
                carriesScreenContext: carriesScreenContext,
                onSelect: selectSendTiming
            )
        }
    }

    private var isSendTimingMenuEnabled: Bool {
        PickySendTimingPolicy.isMenuEnabled(
            isSendEnabled: !isSendDisabled,
            isEditingScheduledMessage: scheduled.editing != nil
        )
    }

    /// A timed send stores plain text, so anything that would travel as an image
    /// or a screen capture keeps the timed rows disabled.
    private var carriesScreenContext: Bool {
        !attachments.isEmpty || isScreenContextArmed
    }

    private func selectSendTiming(_ timing: PickySendTiming) {
        if timing == .custom {
            scheduled.openCustomSendTime()
            return
        }
        scheduled.isSendTimingMenuPresented = false
        switch timing {
        case .afterCurrentReply:
            submit(.followUp)
        case .delay, .at:
            if let delayMs = timing.delayMilliseconds() {
                submitScheduled(delayMs: delayMs)
            }
        case .custom:
            break
        }
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

    private func appendAttachmentPaths(_ paths: [String]) {
        let cleaned = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return }
        attachments.append(contentsOf: cleaned.map { PickyComposerAttachment(path: $0) })
        isFocused = true
    }

    private var attachmentChipsRow: some View {
        PickyComposerAttachmentsRow(attachments: $attachments)
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
        switch session.submitStatus {
        case .running, .queued, .waiting_for_input, .cancelled, .failed:
            return .steer
        case .completed, .blocked:
            return .followUp
        }
    }

    var optionReturnSubmitKind: PickyConversationComposerSubmitKind? {
        switch session.submitStatus {
        case .running, .queued, .waiting_for_input, .completed, .blocked:
            return .followUp
        case .cancelled, .failed:
            return nil
        }
    }

    private var placeholder: String {
        PickyComposerLabelPolicy.placeholder(
            isCompacting: session.isCompacting,
            isFileDropTargeted: isFileDropTargeted,
            status: session.submitStatus
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
        route(activeSubmitKind)
    }

    private func submitDefault() {
        route(defaultSubmitKind)
    }

    private func submitOptionReturn() {
        route(optionReturnSubmitKind)
    }

    private func route(_ submitKind: PickyConversationComposerSubmitKind?) {
        switch PickyComposerSubmitRoute.route(
            editingScheduledRowID: scheduled.editing?.id,
            editingScheduledRowKind: scheduled.editing?.kind,
            submitKind: submitKind
        ) {
        case .send(let kind):
            submit(kind)
        case .saveScheduledEdit:
            scheduled.submitEdit(
                text: draft,
                commands: commands,
                sessionID: session.id,
                applyDraft: applyEditedDraft
            )
        }
    }

    /// Timed sends never carry the composer's screen attachments: delayed-action
    /// stores plain text, so the paths would be sent as text instead of images.
    private func submitScheduled(delayMs: Int) {
        let submittedSessionID = session.id
        let submittedAttachmentIDs = Set(attachments.map(\.id))
        let text = Self.submissionText(draft: draft, attachmentPaths: attachments.map(\.path))
        guard !text.isEmpty else { return }
        let originalDraft = draft
        Task {
            do {
                try await commands.scheduleMessage(sessionID: submittedSessionID, text: text, delayMs: delayMs)
                clearComposerAfterSubmission(
                    originalDraft: originalDraft,
                    submittedAttachmentIDs: submittedAttachmentIDs,
                    sessionID: submittedSessionID
                )
            } catch {
                scheduled.reportCommandFailure(error)
            }
        }
    }

    /// Only what was actually submitted leaves the composer: a draft edited or an
    /// attachment added while the command was in flight stays for the next message.
    private func clearComposerAfterSubmission(
        originalDraft: String,
        submittedAttachmentIDs: Set<PickyComposerAttachment.ID>,
        sessionID: String
    ) {
        let shouldClearSubmittedDraft = draft == originalDraft
        if shouldClearSubmittedDraft {
            draft = ""
            synchronizeAutocompleteInput(text: "")
        }
        attachments.removeAll { submittedAttachmentIDs.contains($0.id) }
        if shouldClearSubmittedDraft && attachments.isEmpty {
            commands.clearComposerDraft(sessionID: sessionID)
            return
        }
        if shouldClearSubmittedDraft {
            commands.updateComposerDraft("", sessionID: sessionID)
        }
        commands.updateComposerAttachmentPaths(attachments.map(\.path), sessionID: sessionID)
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
                clearComposerAfterSubmission(
                    originalDraft: originalDraft,
                    submittedAttachmentIDs: submittedAttachmentIDs,
                    sessionID: submittedSessionID
                )
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

    /// ⌥↑ pulls every queued input back into the draft. It is the only bulk
    /// queue escape hatch left; per-item control lives in the scheduled panel.
    @discardableResult
    private func restoreQueuedMessages() -> Bool {
        guard !isRestoringQueue,
              PickyQueuedInputRestoreAvailability.resolve(
                visibleQueue: session.visibleQueue,
                kind: .all
              ) == .available else { return false }
        isRestoringQueue = true
        scheduled.clearCommandFailure()
        Task {
            defer { isRestoringQueue = false }
            do {
                try await commands.clearQueueRestoringQueuedInputs(sessionID: session.id, kind: .all)
            } catch {
                scheduled.reportCommandFailure(error)
            }
        }
        return true
    }

    private func installKeyDownMonitorIfNeeded() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard keyDownMonitor == nil else { return }
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == Self.escapeKeyCode,
               let composerDictation,
               composerDictation.phase.isActive,
               composerDictation.phase.sessionID == session.id {
                composerDictation.cancel(sessionID: session.id)
                return nil
            }
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
    private static let escapeKeyCode: UInt16 = 53
    private static let pKeyCode: UInt16 = 35
    private static let autocompleteDebounceNanoseconds: UInt64 = 80_000_000

    private func stopIfPossible() {
        guard PickyComposerStopPolicy.canStop(session.status), !isStopping else { return }
        let choice = commands.stopChoice(sessionID: session.id)
        guard choice == .immediate else {
            stopChoiceRequest = PickyStopChoiceRequest(sessionID: session.id, choice: choice)
            return
        }
        stop(scope: .all)
    }

    private func stop(scope: PickyAbortScope) {
        guard !isStopping else { return }
        isStopping = true
        stopError = nil
        Task { @MainActor in
            defer { isStopping = false }
            do { try await commands.abortRestoringQueuedInputs(sessionID: session.id, scope: scope) } catch { stopError = PickyComposerStopPolicy.message(for: error, at: session.status) }
        }
    }
}
