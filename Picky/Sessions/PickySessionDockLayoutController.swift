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
    func reconcile(activeSessionIDs: [String], legacyManualOrder: [String]) -> Bool {
        let universe = Set(activeSessionIDs)
        var next = layout
        var changed = next.pruneUnknownSessions(universe: universe)

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
        let nextColor = PickyDockGroupColor.nextColor(forExistingGroupCount: layout.groups.count)
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
            color: nextColor,
            memberSessionIDs: orderedMembers
        )
        next.entries.append(.group(group))
        _ = apply(next, changed: next != layout)
        return group.id
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

    @discardableResult
    func moveSession(sessionID: String, to destination: PickyDockContainer) -> Bool {
        var next = layout
        next.move(session: sessionID, to: destination)
        return apply(next, changed: next != layout)
    }

    @discardableResult
    func moveGroup(id: String, toTopLevelIndex target: Int) -> Bool {
        var next = layout
        next.moveGroup(id: id, toTopLevelIndex: target)
        return apply(next, changed: next != layout)
    }

    @discardableResult
    private func apply(_ next: PickyDockLayout, changed: Bool) -> Bool {
        guard changed else { return false }
        layout = next
        persist()
        return true
    }

    private func persist() {
        do {
            try store.save(layout)
        } catch {
            onSaveError(error)
        }
    }
}
