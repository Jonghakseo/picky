//
//  PickyScheduledMessageCommandTests.swift
//  PickyTests
//
//  App→daemon contract for per-item queue control and delayed-action
//  scheduled messages, plus the projection that feeds the surface back.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyScheduledMessageCommandTests {
    private func makeViewModel() -> (PickySessionListViewModel, FakePickyAgentClient) {
        let client = FakePickyAgentClient()
        return (
            PickySessionListViewModel(client: client, notificationCenter: PickyNoopNotificationCenter()),
            client
        )
    }

    @Test func perItemQueueCommandsCarryTheTargetedItemID() async throws {
        let (viewModel, client) = makeViewModel()

        try await viewModel.removeQueuedInput(sessionID: "s1", itemID: "q-1")
        try await viewModel.editQueuedFollowUp(sessionID: "s1", itemID: "q-2", text: "  edited  ")
        try await viewModel.sendQueuedFollowUpNow(sessionID: "s1", itemID: "q-3")

        let commands = client.sentCommands
        #expect(commands.map(\.type) == [.removeQueuedInput, .editQueuedFollowUp, .sendQueuedFollowUpNow])
        #expect(commands.map(\.sessionId) == ["s1", "s1", "s1"])
        #expect(commands.map(\.itemId) == ["q-1", "q-2", "q-3"])
        #expect(commands[1].text == "edited")
    }

    @Test func scheduledMessageCommandsCarryDelayAndScheduledID() async throws {
        let (viewModel, client) = makeViewModel()

        try await viewModel.scheduleMessage(sessionID: "s1", text: "check logs", delayMs: 300_000)
        try await viewModel.editScheduledMessage(sessionID: "s1", scheduledID: "d-1", text: "check logs again")
        try await viewModel.sendScheduledMessageNow(sessionID: "s1", scheduledID: "d-2")
        try await viewModel.cancelScheduledMessage(sessionID: "s1", scheduledID: "d-3")

        let commands = client.sentCommands
        #expect(commands.map(\.type) == [
            .scheduleMessage, .editScheduledMessage, .sendScheduledMessageNow, .cancelScheduledMessage,
        ])
        #expect(commands[0].text == "check logs")
        #expect(commands[0].delayMs == 300_000)
        #expect(commands.dropFirst().map(\.scheduledId) == ["d-1", "d-2", "d-3"])
    }

    @Test func emptyOrNonPositiveInputIsRejectedBeforeReachingTheDaemon() async throws {
        let (viewModel, client) = makeViewModel()

        await #expect(throws: (any Error).self) {
            try await viewModel.scheduleMessage(sessionID: "s1", text: "   ", delayMs: 300_000)
        }
        await #expect(throws: (any Error).self) {
            try await viewModel.scheduleMessage(sessionID: "s1", text: "ok", delayMs: 0)
        }
        await #expect(throws: (any Error).self) {
            try await viewModel.editScheduledMessage(sessionID: "s1", scheduledID: "d-1", text: "")
        }

        #expect(client.sentCommands.isEmpty)
    }

    /// Every one of these edits a message the user can still see. Treating "no
    /// answer yet" as success would clear the composer or the row while the daemon
    /// is still deciding, so they wait for the positive acknowledgement.
    @Test func queueCommandsWaitForTheDaemonAcknowledgement() async throws {
        let (viewModel, client) = makeViewModel()

        try await viewModel.removeQueuedInput(sessionID: "s1", itemID: "q-1")
        try await viewModel.editQueuedFollowUp(sessionID: "s1", itemID: "q-2", text: "edited")
        try await viewModel.sendQueuedFollowUpNow(sessionID: "s1", itemID: "q-3")
        try await viewModel.scheduleMessage(sessionID: "s1", text: "later", delayMs: 300_000)
        try await viewModel.editScheduledMessage(sessionID: "s1", scheduledID: "d-1", text: "later still")
        try await viewModel.sendScheduledMessageNow(sessionID: "s1", scheduledID: "d-2")
        try await viewModel.cancelScheduledMessage(sessionID: "s1", scheduledID: "d-3")

        #expect(client.acknowledgementRequirements == Array(repeating: true, count: 7))
        // Attaching a detached runtime and settling the extension's store take seconds.
        #expect(client.acknowledgementTimeouts.allSatisfy { $0 >= 10 })
    }

    /// A row the Pickle already consumed must surface the daemon's rejection so
    /// the panel can report it instead of pretending the edit landed.
    @Test func daemonRejectionSurfacesAsACommandRejection() async throws {
        let (viewModel, client) = makeViewModel()
        client.sendAwaitingErrorResult = PickyErrorEvent(
            code: "queueItemNotFound",
            message: "already delivered",
            commandId: nil
        )

        await #expect(throws: PickyCommandRejection.self) {
            try await viewModel.removeQueuedInput(sessionID: "s1", itemID: "q-1")
        }
    }

    // MARK: - Projection

    @Test func sessionSnapshotCarriesScheduledMessagesIntoTheComposerProjection() throws {
        let json = """
        {
          "id": "s1",
          "title": "Scheduled",
          "status": "running",
          "createdAt": "2026-10-02T01:00:00.000Z",
          "updatedAt": "2026-10-02T01:00:00.000Z",
          "logs": [],
          "tools": [],
          "artifacts": [],
          "changedFiles": [],
          "queuedSteers": [],
          "queuedFollowUps": [],
          "scheduledMessages": [
            {
              "id": "d-1",
              "text": "check deploy logs",
              "dueAt": "2026-10-02T01:05:00.000Z",
              "createdAt": "2026-10-02T01:00:00.000Z"
            }
          ]
        }
        """
        let session = try JSONDecoder.pickyAgentProtocolDecoder()
            .decode(PickyAgentSession.self, from: Data(json.utf8))

        #expect(session.scheduledMessages.map(\.id) == ["d-1"])

        let card = PickySessionListViewModel.SessionCard.fromAgentSession(session)
        let store = PickySessionStore(sessionID: "s1")
        store.replace(card: card)
        let projection = PickyConversationComposerProjection(
            metaStore: store.metaStore,
            conversationStore: store.conversationStore,
            queueStore: store.queueStore
        )

        #expect(projection.scheduledMessages.map(\.text) == ["check deploy logs"])
    }

    /// Older daemons omit the field entirely; the queue mutation must still apply.
    @Test func queueSetMutationDecodesWithAndWithoutScheduledMessages() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let withScheduled = """
        {
          "type": "queueSet",
          "queuedSteers": [],
          "queuedFollowUps": [],
          "scheduledMessages": [
            {"id": "d-1", "text": "later", "dueAt": "2026-10-02T01:05:00.000Z", "createdAt": "2026-10-02T01:00:00.000Z"}
          ],
          "steeringMode": "one-at-a-time",
          "followUpMode": "all"
        }
        """
        let withoutScheduled = """
        {
          "type": "queueSet",
          "queuedSteers": [],
          "queuedFollowUps": [],
          "steeringMode": "one-at-a-time",
          "followUpMode": "all"
        }
        """

        let decodedWith = try decoder.decode(PickySessionProjectionMutation.self, from: Data(withScheduled.utf8))
        let decodedWithout = try decoder.decode(PickySessionProjectionMutation.self, from: Data(withoutScheduled.utf8))

        guard case .queueSet(_, _, let scheduled, _, let followUpMode) = decodedWith,
              case .queueSet(_, _, let missingScheduled, _, _) = decodedWithout else {
            Issue.record("expected queueSet mutations")
            return
        }
        #expect(scheduled.map(\.id) == ["d-1"])
        #expect(followUpMode == .all)
        #expect(missingScheduled.isEmpty)
    }

    // MARK: - Edit mode

    private func editableRow() -> PickyScheduledMessageRow {
        PickyScheduledMessageRow(id: "q-1", kind: .followUp, text: "inspect this", dueAt: nil)
    }

    /// The daemon can reject a save (the Pickle took the message meanwhile). The
    /// typed text has to stay in the composer instead of vanishing with the edit.
    @Test func rejectedEditKeepsEditModeAndTheTypedText() async throws {
        let (viewModel, client) = makeViewModel()
        client.sendAwaitingErrorResult = PickyErrorEvent(
            code: "queueItemNotFound",
            message: "already delivered",
            commandId: nil
        )
        let model = PickyComposerScheduledModel()
        let drafts = DraftRecorder()
        model.handleRowAction(
            editableRow(), action: .edit, commands: viewModel, sessionID: "s1",
            currentDraft: "original draft", applyDraft: drafts.apply
        )
        #expect(model.editing?.id == "q-1")

        model.submitEdit(text: "fixed text", commands: viewModel, sessionID: "s1", applyDraft: drafts.apply)
        try await waitUntil { model.actionError != nil }

        #expect(model.editing?.id == "q-1")
        // Only the text the edit put into the editor; the draft was never restored.
        #expect(drafts.values == ["inspect this"])
        #expect(model.actionErrorRowID == "q-1")
    }

    @Test func acceptedEditEndsEditModeAndRestoresThePreviousDraft() async throws {
        let (viewModel, _) = makeViewModel()
        let model = PickyComposerScheduledModel()
        let drafts = DraftRecorder()
        model.handleRowAction(
            editableRow(), action: .edit, commands: viewModel, sessionID: "s1",
            currentDraft: "original draft", applyDraft: drafts.apply
        )

        model.submitEdit(text: "fixed text", commands: viewModel, sessionID: "s1", applyDraft: drafts.apply)
        try await waitUntil { model.editing == nil }

        #expect(drafts.values == ["inspect this", "original draft"])
        #expect(model.actionError == nil)
    }

    /// The Pickle can take the follow-up (or the timer can fire) while it is being
    /// edited. Edit mode has to end on its own, without swallowing what was typed.
    @Test func editedRowDisappearingEndsEditModeAndKeepsTheTypedText() async throws {
        let (viewModel, _) = makeViewModel()
        let model = PickyComposerScheduledModel()
        let drafts = DraftRecorder()
        model.handleRowAction(
            editableRow(), action: .edit, commands: viewModel, sessionID: "s1",
            currentDraft: "original draft", applyDraft: drafts.apply
        )

        model.reconcile(with: PickyScheduledMessagesPresentation(followUps: [], scheduledMessages: []))

        #expect(model.editing == nil)
        // Only the text the edit put into the editor: the typed text was left alone.
        #expect(drafts.values == ["inspect this"])
        #expect(model.actionError == L10n.t("hud.scheduled.edit.alreadySent"))
        #expect(model.composerVisibleError(isSurfaceVisible: false) != nil)
    }

    @Test func editModeSurvivesWhileTheEditedRowIsStillScheduled() async throws {
        let (viewModel, _) = makeViewModel()
        let model = PickyComposerScheduledModel()
        model.handleRowAction(
            editableRow(), action: .edit, commands: viewModel, sessionID: "s1",
            currentDraft: "original draft", applyDraft: { _ in }
        )

        model.reconcile(with: PickyScheduledMessagesPresentation(
            followUps: [PickyQueueItem(text: "inspect this", enqueuedAt: Date(), id: "q-1")],
            scheduledMessages: []
        ))

        #expect(model.editing?.id == "q-1")
        #expect(model.actionError == nil)
    }

    /// Row errors are printed inside the expanded panel. Anywhere else the
    /// composer has to show them, or a failed command looks like it worked.
    @Test func scheduledErrorsSurfaceInTheComposerWhenThePanelCannotShowThem() async throws {
        let (viewModel, client) = makeViewModel()
        client.sendAwaitingErrorResult = PickyErrorEvent(code: "queueItemNotFound", message: "gone", commandId: nil)
        let model = PickyComposerScheduledModel()
        model.handleRowAction(
            editableRow(), action: .sendNow, commands: viewModel, sessionID: "s1",
            currentDraft: "", applyDraft: { _ in }
        )
        try await waitUntil { model.actionError != nil }

        #expect(model.composerVisibleError(isSurfaceVisible: false) != nil)
        #expect(model.composerVisibleError(isSurfaceVisible: true) != nil, "collapsed panel hides the error")
        model.togglePanel()
        #expect(model.composerVisibleError(isSurfaceVisible: true) == nil, "expanded panel prints it itself")
    }

    @Test func submittingWhileEditingSavesTheScheduledMessageInsteadOfSending() {
        #expect(
            PickyComposerSubmitRoute.route(
                editingScheduledRowID: nil,
                editingScheduledRowKind: nil,
                submitKind: .steer
            ) == .send(.steer)
        )
        #expect(
            PickyComposerSubmitRoute.route(
                editingScheduledRowID: "d-1",
                editingScheduledRowKind: .timed,
                submitKind: .steer
            ) == .saveScheduledEdit(id: "d-1", kind: .timed)
        )
        #expect(
            PickyComposerSubmitRoute.route(
                editingScheduledRowID: "q-1",
                editingScheduledRowKind: .followUp,
                submitKind: .followUp
            ) == .saveScheduledEdit(id: "q-1", kind: .followUp)
        )
    }

    private func waitUntil(
        timeout: Duration = .seconds(2),
        _ condition: () -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while !condition() {
            if ContinuousClock.now >= deadline {
                Issue.record("condition did not become true within \(timeout)")
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Records what the composer's editor was asked to show, in order.
@MainActor
private final class DraftRecorder {
    private(set) var values: [String] = []

    func apply(_ text: String) {
        values.append(text)
    }
}
