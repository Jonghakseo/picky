//
//  PickySessionProjectionStorage.swift
//  Picky
//

import Combine
import Foundation

@MainActor
struct PickySessionProjectionStorageSnapshot: Equatable {
    let activeSessions: [PickySessionListViewModel.SessionCard]
    let archivedSessions: [PickySessionListViewModel.SessionCard]

    func session(id: String) -> PickySessionListViewModel.SessionCard? {
        activeSessions.first { $0.id == id } ?? archivedSessions.first { $0.id == id }
    }
}

/// One assignment boundary retained by the façade mirror. This is a
/// presentation concern, not a wire-protocol dialect: registry mutations and
/// v2 transactions publish the same value.
@MainActor
struct PickySessionProjectionStoragePublicationStep: Equatable {
    let snapshot: PickySessionProjectionStorageSnapshot
    let changesActiveSessions: Bool
    let changesArchivedSessions: Bool
}

/// A semantic storage mutation has one final snapshot and may preserve several
/// façade assignment boundaries for the current ObservableObject bridge.
/// Consumers that do not need that bridge use `finalSnapshot` directly.
@MainActor
struct PickySessionProjectionStoragePublication: Equatable {
    let finalSnapshot: PickySessionProjectionStorageSnapshot
    let steps: [PickySessionProjectionStoragePublicationStep]
}

/// Semantic ownership boundary for the façade's session-card projection.
/// Each operation emits one protocol-neutral publication with its final state.
@MainActor
protocol PickySessionProjectionStorage: AnyObject {
    var activeSessions: [PickySessionListViewModel.SessionCard] { get }
    var archivedSessions: [PickySessionListViewModel.SessionCard] { get }
    var changes: AnyPublisher<PickySessionProjectionStoragePublication, Never> { get }

    func session(id: String) -> PickySessionListViewModel.SessionCard?
    func replaceAllSessions(active: [PickySessionListViewModel.SessionCard], archived: [PickySessionListViewModel.SessionCard])
    func removeSession(id: String)
    @discardableResult func archiveSession(id: String) -> PickySessionListViewModel.SessionCard?
    @discardableResult func unarchiveSession(id: String) -> PickySessionListViewModel.SessionCard?
    func upsertSession(_ card: PickySessionListViewModel.SessionCard, archived: Bool)
    @discardableResult func mutateSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard?
    @discardableResult func mutateArchivedSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard?
    func applyManualOrder(_ order: [String])
}
