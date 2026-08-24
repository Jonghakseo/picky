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
    private(set) var orderedSessionIDs: [String] = []

    func sessionStore(sessionID: String) -> PickySessionStore {
        if let existing = storesBySessionID[sessionID] { return existing }
        let store = PickySessionStore(sessionID: sessionID)
        storesBySessionID[sessionID] = store
        orderedSessionIDs.append(sessionID)
        return store
    }

    func removeSessionStore(sessionID: String) {
        storesBySessionID.removeValue(forKey: sessionID)
        orderedSessionIDs.removeAll { $0 == sessionID }
    }
}
