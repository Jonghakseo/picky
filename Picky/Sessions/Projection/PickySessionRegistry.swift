//
//  PickySessionRegistry.swift
//  Picky
//

import Observation

/// Maintains stable child-store identity independently of the v1 façade arrays.
@MainActor
@Observable
final class PickySessionRegistry {
    @ObservationIgnored private var storesBySessionID: [String: PickySessionStore] = [:]
    /// All registered sessions, kept for stable registry identity assertions.
    private(set) var orderedSessionIDs: [String] = []
    /// Effective membership belongs to the registry, never to a parallel card array.
    private(set) var activeSessionIDs: [String] = []
    private(set) var archivedSessionIDs: [String] = []

    func sessionStore(sessionID: String) -> PickySessionStore {
        if let existing = storesBySessionID[sessionID] { return existing }
        let store = PickySessionStore(sessionID: sessionID)
        storesBySessionID[sessionID] = store
        orderedSessionIDs.append(sessionID)
        return store
    }

    func existingSessionStore(sessionID: String) -> PickySessionStore? {
        storesBySessionID[sessionID]
    }

    func replaceMembership(active: [String], archived: [String]) {
        let normalizedActive = unique(active)
        let activeIDs = Set(normalizedActive)
        let normalizedArchived = unique(archived).filter { !activeIDs.contains($0) }
        let memberIDs = Set(normalizedActive).union(normalizedArchived)

        for sessionID in orderedSessionIDs where !memberIDs.contains(sessionID) {
            storesBySessionID.removeValue(forKey: sessionID)
        }
        orderedSessionIDs.removeAll { !memberIDs.contains($0) }
        for sessionID in normalizedActive + normalizedArchived where storesBySessionID[sessionID] == nil {
            _ = sessionStore(sessionID: sessionID)
        }
        if activeSessionIDs != normalizedActive {
            activeSessionIDs = normalizedActive
        }
        if archivedSessionIDs != normalizedArchived {
            archivedSessionIDs = normalizedArchived
        }
    }

    /// Narrow aggregate for consumers that only need to gate an action on live
    /// Pickles. Reading dock projections makes this react to status changes,
    /// without subscribing to message/tool/log child stores.
    var runningSessionCount: Int {
        activeSessionIDs.reduce(into: 0) { count, sessionID in
            if storesBySessionID[sessionID]?.dockStore.projection?.status == .running {
                count += 1
            }
        }
    }

    func removeSessionStore(sessionID: String) {
        storesBySessionID.removeValue(forKey: sessionID)
        orderedSessionIDs.removeAll { $0 == sessionID }
        activeSessionIDs.removeAll { $0 == sessionID }
        archivedSessionIDs.removeAll { $0 == sessionID }
    }

    private func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }
}
