//
//  PickySessionArchiveProjection.swift
//  Picky
//

/// Read-only archive membership boundary for settings and onboarding surfaces.
/// Consumers observe the ID list, then attach each visible row to its own
/// stable session store rather than materializing the global session façade.
@MainActor
protocol PickySessionArchiveMembership: AnyObject {
    var archivedSessionIDs: [String] { get }
    func existingSessionStore(sessionID: String) -> PickySessionStore?
}

extension PickySessionRegistry: PickySessionArchiveMembership {}

/// Narrow live-session aggregate used by Companion controls that need only a
/// reload safety count, not the session-card collection.
@MainActor
protocol PickySessionRunningCountProviding: AnyObject {
    var runningSessionCount: Int { get }
}

extension PickySessionRegistry: PickySessionRunningCountProviding {}

/// Imperative archive operations stay separate from membership observation so
/// an archive list redraw is never coupled to the whole session view model.
@MainActor
protocol PickySessionArchiveCommands: AnyObject {
    func unarchive(sessionID: String)
    func deleteArchivedSession(sessionID: String)
    func deleteAllArchivedSessions()
    func stopArchivedAsyncWork(sessionID: String) async throws
}

extension PickySessionListViewModel: PickySessionArchiveCommands {}

extension PickyAsyncWorkSummary {
    var permitsArchivedDeletion: Bool {
        tracking == .ready && activeRootCount == 0 && pendingCompletionCount == 0
            && uncertainExecutionCount == 0 && canReleaseRuntime
    }
}

extension PickySessionMetadata {
    var isSafeToDeleteArchived: Bool {
        guard [.completed, .failed, .cancelled, .blocked].contains(status) else { return false }
        return asyncWorkSummary?.permitsArchivedDeletion ?? (agentCycle == nil)
    }
}

extension PickySessionListViewModel.SessionCard {
    var isSafeToDeleteArchived: Bool {
        guard [.completed, .failed, .cancelled, .blocked].contains(status) else { return false }
        return asyncWorkSummary?.permitsArchivedDeletion ?? !hasAsyncTracking
    }
}
