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

    init(
        store: PickyDockLayoutStoring,
        onSaveError: @escaping (Error) -> Void = { _ in }
    ) {
        self.store = store
        self.onSaveError = onSaveError
        self.layout = store.load()
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

    @discardableResult
    func createGroup(name: String = "", withMemberIDs memberSessionIDs: [String] = []) -> String {
        let mutation = groupCreation(name: name, memberSessionIDs: memberSessionIDs)
        _ = apply(mutation.layout, changed: mutation.layout != layout)
        return mutation.groupID
    }

    /// Main-agent group mutations must not report success until the durable
    /// dock layout write succeeds. Unlike the UI path above, a save error
    /// leaves the published controller layout unchanged and propagates.
    func createGroupPersisting(name: String, withMemberIDs memberSessionIDs: [String]) throws -> String {
        let mutation = groupCreation(name: name, memberSessionIDs: memberSessionIDs)
        _ = try applyPersisting(mutation.layout, changed: mutation.layout != layout)
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

    func removeGroupPersisting(id: String, keepMembers: Bool) throws -> [String] {
        var next = layout
        let removedMemberIDs = next.removeGroup(id: id, keepMembers: keepMembers)
        _ = try applyPersisting(next, changed: next != layout)
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
    func addSessionsPersisting(_ sessionIDs: [String], toGroup groupID: String) throws -> Bool {
        var next = layout
        for sessionID in sessionIDs {
            let memberIndex = next.group(withID: groupID)?.memberSessionIDs.count ?? 0
            next.move(session: sessionID, to: .group(id: groupID, memberIndex: memberIndex))
        }
        return try applyPersisting(next, changed: next != layout)
    }

    /// Move validated members out of a group to the bottom of the top-level
    /// dock while preserving the request order. Pickles remain active.
    @discardableResult
    func removeSessionsFromGroupPersisting(_ sessionIDs: [String]) throws -> Bool {
        var next = layout
        for sessionID in sessionIDs {
            next.move(session: sessionID, to: .topLevel(index: next.entries.count))
        }
        return try applyPersisting(next, changed: next != layout)
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
        guard changed else { return false }
        layout = next
        persist()
        return true
    }

    @discardableResult
    private func applyPersisting(_ next: PickyDockLayout, changed: Bool) throws -> Bool {
        guard changed else { return false }
        do {
            try store.save(next)
            layout = next
            return true
        } catch {
            onSaveError(error)
            throw error
        }
    }

    private func persist() {
        do {
            try store.save(layout)
        } catch {
            onSaveError(error)
        }
    }
}
