//
//  PickySessionViewModel+SessionProjectionV2.swift
//  Picky
//

import Foundation

extension PickySessionListViewModel {
    static func makeSessionProjectionRecoveryCoordinator(for viewModel: PickySessionListViewModel) -> PickySessionRecoveryCoordinator {
        PickySessionRecoveryCoordinator(
            requestSnapshot: { [weak viewModel] sessionID, requestID in
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }
                    do {
                        try await viewModel.client.send(PickyCommandEnvelope(
                            type: .getSessionProjectionSnapshot,
                            sessionId: sessionID,
                            requestId: requestID
                        ))
                    } catch {
                        viewModel.lastError = "Session projection recovery failed: \(error.localizedDescription)"
                    }
                }
            },
            applySnapshot: { [weak viewModel] snapshot, _ in viewModel?.applySessionProjectionSnapshot(snapshot) },
            applyTransaction: { [weak viewModel] transaction in viewModel?.applySessionProjectionTransaction(transaction) }
        )
    }

    private func applySessionProjectionSnapshot(_ snapshot: PickySessionProjectionSnapshot) {
        guard let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage else {
            lastError = "Session projection v2 requires registry storage"
            return
        }
        let previous = sessionProjectionStorage.session(id: snapshot.sessionId)
        let wasActive = storage.registry.activeSessionIDs.contains(snapshot.sessionId)
        let wasArchived = storage.registry.archivedSessionIDs.contains(snapshot.sessionId)
        if snapshot.projection.archived == true {
            archiveStore.manuallyArchivedSessionIDs.insert(snapshot.sessionId)
            archiveStore.archivedSessionIDs = archiveStore.manuallyArchivedSessionIDs
        }
        let shouldArchive = archiveStore.manuallyArchivedSessionIDs.contains(snapshot.sessionId)
        guard let card = storage.applyProjectionSnapshot(snapshot, archived: shouldArchive) else {
            lastError = "Discarded invalid session projection snapshot"
            return
        }
        let isActive = storage.registry.activeSessionIDs.contains(snapshot.sessionId)
        let isArchived = storage.registry.archivedSessionIDs.contains(snapshot.sessionId)
        if wasActive != isActive || wasArchived != isArchived {
            // V2 snapshots publish registry membership directly instead of
            // routing through v1's `applyManualOrder`, so restore the shared
            // dock-layout invariant only when membership actually changes.
            reconcileDockLayout()
        }
        // Match v1 bootstrap/upsert behavior: start git metadata work before
        // the card first renders, and seed notifications for cold snapshots.
        PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
        PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        if previous == nil {
            markNotificationDeliveredIfNeeded(for: card)
        } else {
            deliverNotificationIfNeeded(for: card)
        }
        disarmInitialSnapshotWatchdog()
        if isLoadingInitialSessionSnapshot { isLoadingInitialSessionSnapshot = false }
        syncSelectionAfterSessionListChange(skippingRedundantPublishedAssignments: true)
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange(skippingRedundantPublishedAssignments: true)
    }

    private func applySessionProjectionTransaction(_ transaction: PickySessionProjectionTransaction) {
        guard let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage else {
            lastError = "Session projection v2 requires registry storage"
            return
        }
        let previous = sessionProjectionStorage.session(id: transaction.sessionId)
        synchronizeArchiveIntent(for: transaction)
        let shouldArchive = archiveStore.manuallyArchivedSessionIDs.contains(transaction.sessionId)
        guard let card = storage.applyProjectionTransaction(transaction, archived: shouldArchive) else {
            lastError = "Discarded session projection transaction without bootstrap"
            return
        }
        reconcileTodoProgressExpansion(sessionID: card.id, previousState: previous?.todoState, currentState: card.todoState)
        reconcileSubagentInvocationExpansion(
            sessionID: card.id,
            messages: card.messages,
            previousRuns: previous?.subagentRuns ?? [],
            currentRuns: card.subagentRuns
        )
        // V2 no longer routes through `upsert`, so retain its cache warming
        // side effect without making card materialization globally observable.
        PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
        PickyGitHubPullRequestStatus.prefetchIfNeeded(cwd: card.cwd)
        if transactionContainsRuntimeReattachLog(transaction) {
            invalidateSlashCommandCache(sessionID: card.id)
        }
        if shouldArchive {
            unreadSessionIDs.remove(card.id)
            releaseArchivedTerminalChildIfCommitted(card)
            return
        }
        releasedArchivedChildSessionIDs.remove(card.id)
        requestDoneFlashIfNeeded(previousStatus: previous?.status, incoming: card)
        updateUnreadStateIfNeeded(previousStatus: previous?.status, incoming: card)
        deliverNotificationIfNeeded(for: card)
        if visibleSessionDiffSessionIDs.contains(card.id),
           PickySessionDiffPresentation.isSettledTransition(from: previous?.status, to: card.status) {
            requestSessionDiff(sessionID: card.id)
        }
    }

    private func transactionContainsRuntimeReattachLog(_ transaction: PickySessionProjectionTransaction) -> Bool {
        transaction.mutations.contains { mutation in
            guard case .logAppend(let line) = mutation else { return false }
            return SessionCard.isRuntimeReattachLogLine(line)
        }
    }

    private func synchronizeArchiveIntent(for transaction: PickySessionProjectionTransaction) {
        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation else { continue }
            switch patch.archived {
            case .unchanged, .clear: continue
            case .set(let archived):
                if archived { archiveStore.manuallyArchivedSessionIDs.insert(transaction.sessionId) }
                else { archiveStore.manuallyArchivedSessionIDs.remove(transaction.sessionId) }
                archiveStore.archivedSessionIDs = archiveStore.manuallyArchivedSessionIDs
            }
        }
    }
}
