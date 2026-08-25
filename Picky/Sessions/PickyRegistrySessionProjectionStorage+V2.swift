//
//  PickyRegistrySessionProjectionStorage+V2.swift
//  Picky
//

import Combine
import Foundation

/// V2 projection application stays inside the registry backend so a live
/// transaction mutates only the addressed session's stable child stores.
@MainActor
extension PickyRegistrySessionProjectionStorage {
    @discardableResult
    func applyProjectionSnapshot(
        _ snapshot: PickySessionProjectionSnapshot,
        archived: Bool
    ) -> PickySessionListViewModel.SessionCard? {
        let store = registry.sessionStore(sessionID: snapshot.sessionId)
        let projection = snapshot.projection
        guard projection.id == snapshot.sessionId else { return nil }

        store.metaStore.replace(PickySessionMetadata(session: projection, revision: snapshot.revision))
        replaceSnapshotChildren(of: store, projection: projection, omittedFields: Set(snapshot.omittedFields))
        store.refreshDockProjection()
        guard let card = store.materializedSessionCard() else { return nil }
        publishProjection(card, archived: archived)
        return card
    }

    @discardableResult
    func applyProjectionTransaction(
        _ transaction: PickySessionProjectionTransaction,
        archived: Bool
    ) -> PickySessionListViewModel.SessionCard? {
        guard let store = registry.existingSessionStore(sessionID: transaction.sessionId),
              case .loaded(var metadata) = store.metaStore.metadataState else {
            return nil
        }

        for mutation in transaction.mutations {
            apply(mutation, to: store, metadata: &metadata)
        }
        metadata.revision = transaction.revision
        store.metaStore.replace(metadata)
        store.refreshDockProjection()
        guard let card = store.materializedSessionCard() else { return nil }
        publishProjection(card, archived: archived)
        return card
    }

    private func replaceSnapshotChildren(
        of store: PickySessionStore,
        projection: PickyAgentSession,
        omittedFields: Set<String>
    ) {
        if omittedFields.contains("logs") { store.logStore.markUnavailable() }
        else { store.logStore.replace(projection.logs) }
        if omittedFields.contains("tools") { store.toolStore.markUnavailable() }
        else { store.toolStore.replace(projection.tools) }
        if omittedFields.contains("todoState") { store.todoStore.markUnavailable() }
        else { store.todoStore.replace(projection.todoState) }
        if omittedFields.contains("subagentRuns") { store.subagentStore.markUnavailable() }
        else { store.subagentStore.replace(projection.subagentRuns) }
        if omittedFields.contains("artifacts") || omittedFields.contains("changedFiles") { store.artifactStore.markUnavailable() }
        else { store.artifactStore.replace(artifacts: projection.artifacts, changedFiles: projection.changedFiles) }
        if omittedFields.contains("messages") { store.conversationStore.markMessagesUnavailable() }
        else {
            store.conversationStore.replaceMessages(projection.messages)
            if omittedFields.contains("messageJournalAvailable") {
                store.conversationStore.markMessageJournalAvailabilityUnavailable()
            } else {
                store.conversationStore.replaceMessageJournalAvailability(projection.messageJournalAvailable)
            }
        }
        if omittedFields.contains("queuedSteers") || omittedFields.contains("queuedFollowUps") {
            store.queueStore.markUnavailable(steeringMode: projection.steeringMode, followUpMode: projection.followUpMode)
        } else {
            store.queueStore.replace(
                steers: projection.queuedSteers,
                followUps: projection.queuedFollowUps,
                steeringMode: projection.steeringMode,
                followUpMode: projection.followUpMode
            )
        }
        if omittedFields.contains("activitySummary") { store.activityStore.markUnavailable() }
        else { store.activityStore.replace(projection.activitySummary) }
        if omittedFields.contains("pendingExtensionUiRequest") { store.extensionUiStore.markUnavailable() }
        else { store.extensionUiStore.replace(projection.pendingExtensionUiRequest) }
    }

    private func apply(
        _ mutation: PickySessionProjectionMutation,
        to store: PickySessionStore,
        metadata: inout PickySessionMetadata
    ) {
        switch mutation {
        case .metaPatch(let patch):
            apply(patch, to: &metadata, conversationStore: store.conversationStore)
        case .messageAppend(let message):
            _ = store.conversationStore.messageStore(message: message)
        case .messageReplace(_, let message):
            _ = store.conversationStore.messageStore(message: message)
        case .messageRemove(let messageID):
            store.conversationStore.removeMessage(id: messageID)
        case .messagesImport(let messages):
            for message in messages { _ = store.conversationStore.messageStore(message: message) }
        case .logAppend(let line):
            var logs = store.logStore.logsState.loadedValue ?? []
            logs.append(line)
            store.logStore.replace(logs)
            store.appendProjectionLog(line)
        case .toolUpsert(let tool):
            var tools = store.toolStore.toolsState.loadedValue ?? []
            if let index = tools.firstIndex(where: { $0.toolCallId == tool.toolCallId }) { tools[index] = tool }
            else { tools.append(tool) }
            store.toolStore.replace(tools)
            store.applyProjectionTool(tool)
        case .todoSet(let todoState):
            store.todoStore.replace(todoState)
        case .subagentRunsSet(let runs):
            store.subagentStore.replace(runs)
        case .artifactUpsert(let artifact):
            var artifacts = store.artifactStore.artifactsState.loadedValue ?? []
            if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) { artifacts[index] = artifact }
            else { artifacts.append(artifact) }
            store.artifactStore.replace(artifacts: artifacts, changedFiles: store.artifactStore.changedFilesProjectionState.loadedValue ?? [])
        case .changedFilesSet(let changedFiles):
            store.artifactStore.replace(artifacts: store.artifactStore.artifactsState.loadedValue ?? [], changedFiles: changedFiles)
        case .queueSet(let steers, let followUps, let steeringMode, let followUpMode):
            store.queueStore.replace(steers: steers, followUps: followUps, steeringMode: steeringMode, followUpMode: followUpMode)
        case .activitySet(let activity):
            store.activityStore.replace(activity)
        case .finalAnswerSet(let finalAnswer):
            metadata.finalAnswer = finalAnswer
        case .extensionUiRequestSet(let request):
            store.extensionUiStore.replace(request)
        }
    }

    private func apply(
        _ patch: PickySessionMetaPatch,
        to metadata: inout PickySessionMetadata,
        conversationStore: PickyConversationStore
    ) {
        // Session identity is a transaction envelope invariant; a meta patch
        // may repeat it for validation but never rekeys an existing store.
        apply(patch.title, to: &metadata.title)
        apply(patch.status, to: &metadata.status)
        apply(patch.cwd, to: &metadata.cwd)
        apply(patch.piSessionFilePath, to: &metadata.piSessionFilePath)
        apply(patch.createdAt, to: &metadata.createdAt)
        apply(patch.updatedAt, to: &metadata.updatedAt)
        apply(patch.lastSummary, to: &metadata.lastSummary)
        apply(patch.thinkingPreview, to: &metadata.thinkingPreview)
        switch patch.messageJournalAvailable {
        case .unchanged: break
        case .clear: conversationStore.replaceMessageJournalAvailability(nil)
        case .set(let available): conversationStore.replaceMessageJournalAvailability(available)
        }
        apply(patch.contextUsage, to: &metadata.contextUsage)
        apply(patch.currentAssistantRun, to: &metadata.currentAssistantRun)
        apply(patch.notifyMainOnCompletion, to: &metadata.notifyMainOnCompletion)
        apply(patch.archived, to: &metadata.archived)
        apply(patch.archivedAt, to: &metadata.archivedAt)
        apply(patch.pinned, to: &metadata.pinned)
    }

    private func apply<Value>(_ update: FieldUpdate<Value>, to value: inout Value) {
        if case .set(let replacement) = update { value = replacement }
    }

    private func apply<Value>(_ update: FieldUpdate<Value>, to value: inout Value?) {
        switch update {
        case .unchanged: break
        case .clear: value = nil
        case .set(let replacement): value = replacement
        }
    }

    private func publishProjection(_ card: PickySessionListViewModel.SessionCard, archived shouldArchive: Bool) {
        var activeIDs = registry.activeSessionIDs
        var archivedIDs = registry.archivedSessionIDs
        if shouldArchive {
            activeIDs.removeAll { $0 == card.id }
            if !archivedIDs.contains(card.id) { archivedIDs.append(card.id) }
        } else {
            archivedIDs.removeAll { $0 == card.id }
            if !activeIDs.contains(card.id) { activeIDs.append(card.id) }
        }
        registry.replaceMembership(active: activeIDs, archived: archivedIDs)
        let final = snapshot()
        v1RelaySteps = [relay(
            active: final.activeSessions,
            archived: final.archivedSessions,
            activeChanged: !shouldArchive,
            archivedChanged: shouldArchive
        )]
        changesSubject.send(final)
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
