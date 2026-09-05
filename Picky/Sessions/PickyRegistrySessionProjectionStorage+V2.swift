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

        // A correlated recovery can supersede a lost `/new` transaction. When
        // its Pi session changes an already materialized card, this represents
        // a replacement rather than ordinary hydration, so local transient UI
        // state must not leak into the new Pi session.
        let replacesExistingPiSession = store.materializedSessionCard().map {
            $0.piSessionFilePath != projection.piSessionFilePath
        } ?? false
        let omittedFields = Set(snapshot.omittedFields)
        store.metaStore.replace(PickySessionMetadata(session: projection, revision: snapshot.revision))
        if replacesExistingPiSession {
            store.clearLocallyOwnedProjectionPresentation()
        }
        replaceSnapshotChildren(of: store, projection: projection, omittedFields: omittedFields)
        var presentationSession = projection
        if omittedFields.contains("logs") { presentationSession.logs = [] }
        if omittedFields.contains("tools") { presentationSession.tools = [] }
        store.replaceProjectionPresentation(with: .fromAgentSession(presentationSession))
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
        if transactionIsSessionReplacement(transaction) {
            store.clearLocallyOwnedProjectionPresentation()
        }
        if transaction.mutations.contains(where: requiresPresentationRehydration) {
            guard let session = store.materializedAgentSessionSummary() else { return nil }
            store.replaceProjectionPresentation(with: .fromAgentSession(session))
        }
        store.refreshDockProjection()
        guard let card = store.materializedSessionCard() else { return nil }
        publishProjection(card, archived: archived)
        return card
    }

    /// Moves one existing session between active and archived registry
    /// membership without round-tripping any stable child store through the
    /// lossy v1 `SessionCard` installation boundary.
    @discardableResult
    func moveProjectionMembership(
        sessionID: String,
        archived: Bool
    ) -> PickySessionListViewModel.SessionCard? {
        guard let store = registry.existingSessionStore(sessionID: sessionID),
              let card = store.materializedSessionCard()
        else { return nil }

        let wasActive = registry.activeSessionIDs.contains(sessionID)
        let wasArchived = registry.archivedSessionIDs.contains(sessionID)
        guard archived ? wasActive : wasArchived else { return nil }

        var activeIDs = registry.activeSessionIDs
        var archivedIDs = registry.archivedSessionIDs
        if archived {
            activeIDs.removeAll { $0 == sessionID }
            archivedIDs.append(sessionID)
            archivedIDs = archivedIDs.sorted { lhs, rhs in
                guard let left = registry.existingSessionStore(sessionID: lhs)?.materializedSessionCard(),
                      let right = registry.existingSessionStore(sessionID: rhs)?.materializedSessionCard()
                else { return lhs < rhs }
                if left.createdAt != right.createdAt { return left.createdAt > right.createdAt }
                return left.id < right.id
            }
        } else {
            archivedIDs.removeAll { $0 == sessionID }
            activeIDs.append(sessionID)
        }
        registry.replaceMembership(active: activeIDs, archived: archivedIDs)

        let final = snapshot()
        publish([step(
            active: final.activeSessions,
            archived: final.archivedSessions,
            activeChanged: wasActive != registry.activeSessionIDs.contains(sessionID),
            archivedChanged: wasArchived != registry.archivedSessionIDs.contains(sessionID)
        )], final: final)
        return card
    }

    /// Applies a presentation-only v2 event without round-tripping every
    /// registry store through the lossy v1 `SessionCard` installation path.
    @discardableResult
    func updateProjectionPresentation(
        sessionID: String,
        update: (PickySessionStore) -> Void
    ) -> PickySessionListViewModel.SessionCard? {
        guard let store = registry.existingSessionStore(sessionID: sessionID) else { return nil }
        update(store)
        guard let card = store.materializedSessionCard() else { return nil }
        let final = snapshot()
        let isActive = registry.activeSessionIDs.contains(sessionID)
        let isArchived = registry.archivedSessionIDs.contains(sessionID)
        guard isActive || isArchived else { return nil }
        publish([step(
            active: final.activeSessions,
            archived: final.archivedSessions,
            activeChanged: isActive,
            archivedChanged: isArchived
        )], final: final)
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
            store.conversationStore.importMessages(messages)
        case .logAppend(let line):
            var logs = store.logStore.logsState.loadedValue ?? []
            logs.append(line)
            store.logStore.replace(logs)
            store.appendProjectionLog(line)
        case .logsSet(let logs):
            store.logStore.replace(logs)
        case .toolUpsert(let tool):
            var tools = store.toolStore.toolsState.loadedValue ?? []
            if let index = tools.firstIndex(where: { $0.toolCallId == tool.toolCallId }) { tools[index] = tool }
            else { tools.append(tool) }
            store.toolStore.replace(tools)
            store.applyProjectionTool(tool)
        case .toolsSet(let tools):
            store.toolStore.replace(tools)
        case .todoSet(let todoState):
            store.todoStore.replace(todoState)
        case .subagentRunsSet(let runs):
            store.subagentStore.replace(runs)
        case .artifactUpsert(let artifact):
            var artifacts = store.artifactStore.artifactsState.loadedValue ?? []
            if let index = artifacts.firstIndex(where: { $0.id == artifact.id }) { artifacts[index] = artifact }
            else { artifacts.append(artifact) }
            store.artifactStore.replace(artifacts: artifacts, changedFiles: store.artifactStore.changedFilesProjectionState.loadedValue ?? [])
        case .artifactsSet(let artifacts):
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

    private func requiresPresentationRehydration(_ mutation: PickySessionProjectionMutation) -> Bool {
        switch mutation {
        case .logsSet, .toolsSet:
            true
        default:
            false
        }
    }

    /// `/new` is represented by authoritative empty replacements for all
    /// resettable projection collections. Treat that combination as a fresh
    /// session, clearing locally-owned presentation state before rehydration.
    private func transactionIsSessionReplacement(_ transaction: PickySessionProjectionTransaction) -> Bool {
        var clearsLogs = false
        var clearsTools = false
        var clearsArtifacts = false
        for mutation in transaction.mutations {
            switch mutation {
            case .logsSet(let logs): clearsLogs = logs.isEmpty
            case .toolsSet(let tools): clearsTools = tools.isEmpty
            case .artifactsSet(let artifacts): clearsArtifacts = artifacts.isEmpty
            default: break
            }
        }
        return clearsLogs && clearsTools && clearsArtifacts
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
        apply(patch.notifyMacOSOnCompletion, to: &metadata.notifyMacOSOnCompletion)
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
        let wasActive = activeIDs.contains(card.id)
        let wasArchived = archivedIDs.contains(card.id)
        if shouldArchive {
            activeIDs.removeAll { $0 == card.id }
            if !archivedIDs.contains(card.id) { archivedIDs.append(card.id) }
        } else {
            archivedIDs.removeAll { $0 == card.id }
            if !activeIDs.contains(card.id) { activeIDs.append(card.id) }
        }
        registry.replaceMembership(active: activeIDs, archived: archivedIDs)
        let final = snapshot()
        publish([step(
            active: final.activeSessions,
            archived: final.archivedSessions,
            activeChanged: !shouldArchive || wasActive,
            archivedChanged: shouldArchive || wasArchived
        )], final: final)
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
