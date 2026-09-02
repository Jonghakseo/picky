//
//  PickySessionViewModel+SessionProjectionV2.swift
//  Picky
//

import Foundation

/// A recovery response is a localhost round trip. Five seconds is generous for
/// the daemon's session barrier while still repairing a lost request long
/// before a person notices the Pickle has stopped moving.
let sessionProjectionRecoveryDeadlineNanoseconds: UInt64 = 5_000_000_000

extension PickySessionListViewModel {
    /// Routes command-correlated recovery rejections to the per-session
    /// coordinator. Other command errors are ignored by the coordinator.
    func handleSessionProjectionRecoveryFailure(commandID: String?) {
        sessionProjectionRecoveryCoordinator?.receiveRecoveryFailure(commandID: commandID)
    }

    /// Fired by the recovery deadline armed below. A request ID that is no
    /// longer outstanding resolves to a no-op inside the coordinator, so the
    /// deadline never needs cancelling.
    func handleSessionProjectionRecoveryDeadline(sessionID: String, requestID: String) {
        sessionProjectionRecoveryCoordinator?.recoveryDeadlineElapsed(sessionID: sessionID, requestID: requestID)
    }

    /// Last-resort repair for a session whose projection can no longer be
    /// fixed by asking the daemon again.
    func reconnectStalledProjectionOwner(sessionID: String) {
        pickySessionLog("projection stalled, reconnecting owner session=\(sessionID)")
        lastError = "Picky lost sync with this Pickle and is reconnecting."
        projectionOwnerReconnector?.reconnectProjectionOwner(sessionID: sessionID)
    }

    static func makeSessionProjectionRecoveryCoordinator(for viewModel: PickySessionListViewModel) -> PickySessionRecoveryCoordinator {
        PickySessionRecoveryCoordinator(
            requestSnapshot: { [weak viewModel] sessionID, requestID in
                Task { @MainActor [weak viewModel] in
                    guard let viewModel else { return }
                    do {
                        try await viewModel.client.send(PickyCommandEnvelope(
                            id: requestID,
                            type: .getSessionProjectionSnapshot,
                            sessionId: sessionID,
                            requestId: requestID
                        ))
                    } catch {
                        viewModel.lastError = "Session projection recovery failed: \(error.localizedDescription)"
                        viewModel.handleSessionProjectionRecoveryFailure(commandID: requestID)
                        return
                    }
                    // Armed only after the frame is on the wire, so transport
                    // latency never counts against the daemon's answer.
                    try? await Task.sleep(nanoseconds: sessionProjectionRecoveryDeadlineNanoseconds)
                    viewModel.handleSessionProjectionRecoveryDeadline(sessionID: sessionID, requestID: requestID)
                }
            },
            applySnapshot: { [weak viewModel] snapshot, _, origin in viewModel?.applySessionProjectionSnapshot(snapshot, origin: origin) },
            applyTransaction: { [weak viewModel] transaction in viewModel?.applySessionProjectionTransaction(transaction) },
            onProjectionStalled: { [weak viewModel] sessionID in
                viewModel?.reconnectStalledProjectionOwner(sessionID: sessionID)
            }
        )
    }

    private func applySessionProjectionSnapshot(
        _ snapshot: PickySessionProjectionSnapshot,
        origin: PickySessionRecoveryCoordinator.SnapshotOrigin
    ) {
        guard let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage else {
            lastError = "Session projection v2 requires registry storage"
            return
        }
        let previous = sessionProjectionStorage.session(id: snapshot.sessionId)
        let wasActive = storage.registry.activeSessionIDs.contains(snapshot.sessionId)
        applyArchiveIntentUpdate(
            PickySessionProjectionArchiveIntentPolicy.snapshotUpdate(
                archived: snapshot.projection.archived,
                origin: origin,
                pendingLocalIntent: pendingArchiveIntentBySessionID[snapshot.sessionId]
            ),
            sessionID: snapshot.sessionId
        )
        let shouldArchive = archiveStore.manuallyArchivedSessionIDs.contains(snapshot.sessionId)
        guard let card = storage.applyProjectionSnapshot(snapshot, archived: shouldArchive) else {
            lastError = "Discarded invalid session projection snapshot"
            return
        }
        let isActive = storage.registry.activeSessionIDs.contains(snapshot.sessionId)
        if !wasActive && isActive {
            admitActiveSessionToDockLayout(snapshot.sessionId)
        }
        if origin == .recovery {
            applyLiveProjectionTransitionEffects(
                previous: previous,
                incoming: card,
                shouldArchive: shouldArchive
            )
        }
        // Match v1 bootstrap/upsert behavior: start git metadata work before
        // the card first renders, and seed notifications for cold snapshots.
        PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
        PickyGitHubPullRequestStatus.prefetchIfNeeded(
            cwd: card.cwd,
            artifactURLs: card.artifacts.compactMap(\.url)
        )
        if previous == nil {
            // Cold snapshots seed terminal dedupe even when the card is archived.
            markNotificationDeliveredIfNeeded(for: card)
        } else if !shouldArchive {
            deliverNotificationIfNeeded(for: card)
        }
        syncSelectionAfterSessionListChange(skippingRedundantPublishedAssignments: true)
        syncVoiceFollowUpAfterSessionListChange()
        syncScreenContextTargetAfterSessionListChange()
        syncActiveVoiceFollowUpAfterSessionListChange(skippingRedundantPublishedAssignments: true)
    }

    /// Source identity is retained only at the router boundary. This hook is
    /// deliberately invoked from its primary-only callback rather than from
    /// source-free projection application, so child snapshots cannot mask a
    /// stalled primary bootstrap.
    func handleSessionProjectionSnapshotReceived(isPrimary: Bool) {
        guard isPrimary else { return }
        disarmInitialSnapshotWatchdog()
        isLoadingInitialSessionSnapshot = false
    }

    private func applySessionProjectionTransaction(_ transaction: PickySessionProjectionTransaction) {
        guard let storage = sessionProjectionStorage as? PickyRegistrySessionProjectionStorage else {
            lastError = "Session projection v2 requires registry storage"
            return
        }
        let previous = sessionProjectionStorage.session(id: transaction.sessionId)
        let invalidatesSlashCommandCache = transactionChangesSlashCommandMetadata(transaction, storage: storage)
        let wasActive = storage.registry.activeSessionIDs.contains(transaction.sessionId)
        synchronizeArchiveIntent(for: transaction)
        let shouldArchive = archiveStore.manuallyArchivedSessionIDs.contains(transaction.sessionId)
        guard let card = storage.applyProjectionTransaction(transaction, archived: shouldArchive) else {
            lastError = "Discarded session projection transaction without bootstrap"
            return
        }
        let isActive = storage.registry.activeSessionIDs.contains(transaction.sessionId)
        if wasActive != isActive {
            syncSelectionAfterSessionListChange()
            syncVoiceFollowUpAfterSessionListChange()
            syncScreenContextTargetAfterSessionListChange()
            syncActiveVoiceFollowUpAfterSessionListChange()
        }
        // V2 no longer routes through `upsert`, so retain its cache warming
        // side effect without making card materialization globally observable.
        PickyGitRepositoryStatus.prefetchIfNeeded(cwd: card.cwd)
        PickyGitHubPullRequestStatus.prefetchIfNeeded(
            cwd: card.cwd,
            artifactURLs: card.artifacts.compactMap(\.url)
        )
        if shouldInvalidateSlashCommandCache(previous: previous, incoming: card)
            || invalidatesSlashCommandCache
            || transactionContainsPiSessionPathLog(transaction) {
            invalidateSlashCommandCache(sessionID: card.id)
        }
        applyLiveProjectionTransitionEffects(
            previous: previous,
            incoming: card,
            shouldArchive: shouldArchive
        )
        if !shouldArchive {
            deliverNotificationIfNeeded(for: card)
        }
    }

    private func transactionContainsPiSessionPathLog(_ transaction: PickySessionProjectionTransaction) -> Bool {
        transaction.mutations.contains { mutation in
            guard case .logAppend(let line) = mutation else { return false }
            return SessionCard.piSessionFilePath(fromLogLine: line) != nil
        }
    }

    /// `materializedSessionCard()` intentionally gives a log-derived Pi path
    /// precedence over metadata. Inspect the patch against registry metadata
    /// directly so that presentation fallback cannot hide a path or cwd change
    /// from the slash-command cache.
    private func transactionChangesSlashCommandMetadata(
        _ transaction: PickySessionProjectionTransaction,
        storage: PickyRegistrySessionProjectionStorage
    ) -> Bool {
        guard case .loaded(let metadata) = storage.registry
            .existingSessionStore(sessionID: transaction.sessionId)?
            .metaStore.metadataState
        else { return false }
        var cwd = metadata.cwd
        var piSessionFilePath = metadata.piSessionFilePath
        var changed = false
        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation else { continue }
            switch patch.cwd {
            case .unchanged: break
            case .clear:
                changed = changed || cwd != nil
                cwd = nil
            case .set(let replacement):
                changed = changed || cwd != replacement
                cwd = replacement
            }
            switch patch.piSessionFilePath {
            case .unchanged: break
            case .clear:
                changed = changed || piSessionFilePath != nil
                piSessionFilePath = nil
            case .set(let replacement):
                changed = changed || piSessionFilePath != replacement
                piSessionFilePath = replacement
            }
        }
        return changed
    }

    private func applyLiveProjectionTransitionEffects(
        previous: SessionCard?,
        incoming card: SessionCard,
        shouldArchive: Bool
    ) {
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
        if visibleSessionDiffSessionIDs.contains(card.id),
           PickySessionDiffPresentation.isSettledTransition(from: previous?.status, to: card.status) {
            requestSessionDiff(sessionID: card.id)
        }
    }

    private func synchronizeArchiveIntent(for transaction: PickySessionProjectionTransaction) {
        for mutation in transaction.mutations {
            guard case .metaPatch(let patch) = mutation,
                  case .set(let archived) = patch.archived
            else { continue }
            applyArchiveIntentUpdate(
                PickySessionProjectionArchiveIntentPolicy.transactionUpdate(
                    archived: archived,
                    pendingLocalIntent: pendingArchiveIntentBySessionID[transaction.sessionId]
                ),
                sessionID: transaction.sessionId
            )
        }
    }

    private func applyArchiveIntentUpdate(
        _ update: PickySessionProjectionArchiveIntentUpdate,
        sessionID: String
    ) {
        switch update {
        case .preserve:
            return
        case .set(let archived), .setAndResolvePending(let archived):
            if case .setAndResolvePending = update {
                clearPendingArchiveIntent(sessionID: sessionID)
            }
            if archived { archiveStore.manuallyArchivedSessionIDs.insert(sessionID) }
            else { archiveStore.manuallyArchivedSessionIDs.remove(sessionID) }
            archiveStore.archivedSessionIDs = archiveStore.manuallyArchivedSessionIDs
        }
    }
}

enum PickySessionProjectionArchiveIntentUpdate: Equatable {
    case preserve
    case set(Bool)
    case setAndResolvePending(Bool)
}

enum PickySessionProjectionArchiveIntentPolicy {
    static func snapshotUpdate(
        archived: Bool?,
        origin: PickySessionRecoveryCoordinator.SnapshotOrigin,
        pendingLocalIntent: Bool?
    ) -> PickySessionProjectionArchiveIntentUpdate {
        guard let archived else { return .preserve }
        if pendingLocalIntent != nil {
            guard origin == .recovery else { return .preserve }
            // A response to the in-flight recovery request is authoritative
            // even when it conflicts with an optimistic archive intent. It
            // can briefly flicker if the daemon processes the command later,
            // but that later transaction re-applies the archive, whereas
            // preserving the conflict leaves the session hidden forever.
            return .setAndResolvePending(archived)
        }
        switch origin {
        case .recovery:
            return .set(archived)
        case .bootstrap:
            return archived ? .set(true) : .preserve
        }
    }

    static func transactionUpdate(
        archived: Bool,
        pendingLocalIntent: Bool?
    ) -> PickySessionProjectionArchiveIntentUpdate {
        guard let pendingLocalIntent else { return .set(archived) }
        guard archived == pendingLocalIntent else { return .preserve }
        return .setAndResolvePending(archived)
    }
}
