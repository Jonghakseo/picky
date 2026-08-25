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
        if snapshot.projection.archived == true {
            archiveStore.manuallyArchivedSessionIDs.insert(snapshot.sessionId)
            archiveStore.archivedSessionIDs = archiveStore.manuallyArchivedSessionIDs
        }
        let shouldArchive = archiveStore.manuallyArchivedSessionIDs.contains(snapshot.sessionId)
        guard storage.applyProjectionSnapshot(snapshot, archived: shouldArchive) != nil else {
            lastError = "Discarded invalid session projection snapshot"
            return
        }
        disarmInitialSnapshotWatchdog()
        isLoadingInitialSessionSnapshot = false
        syncSelectionAfterSessionListChange()
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange()
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
        if shouldArchive {
            unreadSessionIDs.remove(card.id)
            releaseArchivedTerminalChildIfCommitted(card)
            return
        }
        releasedArchivedChildSessionIDs.remove(card.id)
        requestDoneFlashIfNeeded(previousStatus: previous?.status, incoming: card)
        updateUnreadStateIfNeeded(previousStatus: previous?.status, incoming: card)
        deliverNotificationIfNeeded(for: card)
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
