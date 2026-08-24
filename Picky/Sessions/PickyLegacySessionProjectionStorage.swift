//
//  PickyLegacySessionProjectionStorage.swift
//  Picky
//

import Combine
import Foundation

/// Temporary v1 façade bridge. The array backend retains its historical
/// per-assignment publication boundaries here; registry-backed storage never
/// adopts this legacy-only detail.
@MainActor
struct PickySessionProjectionStorageRelay: Equatable {
    let snapshot: PickySessionProjectionStorageSnapshot
    let changesActiveSessions: Bool
    let changesArchivedSessions: Bool
}

/// Presentation-only adapter that preserves v1's per-assignment façade
/// publications. It is deliberately outside `PickySessionProjectionStorage`:
/// registry ownership remains defined by semantic operations and one final
/// storage snapshot, while the façade can retain its legacy publish budget.
@MainActor
protocol PickySessionProjectionStorageV1Relaying: PickySessionProjectionStorage {
    var v1RelaySteps: [PickySessionProjectionStorageRelay] { get }
}

@MainActor
protocol PickyLegacySessionProjectionStorageRelaying: PickySessionProjectionStorageV1Relaying {}

/// Array-backed v1 implementation retained until the registry backend is enabled.
@MainActor
final class PickyLegacySessionProjectionStorage: PickyLegacySessionProjectionStorageRelaying {
    private var active: [PickySessionListViewModel.SessionCard] = []
    private var archived: [PickySessionListViewModel.SessionCard] = []
    private let changesSubject = PassthroughSubject<PickySessionProjectionStorageSnapshot, Never>()

    private(set) var v1RelaySteps: [PickySessionProjectionStorageRelay] = []
    var activeSessions: [PickySessionListViewModel.SessionCard] { active }
    var archivedSessions: [PickySessionListViewModel.SessionCard] { archived }
    var changes: AnyPublisher<PickySessionProjectionStorageSnapshot, Never> { changesSubject.eraseToAnyPublisher() }

    func session(id: String) -> PickySessionListViewModel.SessionCard? {
        active.first { $0.id == id } ?? archived.first { $0.id == id }
    }

    func replaceAllSessions(active: [PickySessionListViewModel.SessionCard], archived: [PickySessionListViewModel.SessionCard]) {
        performOperation { steps in
            self.active = active
            capture(&steps, active: true, archived: false)
            self.archived = archived
            capture(&steps, active: false, archived: true)
        }
    }

    func removeSession(id: String) {
        performOperation { steps in
            active.removeAll { $0.id == id }
            capture(&steps, active: true, archived: false)
            archived.removeAll { $0.id == id }
            capture(&steps, active: false, archived: true)
        }
    }

    @discardableResult
    func archiveSession(id: String) -> PickySessionListViewModel.SessionCard? {
        guard let index = active.firstIndex(where: { $0.id == id }) else { return nil }
        let card = active[index]
        performOperation { steps in
            active.remove(at: index)
            capture(&steps, active: true, archived: false)
            if !archived.contains(where: { $0.id == id }) {
                archived.append(card)
                capture(&steps, active: false, archived: true)
            }
            archived = archived.sortedForHUD()
            capture(&steps, active: false, archived: true)
        }
        return card
    }

    @discardableResult
    func unarchiveSession(id: String) -> PickySessionListViewModel.SessionCard? {
        guard let index = archived.firstIndex(where: { $0.id == id }) else { return nil }
        let card = archived[index]
        performOperation { steps in
            archived.remove(at: index)
            capture(&steps, active: false, archived: true)
            if !active.contains(where: { $0.id == id }) {
                active.append(card)
                capture(&steps, active: true, archived: false)
            }
        }
        return card
    }

    func upsertSession(_ card: PickySessionListViewModel.SessionCard, archived shouldArchive: Bool) {
        var steps: [PickySessionProjectionStorageRelay] = []
        PickyPerf.interval("vm_upsert_remove_from_lists") {
            active.removeAll { $0.id == card.id }
            capture(&steps, active: true, archived: false)
            archived.removeAll { $0.id == card.id }
            capture(&steps, active: false, archived: true)
        }
        PickyPerf.interval("vm_upsert_append_to_list") {
            if shouldArchive {
                archived.append(card)
                capture(&steps, active: false, archived: true)
            } else {
                active.append(card)
                capture(&steps, active: true, archived: false)
            }
        }
        PickyPerf.interval("vm_upsert_sort_archived") {
            archived = archived.sortedForHUD()
            capture(&steps, active: false, archived: true)
        }
        publish(steps)
    }

    @discardableResult
    func mutateSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard? {
        guard let index = active.firstIndex(where: { $0.id == sessionID }) else { return nil }
        var card = active[index]
        mutate(&card)
        PickyPerf.interval("vm_update_publish_sessions_subscript") {
            performOperation { steps in
                active[index] = card
                capture(&steps, active: true, archived: false)
            }
        }
        return card
    }

    @discardableResult
    func mutateArchivedSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard? {
        guard let index = archived.firstIndex(where: { $0.id == sessionID }) else { return nil }
        var card = archived[index]
        mutate(&card)
        var steps: [PickySessionProjectionStorageRelay] = []
        PickyPerf.interval("vm_update_publish_archived_subscript") {
            archived[index] = card
            capture(&steps, active: false, archived: true)
        }
        PickyPerf.interval("vm_update_sort_archived") {
            archived = archived.sortedForHUD()
            capture(&steps, active: false, archived: true)
        }
        publish(steps)
        return card
    }

    func applyManualOrder(_ order: [String]) {
        performOperation { steps in
            active = active.sortedByManualOrder(order)
            capture(&steps, active: true, archived: false)
        }
    }

    private func performOperation(_ operation: (inout [PickySessionProjectionStorageRelay]) -> Void) {
        var steps: [PickySessionProjectionStorageRelay] = []
        operation(&steps)
        publish(steps)
    }

    private func publish(_ steps: [PickySessionProjectionStorageRelay]) {
        v1RelaySteps = steps
        changesSubject.send(snapshot())
    }

    private func capture(
        _ steps: inout [PickySessionProjectionStorageRelay],
        active activeChanged: Bool,
        archived archivedChanged: Bool
    ) {
        steps.append(PickySessionProjectionStorageRelay(
            snapshot: snapshot(),
            changesActiveSessions: activeChanged,
            changesArchivedSessions: archivedChanged
        ))
    }

    private func snapshot() -> PickySessionProjectionStorageSnapshot {
        PickySessionProjectionStorageSnapshot(activeSessions: active, archivedSessions: archived)
    }
}
