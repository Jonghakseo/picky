//
//  PickyComposerScheduledModel.swift
//  Picky
//
//  Composer-owned state for messages that have not been sent yet: queued
//  follow-ups and delayed-action timed messages. It keeps the per-row
//  mutations and the "send when" menu out of the editor's own view state so
//  typing never touches them.
//

import Combine
import Foundation

@MainActor
final class PickyComposerScheduledModel: ObservableObject {
    struct Editing: Equatable {
        let id: String
        let kind: PickyScheduledMessageRow.Kind
        /// Draft that was in the composer before the edit started.
        let restoredDraft: String
    }

    struct SendTimingMenu: Equatable {
        let options: [PickySendTimingOption]
        let isPluginInstalled: Bool
    }

    @Published private(set) var isPanelExpanded = false
    @Published private(set) var pendingDeleteRowID: String?
    @Published private(set) var editing: Editing?
    @Published private(set) var actionError: String?
    @Published private(set) var actionErrorRowID: String?
    @Published var isSendTimingMenuPresented = false
    @Published private(set) var sendTimingMenu: SendTimingMenu?
    @Published private(set) var isInstallingPlugin = false
    @Published private(set) var installError: String?

    func reset() {
        isPanelExpanded = false
        pendingDeleteRowID = nil
        editing = nil
        actionError = nil
        actionErrorRowID = nil
        isSendTimingMenuPresented = false
        sendTimingMenu = nil
        installError = nil
    }

    func togglePanel() {
        isPanelExpanded.toggle()
        if !isPanelExpanded { pendingDeleteRowID = nil }
    }

    func cancelDelete() { pendingDeleteRowID = nil }

    /// `applyDraft` moves the row's text into the editor when an edit starts.
    func handleRowAction(
        _ row: PickyScheduledMessageRow,
        action: PickyScheduledMessageAction,
        commands: any PickySessionCommands,
        sessionID: String,
        currentDraft: String,
        applyDraft: (String) -> Void
    ) {
        actionError = nil
        actionErrorRowID = nil
        switch action {
        case .delete:
            pendingDeleteRowID = row.id
        case .edit:
            beginEdit(row, commands: commands, sessionID: sessionID, currentDraft: currentDraft, applyDraft: applyDraft)
        case .sendNow:
            pendingDeleteRowID = nil
            run(rowID: row.id) {
                switch row.kind {
                case .followUp:
                    try await commands.sendQueuedFollowUpNow(sessionID: sessionID, itemID: row.id)
                case .timed:
                    try await commands.sendScheduledMessageNow(sessionID: sessionID, scheduledID: row.id)
                }
            }
        }
    }

    func confirmDelete(
        _ row: PickyScheduledMessageRow,
        commands: any PickySessionCommands,
        sessionID: String,
        applyDraft: (String) -> Void
    ) {
        pendingDeleteRowID = nil
        if editing?.id == row.id { cancelEdit(commands: commands, sessionID: sessionID, applyDraft: applyDraft) }
        run(rowID: row.id) {
            switch row.kind {
            case .followUp:
                try await commands.removeQueuedInput(sessionID: sessionID, itemID: row.id)
            case .timed:
                try await commands.cancelScheduledMessage(sessionID: sessionID, scheduledID: row.id)
            }
        }
    }

    /// Ends an edit whose row is gone: the Pickle took the follow-up, or the timer
    /// fired. What the user typed stays in the composer so it can be sent as a new
    /// message, and the note says why the edit stopped.
    func reconcile(with presentation: PickyScheduledMessagesPresentation) {
        guard let editing, presentation.row(id: editing.id) == nil else { return }
        self.editing = nil
        actionErrorRowID = nil
        actionError = L10n.t("hud.scheduled.edit.alreadySent")
    }

    func cancelEdit(
        commands: any PickySessionCommands,
        sessionID: String,
        applyDraft: (String) -> Void
    ) {
        guard let editing else { return }
        self.editing = nil
        applyDraft(editing.restoredDraft)
        commands.updateComposerDraft(editing.restoredDraft, sessionID: sessionID)
    }

    /// Saving an edit replaces the pending message instead of sending a new one.
    /// Edit mode ends only once the daemon accepted it: a rejected save keeps the
    /// typed text in the composer so it can be retried instead of disappearing.
    func submitEdit(
        text: String,
        commands: any PickySessionCommands,
        sessionID: String,
        applyDraft: @escaping (String) -> Void
    ) {
        guard let editing else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        actionError = nil
        actionErrorRowID = nil
        Task { [weak self] in
            do {
                switch editing.kind {
                case .followUp:
                    try await commands.editQueuedFollowUp(sessionID: sessionID, itemID: editing.id, text: trimmed)
                case .timed:
                    try await commands.editScheduledMessage(sessionID: sessionID, scheduledID: editing.id, text: trimmed)
                }
                guard let self, self.editing == editing else { return }
                self.editing = nil
                applyDraft(editing.restoredDraft)
                commands.updateComposerDraft(editing.restoredDraft, sessionID: sessionID)
            } catch {
                self?.actionErrorRowID = editing.id
                self?.actionError = error.localizedDescription
            }
        }
    }

    /// Error text the composer has to print itself. Row errors live inside the
    /// expanded panel; with the panel closed or the surface gone they would be
    /// invisible, and a failed edit or install would look like it worked.
    func composerVisibleError(isSurfaceVisible: Bool) -> String? {
        if let installError, !isSendTimingMenuPresented { return installError }
        guard let actionError else { return nil }
        return isSurfaceVisible && isPanelExpanded ? nil : actionError
    }

    func reportCommandFailure(_ error: Error) {
        actionErrorRowID = nil
        actionError = error.localizedDescription
    }

    func clearCommandFailure() {
        actionErrorRowID = nil
        actionError = nil
    }

    // MARK: - Send timing menu

    /// Snapshotting on open keeps the listed send times stable while the menu
    /// is on screen and keeps the package lookup off the typing path.
    func openSendTimingMenu(
        canSendAfterCurrentReply: Bool,
        carriesScreenContext: Bool = false,
        commands: any PickySessionCommands
    ) {
        sendTimingMenu = makeMenu(
            canSendAfterCurrentReply: canSendAfterCurrentReply,
            carriesScreenContext: carriesScreenContext,
            commands: commands
        )
        installError = nil
        isSendTimingMenuPresented = true
    }

    func installPlugin(
        canSendAfterCurrentReply: Bool,
        carriesScreenContext: Bool = false,
        commands: any PickySessionCommands
    ) {
        guard !isInstallingPlugin else { return }
        isInstallingPlugin = true
        installError = nil
        Task { [weak self] in
            defer { self?.isInstallingPlugin = false }
            do {
                try await commands.installScheduledSendPlugin()
                self?.sendTimingMenu = self?.makeMenu(
                    canSendAfterCurrentReply: canSendAfterCurrentReply,
                    carriesScreenContext: carriesScreenContext,
                    commands: commands
                )
            } catch {
                self?.installError = error.localizedDescription
            }
        }
    }

    private func makeMenu(
        canSendAfterCurrentReply: Bool,
        carriesScreenContext: Bool,
        commands: any PickySessionCommands
    ) -> SendTimingMenu {
        let isPluginInstalled = commands.isScheduledSendPluginInstalled()
        return SendTimingMenu(
            options: PickySendTimingPolicy.options(
                canSendAfterCurrentReply: canSendAfterCurrentReply,
                isPluginInstalled: isPluginInstalled,
                carriesScreenContext: carriesScreenContext
            ),
            isPluginInstalled: isPluginInstalled
        )
    }

    private func beginEdit(
        _ row: PickyScheduledMessageRow,
        commands: any PickySessionCommands,
        sessionID: String,
        currentDraft: String,
        applyDraft: (String) -> Void
    ) {
        pendingDeleteRowID = nil
        // Switching rows mid-edit keeps the original draft, not the text of the
        // row that is being abandoned.
        editing = Editing(id: row.id, kind: row.kind, restoredDraft: editing?.restoredDraft ?? currentDraft)
        applyDraft(row.text)
        commands.updateComposerDraft(row.text, sessionID: sessionID)
    }

    private func run(rowID: String, _ operation: @escaping () async throws -> Void) {
        Task { [weak self] in
            do {
                try await operation()
            } catch {
                self?.actionErrorRowID = rowID
                self?.actionError = error.localizedDescription
            }
        }
    }
}
