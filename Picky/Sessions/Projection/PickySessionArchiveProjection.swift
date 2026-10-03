//
//  PickySessionArchiveProjection.swift
//  Picky
//

/// Read-only archive membership boundary for settings surfaces.
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
    func deleteArchivedSession(sessionID: String, onFailure: @escaping @MainActor (Error) -> Void)
    func deleteAllArchivedSessions()
    func deleteAllArchivedSessions(onFailure: @escaping @MainActor (Error) -> Void)
    func stopArchivedAsyncWork(sessionID: String) async throws
}

extension PickySessionListViewModel: PickySessionArchiveCommands {}

extension PickyAsyncWorkSummary {
    var permitsArchivedRuntimeRelease: Bool {
        tracking == .ready && activeRootCount == 0 && pendingCompletionCount == 0
            && uncertainExecutionCount == 0 && attentionCount == 0 && canReleaseRuntime
    }
}

extension PickySessionMetadata {
    var isSafeToReleaseArchivedRuntime: Bool {
        if let asyncWorkSummary {
            return status != .running && status != .queued
                && agentCycle?.phase != .responding && agentCycle?.phase != .compacting
                && asyncWorkSummary.permitsArchivedRuntimeRelease
        }
        return [.completed, .failed, .cancelled, .blocked].contains(status) && agentCycle == nil
    }
}

extension PickySessionListViewModel.SessionCard {
    var isSafeToReleaseArchivedRuntime: Bool {
        if let asyncWorkSummary {
            return status != .running && status != .queued
                && agentCycle?.phase != .responding && agentCycle?.phase != .compacting
                && asyncWorkSummary.permitsArchivedRuntimeRelease
        }
        return [.completed, .failed, .cancelled, .blocked].contains(status) && !hasAsyncTracking
    }
}
