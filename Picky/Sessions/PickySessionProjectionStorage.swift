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

/// Semantic ownership boundary for the façade's session-card projection.
///
/// A storage operation emits exactly one final snapshot through `changes`.
@MainActor
protocol PickySessionProjectionStorage: AnyObject {
    var activeSessions: [PickySessionListViewModel.SessionCard] { get }
    var archivedSessions: [PickySessionListViewModel.SessionCard] { get }
    var changes: AnyPublisher<PickySessionProjectionStorageSnapshot, Never> { get }

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
