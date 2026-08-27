//
//  PickySessionDockLayoutController.swift
//  Picky
//
//  Owns persisted dock layout mutation/persistence for the session list
//  facade. The ViewModel remains the ObservableObject and side-effect owner;
//  this controller keeps group/order policy changes small and testable.
//

import Foundation

@MainActor
final class PickySessionDockLayoutController {
    private let store: PickyDockLayoutStoring
    private let onSaveError: (Error) -> Void

    private(set) var layout: PickyDockLayout
    /// Monotonic admission revision prevents an awaited durable mutation from
    /// publishing over a newer UI or CLI mutation admitted while suspended.
    private var layoutRevision: UInt64 = 0

    init(
        store: PickyDockLayoutStoring,
        onSaveError: @escaping (Error) -> Void = { _ in }
    ) {
        self.store = store
        self.onSaveError = onSaveError
        let loaded = store.load()
        let normalized = loaded.normalizedForFolderRail()
        self.layout = normalized
        // Legacy expanded groups are no longer a durable UI state. Persist the
        // all-closed migration during load so disk matches runtime immediately.
        if normalized != loaded {
            store.enqueueSave(normalized) { result in
                if case .failure(let error) = result { onSaveError(error) }
            }
        }
    }

    /// Keep layout entries aligned with active session IDs. Active IDs are
    /// newest-first, while dock layout entries are top-to-bottom. Brand-new
    /// sessions are therefore appended by iterating the active list in reverse
    /// so the newest session lands at the visual bottom/end slot.
    @discardableResult
    func reconcile(
        activeSessionIDs: [String],
        archivedSessionIDs: [String] = [],
        legacyManualOrder: [String]
    ) -> Bool {
        let universe = Set(activeSessionIDs)
        var next = layout
        // Archived Pickles leave the active universe but are still known, so
        // keep them inside their group to survive an archive/restore cycle.
        var changed = next.pruneUnknownSessions(
            universe: universe,
            retainedGroupMemberIDs: Set(archivedSessionIDs)
        )

        if next.entries.isEmpty && !legacyManualOrder.isEmpty {
            for sessionID in legacyManualOrder.reversed() where universe.contains(sessionID) {
                if next.appendNewSessionIfMissing(sessionID) {
                    changed = true
                }
            }
        }

        for sessionID in activeSessionIDs.reversed() {
            if next.appendNewSessionIfMissing(sessionID) {
                changed = true
            }
        }

        return apply(next, changed: changed)
    }

    /// Admit one active session without pruning other persisted IDs. V2
    /// bootstrap snapshots arrive one session at a time, so IDs absent from
    /// the registry at this moment are not evidence that they are stale.
    @discardableResult
    func admitActiveSessionIfMissing(_ sessionID: String) -> Bool {
        var next = layout
        let changed = next.appendNewSessionIfMissing(sessionID)
        return apply(next, changed: changed)
    }

    @discardableResult
    func createGroup(name: String = "", withMemberIDs memberSessionIDs: [String] = []) -> String {
        let mutation = groupCreation(name: name, memberSessionIDs: memberSessionIDs)
        _ = apply(mutation.layout, changed: mutation.layout != layout)
        return mutation.groupID
    }

    /// Main-agent group mutations must not report success until the durable
    /// dock layout write succeeds. Their layout is reserved synchronously so
    /// later UI mutations derive from it; a save error still propagates.
    func createGroupPersisting(name: String, withMemberIDs memberSessionIDs: [String]) async throws -> String {
        let mutation = groupCreation(name: name, memberSessionIDs: memberSessionIDs)
        _ = try await applyPersisting(mutation.layout, changed: mutation.layout != layout)
        return mutation.groupID
    }

    @discardableResult
    func renameGroup(id: String, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = layout
        next.updateGroup(id: id) { $0.name = trimmed }
        return apply(next, changed: next != layout)
    }

    @discardableResult
    func setGroupColor(id: String, color: PickyDockGroupColor) -> Bool {
        var next = layout
        next.updateGroup(id: id) { $0.color = color }
        return apply(next, changed: next != layout)
    }

    @discardableResult
    func removeGroup(id: String, keepMembers: Bool) -> [String] {
        var next = layout
        let removedMemberIDs = next.removeGroup(id: id, keepMembers: keepMembers)
        _ = apply(next, changed: next != layout)
        return removedMemberIDs
    }

    func removeGroupPersisting(id: String, keepMembers: Bool) async throws -> [String] {
        var next = layout
        let removedMemberIDs = next.removeGroup(id: id, keepMembers: keepMembers)
        _ = try await applyPersisting(next, changed: next != layout)
        return removedMemberIDs
    }

    @discardableResult
    func moveSession(sessionID: String, to destination: PickyDockContainer) -> Bool {
        var next = layout
        next.move(session: sessionID, to: destination)
        return apply(next, changed: next != layout)
    }

    /// Move a validated set of sessions to the end of one group and persist
    /// the whole mutation once. This is the programmatic counterpart to the
    /// dock's per-session drag path and shares the same layout primitive.
    @discardableResult
    func addSessionsPersisting(_ sessionIDs: [String], toGroup groupID: String) async throws -> Bool {
        var next = layout
        for sessionID in sessionIDs {
            let memberIndex = next.group(withID: groupID)?.memberSessionIDs.count ?? 0
            next.move(session: sessionID, to: .group(id: groupID, memberIndex: memberIndex))
        }
        return try await applyPersisting(next, changed: next != layout)
    }

    /// Move validated members out of a group to the bottom of the top-level
    /// dock while preserving the request order. Pickles remain active.
    @discardableResult
    func removeSessionsFromGroupPersisting(_ sessionIDs: [String]) async throws -> Bool {
        var next = layout
        for sessionID in sessionIDs {
            next.move(session: sessionID, to: .topLevel(index: next.entries.count))
        }
        return try await applyPersisting(next, changed: next != layout)
    }

    @discardableResult
    func moveGroup(id: String, toTopLevelIndex target: Int) -> Bool {
        var next = layout
        next.moveGroup(id: id, toTopLevelIndex: target)
        return apply(next, changed: next != layout)
    }

    private func groupCreation(name: String, memberSessionIDs: [String]) -> (layout: PickyDockLayout, groupID: String) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        var next = layout
        var orderedMembers: [String] = []
        var seen = Set<String>()
        for memberID in memberSessionIDs where !seen.contains(memberID) {
            seen.insert(memberID)
            _ = next.removeSession(memberID)
            orderedMembers.append(memberID)
        }
        let group = PickyDockGroup(
            name: trimmedName,
            color: PickyDockGroupColor.defaultColor,
            memberSessionIDs: orderedMembers
        )
        next.entries.append(.group(group))
        return (next, group.id)
    }

    @discardableResult
    private func apply(_ next: PickyDockLayout, changed: Bool) -> Bool {
        let normalized = next.normalizedForFolderRail()
        let didChange = changed || normalized != layout
        guard didChange else { return false }
        layoutRevision &+= 1
        layout = normalized
        persist()
        return true
    }

    @discardableResult
    private func applyPersisting(_ next: PickyDockLayout, changed: Bool) async throws -> Bool {
        let normalized = next.normalizedForFolderRail()
        let didChange = changed || normalized != layout
        guard didChange else { return false }

        // `saveDurably` enters the same FIFO as UI persistence, but awaiting
        // it yields the main actor. Publish before that yield so every later
        // mutation starts from this accepted layout rather than a stale one.
        let previousLayout = layout
        layoutRevision &+= 1
        let admissionRevision = layoutRevision
        layout = normalized

        do {
            try await store.saveDurably(normalized)
            return true
        } catch {
            // A later accepted mutation was derived from `normalized` and has
            // already captured the composite layout for the FIFO. Reverting it
            // here would discard that later mutation. Only roll back when this
            // failed admission is still the current revision.
            if layoutRevision == admissionRevision {
                layout = previousLayout
            }
            onSaveError(error)
            throw error
        }
    }

    private func persist() {
        store.enqueueSave(layout) { [weak self] result in
            guard case .failure(let error) = result else { return }
            self?.onSaveError(error)
        }
    }
}
