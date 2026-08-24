//
//  PickyRegistrySessionProjectionStorage.swift
//  Picky
//

import Combine
import Foundation

/// Registry-backed owner for the v1 SessionCard façade.
///
/// Session membership is represented only by registry ID lists and each card is
/// re-materialized from its stable child stores. The Combine stream emits one
/// final snapshot per semantic operation. `v1RelaySteps` is a presentation
/// adapter, isolated from the storage protocol, that retains the façade's
/// historical per-assignment publication boundaries during the W4 cutover.
@MainActor
final class PickyRegistrySessionProjectionStorage: PickySessionProjectionStorageV1Relaying {
    let registry: PickySessionRegistry
    private let changesSubject = PassthroughSubject<PickySessionProjectionStorageSnapshot, Never>()

    private(set) var v1RelaySteps: [PickySessionProjectionStorageRelay] = []
    var activeSessions: [PickySessionListViewModel.SessionCard] { cards(for: registry.activeSessionIDs) }
    var archivedSessions: [PickySessionListViewModel.SessionCard] { cards(for: registry.archivedSessionIDs) }
    var changes: AnyPublisher<PickySessionProjectionStorageSnapshot, Never> { changesSubject.eraseToAnyPublisher() }

    init(registry: PickySessionRegistry? = nil) {
        self.registry = registry ?? PickySessionRegistry()
    }

    func session(id: String) -> PickySessionListViewModel.SessionCard? {
        registry.existingSessionStore(sessionID: id)?.materializedSessionCard()
    }

    func replaceAllSessions(active: [PickySessionListViewModel.SessionCard], archived: [PickySessionListViewModel.SessionCard]) {
        let before = snapshot()
        install(active: active, archived: archived)
        let final = snapshot()
        publish([
            relay(active: final.activeSessions, archived: before.archivedSessions, activeChanged: true, archivedChanged: false),
            relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: false, archivedChanged: true),
        ], final: final)
    }

    func removeSession(id: String) {
        let before = snapshot()
        let active = before.activeSessions.filter { $0.id != id }
        let archived = before.archivedSessions.filter { $0.id != id }
        install(active: active, archived: archived)
        let final = snapshot()
        publish([
            relay(active: final.activeSessions, archived: before.archivedSessions, activeChanged: true, archivedChanged: false),
            relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: false, archivedChanged: true),
        ], final: final)
    }

    @discardableResult
    func archiveSession(id: String) -> PickySessionListViewModel.SessionCard? {
        let before = snapshot()
        guard let index = before.activeSessions.firstIndex(where: { $0.id == id }) else { return nil }
        let card = before.activeSessions[index]
        let active = before.activeSessions.filter { $0.id != id }
        var appendedArchived = before.archivedSessions
        if !appendedArchived.contains(where: { $0.id == id }) {
            appendedArchived.append(card)
        }
        let archived = appendedArchived.sortedForHUD()
        install(active: active, archived: archived)
        let final = snapshot()
        publish([
            relay(active: active, archived: before.archivedSessions, activeChanged: true, archivedChanged: false),
            relay(active: active, archived: appendedArchived, activeChanged: false, archivedChanged: true),
            relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: false, archivedChanged: true),
        ], final: final)
        return card
    }

    @discardableResult
    func unarchiveSession(id: String) -> PickySessionListViewModel.SessionCard? {
        let before = snapshot()
        guard let index = before.archivedSessions.firstIndex(where: { $0.id == id }) else { return nil }
        let card = before.archivedSessions[index]
        let archived = before.archivedSessions.filter { $0.id != id }
        var active = before.activeSessions
        if !active.contains(where: { $0.id == id }) {
            active.append(card)
        }
        install(active: active, archived: archived)
        let final = snapshot()
        publish([
            relay(active: before.activeSessions, archived: archived, activeChanged: false, archivedChanged: true),
            relay(active: active, archived: archived, activeChanged: true, archivedChanged: false),
        ], final: final)
        return card
    }

    func upsertSession(_ card: PickySessionListViewModel.SessionCard, archived shouldArchive: Bool) {
        let before = snapshot()
        let withoutActive = before.activeSessions.filter { $0.id != card.id }
        let withoutArchived = before.archivedSessions.filter { $0.id != card.id }
        let appendedActive = shouldArchive ? withoutActive : withoutActive + [card]
        let appendedArchived = shouldArchive ? withoutArchived + [card] : withoutArchived
        let archived = appendedArchived.sortedForHUD()
        install(active: appendedActive, archived: archived)
        let final = snapshot()
        publish([
            relay(active: withoutActive, archived: before.archivedSessions, activeChanged: true, archivedChanged: false),
            relay(active: withoutActive, archived: withoutArchived, activeChanged: false, archivedChanged: true),
            relay(active: appendedActive, archived: appendedArchived, activeChanged: !shouldArchive, archivedChanged: shouldArchive),
            relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: false, archivedChanged: true),
        ], final: final)
    }

    @discardableResult
    func mutateSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard? {
        let before = snapshot()
        guard let index = before.activeSessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        var card = before.activeSessions[index]
        mutate(&card)
        var active = before.activeSessions
        active[index] = card
        install(active: active, archived: before.archivedSessions)
        let final = snapshot()
        publish([relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: true, archivedChanged: false)], final: final)
        return card
    }

    @discardableResult
    func mutateArchivedSession(
        sessionID: String,
        mutate: (inout PickySessionListViewModel.SessionCard) -> Void
    ) -> PickySessionListViewModel.SessionCard? {
        let before = snapshot()
        guard let index = before.archivedSessions.firstIndex(where: { $0.id == sessionID }) else { return nil }
        var card = before.archivedSessions[index]
        mutate(&card)
        var updatedArchived = before.archivedSessions
        updatedArchived[index] = card
        let archived = updatedArchived.sortedForHUD()
        install(active: before.activeSessions, archived: archived)
        let final = snapshot()
        publish([
            relay(active: before.activeSessions, archived: updatedArchived, activeChanged: false, archivedChanged: true),
            relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: false, archivedChanged: true),
        ], final: final)
        return card
    }

    func applyManualOrder(_ order: [String]) {
        let before = snapshot()
        let active = before.activeSessions.sortedByManualOrder(order)
        install(active: active, archived: before.archivedSessions)
        let final = snapshot()
        publish([relay(active: final.activeSessions, archived: final.archivedSessions, activeChanged: true, archivedChanged: false)], final: final)
    }

    private func install(
        active: [PickySessionListViewModel.SessionCard],
        archived: [PickySessionListViewModel.SessionCard]
    ) {
        for card in active + archived {
            registry.sessionStore(sessionID: card.id).replace(card: card)
        }
        registry.replaceMembership(active: active.map(\.id), archived: archived.map(\.id))
    }

    private func cards(for ids: [String]) -> [PickySessionListViewModel.SessionCard] {
        ids.compactMap { registry.existingSessionStore(sessionID: $0)?.materializedSessionCard() }
    }

    private func snapshot() -> PickySessionProjectionStorageSnapshot {
        PickySessionProjectionStorageSnapshot(activeSessions: activeSessions, archivedSessions: archivedSessions)
    }

    private func relay(
        active: [PickySessionListViewModel.SessionCard],
        archived: [PickySessionListViewModel.SessionCard],
        activeChanged: Bool,
        archivedChanged: Bool
    ) -> PickySessionProjectionStorageRelay {
        PickySessionProjectionStorageRelay(
            snapshot: PickySessionProjectionStorageSnapshot(activeSessions: active, archivedSessions: archived),
            changesActiveSessions: activeChanged,
            changesArchivedSessions: archivedChanged
        )
    }

    private func publish(_ steps: [PickySessionProjectionStorageRelay], final: PickySessionProjectionStorageSnapshot) {
        v1RelaySteps = steps
        changesSubject.send(final)
    }
}
