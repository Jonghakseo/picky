//
//  PickyFullscreenTurnSnapshotStore.swift
//  Picky
//
//  In-memory turn boundary snapshot store for fullscreen changed-file cards.
//

import Combine
import Foundation

@MainActor
final class PickyFullscreenTurnSnapshotStore: ObservableObject {
    @Published private(set) var snapshots: [String: [String: PickyFullscreenTurnGitSnapshot]] = [:]

    func record(sessionID: String, turnID: String, snapshot: PickyFullscreenTurnGitSnapshot) {
        let trimmedSessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedTurnID = turnID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedSessionID.isEmpty, !trimmedTurnID.isEmpty else { return }
        snapshots[trimmedSessionID, default: [:]][trimmedTurnID] = snapshot
    }

    func snapshot(sessionID: String, turnID: String) -> PickyFullscreenTurnGitSnapshot? {
        snapshots[sessionID]?[turnID]
    }

    func clear(sessionID: String) {
        snapshots.removeValue(forKey: sessionID)
    }
}
