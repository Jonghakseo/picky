//
//  PickyDockLayout.swift
//  Picky
//
//  Persisted model for user-created Pickle groups in the dock.
//
//  Source-of-truth ordering for the dock is `PickyDockLayout.entries`, which
//  interleaves ungrouped session refs and group definitions top-to-bottom.
//  Each group owns its own ordered `memberSessionIDs`. These types are
//  persisted and mutated by the Picky CLI, so they live outside the HUD.
//  `Picky/HUD/Dock/PickyDockGrouping.swift` projects this layout into the rendered
//  dock tree.
//

import Foundation
import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

/// Group accent palette. Stored as an integer so re-ordering palette entries
/// does not invalidate persisted user choices — only the picker/menu order
/// shifts, never the resolved color for an existing group.
enum PickyDockGroupColor: Int, Codable, CaseIterable, Identifiable {
    case teal = 0
    case amber = 1
    case blue = 2
    case pink = 3
    case purple = 4
    case red = 5
    case gray = 6

    var id: Int { rawValue }

    /// Default color for newly created groups. Neutral gray so color-sensitive
    /// users get a predictable swatch instead of a random/rotating accent.
    static let defaultColor: PickyDockGroupColor = .gray

    /// 7-color palette in picker/menu display order (matches Notion's order:
    /// gray, amber, teal, blue, purple, pink, red).
    static var palette: [PickyDockGroupColor] {
        [.gray, .amber, .teal, .blue, .purple, .pink, .red]
    }

    /// Solid accent color used for the folder tile.
    var accent: Color {
        switch self {
        case .teal:   DS.GroupAccent.teal
        case .amber:  DS.GroupAccent.amber
        case .blue:   DS.GroupAccent.blue
        case .pink:   DS.GroupAccent.pink
        case .purple: DS.GroupAccent.purple
        case .red:    DS.GroupAccent.red
        case .gray:   DS.GroupAccent.gray
        }
    }

    /// Display name for the color picker submenu.
    /// Localized display name for the color picker submenu.
    var localizedName: String {
        switch self {
        case .teal:   L10n.t("group.color.teal")
        case .amber:  L10n.t("group.color.amber")
        case .blue:   L10n.t("group.color.blue")
        case .pink:   L10n.t("group.color.pink")
        case .purple: L10n.t("group.color.purple")
        case .red:    L10n.t("group.color.red")
        case .gray:   L10n.t("group.color.gray")
        }
    }

    #if canImport(AppKit)
    /// Small rounded-square swatch in the accent color, shown beside each
    /// entry in the color picker submenu. Matches the dock group header.
    var menuSwatchImage: NSImage {
        let diameter: CGFloat = 10
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(accent).setFill()
        NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: 2.5, yRadius: 2.5).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
    #endif
}

/// A single user-created group in the dock. Membership order matches the
/// rendered vertical (or horizontal) order inside the group.
struct PickyDockGroup: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var colorRaw: Int
    var memberSessionIDs: [String]
    var isCollapsed: Bool

    var color: PickyDockGroupColor {
        get { PickyDockGroupColor(rawValue: colorRaw) ?? .teal }
        set { colorRaw = newValue.rawValue }
    }

    init(
        id: String = UUID().uuidString,
        name: String = "",
        color: PickyDockGroupColor = .defaultColor,
        memberSessionIDs: [String] = [],
        isCollapsed: Bool = true
    ) {
        self.id = id
        self.name = name
        self.colorRaw = color.rawValue
        self.memberSessionIDs = memberSessionIDs
        self.isCollapsed = isCollapsed
    }

    /// Display name with sensible fallback when the user hasn't named the
    /// group yet (e.g. brand new from `+ → New Group` with focus pulled away
    /// before they typed anything).
    var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }
}

/// One slot in the dock's top-level layout. `session` is an ungrouped Pickle;
/// `group` is a user-created bucket that may contain zero or more Pickles.
enum PickyDockEntry: Codable, Equatable {
    case session(id: String)
    case group(PickyDockGroup)

    private enum Kind: String, Codable { case session, group }
    private enum CodingKeys: String, CodingKey { case kind, id, group }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let id):
            try c.encode(Kind.session, forKey: .kind)
            try c.encode(id, forKey: .id)
        case .group(let group):
            try c.encode(Kind.group, forKey: .kind)
            try c.encode(group, forKey: .group)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .session: self = .session(id: try c.decode(String.self, forKey: .id))
        case .group:   self = .group(try c.decode(PickyDockGroup.self, forKey: .group))
        }
    }
}

/// Persisted dock layout — the canonical ordering of icons and group
/// containers shown in the rail. Top of the dock = `entries.first`,
/// bottom of the dock = `entries.last` (closest to the `+` slot).
struct PickyDockLayout: Codable, Equatable {
    var entries: [PickyDockEntry]

    static let empty = PickyDockLayout(entries: [])

    init(entries: [PickyDockEntry] = []) {
        self.entries = entries
    }
}

// MARK: - Mutation helpers

extension PickyDockLayout {
    /// All groups present in the layout, in top-to-bottom order.
    var groups: [PickyDockGroup] {
        entries.compactMap {
            if case .group(let g) = $0 { return g }
            return nil
        }
    }

    /// Set of every session id known to the layout (top-level or grouped).
    var allKnownSessionIDs: Set<String> {
        var ids: Set<String> = []
        for entry in entries {
            switch entry {
            case .session(let id): ids.insert(id)
            case .group(let g):    ids.formUnion(g.memberSessionIDs)
            }
        }
        return ids
    }

    /// Find which container a session currently lives in. Returns `nil`
    /// when the session is unknown to the layout (e.g. a brand-new Pickle
    /// that has not been reconciled in yet).
    func container(forSessionID id: String) -> PickyDockContainer? {
        for (idx, entry) in entries.enumerated() {
            switch entry {
            case .session(let sid) where sid == id:
                return .topLevel(index: idx)
            case .group(let g):
                if let memberIdx = g.memberSessionIDs.firstIndex(of: id) {
                    return .group(id: g.id, memberIndex: memberIdx)
                }
            default: break
            }
        }
        return nil
    }

    func group(withID id: String) -> PickyDockGroup? {
        for entry in entries {
            if case .group(let g) = entry, g.id == id { return g }
        }
        return nil
    }

    /// Screen-local presentation copy. Never persist this over the shared layout:
    /// group membership, ordering, names and colors still belong to every display.
    func applyingGroupCollapseOverrides(_ overrides: [String: Bool]) -> PickyDockLayout {
        guard !overrides.isEmpty else { return self }
        var next = self
        for index in next.entries.indices {
            guard case var .group(group) = next.entries[index],
                  let collapsed = overrides[group.id] else { continue }
            group.isCollapsed = collapsed
            next.entries[index] = .group(group)
        }
        return next
    }

    /// Every group expanded, for the list dock's one-time migration away from
    /// the folder dock, which persisted all groups as collapsed.
    func expandingAllGroups() -> PickyDockLayout {
        var next = self
        for index in next.entries.indices {
            guard case var .group(group) = next.entries[index] else { continue }
            group.isCollapsed = false
            next.entries[index] = .group(group)
        }
        return next
    }

    /// Drop any session id no longer present in `universe` from both
    /// top-level entries and every group's member list. Returns `true`
    /// when any change was applied.
    ///
    /// `retainedGroupMemberIDs` are kept inside their groups even when absent
    /// from `universe`. This preserves group membership for archived Pickles
    /// (which leave the active session universe) so restoring one returns it
    /// to its original group/position instead of leaking out to the top
    /// level. Retention applies to group members only — a top-level archived
    /// Pickle still follows the existing prune-and-reappend behavior.
    @discardableResult
    mutating func pruneUnknownSessions(
        universe: Set<String>,
        retainedGroupMemberIDs: Set<String> = []
    ) -> Bool {
        var changed = false
        var newEntries: [PickyDockEntry] = []
        newEntries.reserveCapacity(entries.count)
        for entry in entries {
            switch entry {
            case .session(let id):
                if universe.contains(id) {
                    newEntries.append(entry)
                } else {
                    changed = true
                }
            case .group(var g):
                let before = g.memberSessionIDs.count
                g.memberSessionIDs.removeAll {
                    !universe.contains($0) && !retainedGroupMemberIDs.contains($0)
                }
                if g.memberSessionIDs.count != before { changed = true }
                newEntries.append(.group(g))
            }
        }
        if changed { entries = newEntries }
        return changed
    }

    /// Append a brand-new session at the bottom of the dock (= end of the
    /// top-level entries array). No-op when already known.
    @discardableResult
    mutating func appendNewSessionIfMissing(_ id: String) -> Bool {
        if allKnownSessionIDs.contains(id) { return false }
        entries.append(.session(id: id))
        return true
    }

    /// Remove a session from wherever it lives (top-level or group). When
    /// the session sits inside a group, the group is preserved even if it
    /// becomes empty — empty groups remain visible so the user can still
    /// drop more pickles into them, or delete them explicitly.
    @discardableResult
    mutating func removeSession(_ id: String) -> PickyDockContainer? {
        for (idx, entry) in entries.enumerated() {
            switch entry {
            case .session(let sid) where sid == id:
                entries.remove(at: idx)
                return .topLevel(index: idx)
            case .group(var g):
                if let memberIdx = g.memberSessionIDs.firstIndex(of: id) {
                    g.memberSessionIDs.remove(at: memberIdx)
                    entries[idx] = .group(g)
                    return .group(id: g.id, memberIndex: memberIdx)
                }
            default: break
            }
        }
        return nil
    }

    /// Insert a session at the given container/position. Caller is
    /// responsible for removing the session from its previous location
    /// first (use `move(session:to:)` for safe atomic moves).
    mutating func insertSession(_ id: String, into destination: PickyDockContainer) {
        switch destination {
        case .topLevel(let index):
            let clamped = max(0, min(entries.count, index))
            entries.insert(.session(id: id), at: clamped)
        case .group(let groupID, let memberIndex):
            for (idx, entry) in entries.enumerated() {
                if case .group(var g) = entry, g.id == groupID {
                    let clamped = max(0, min(g.memberSessionIDs.count, memberIndex))
                    g.memberSessionIDs.insert(id, at: clamped)
                    entries[idx] = .group(g)
                    return
                }
            }
            // Unknown group id → fall back to top-level append so the
            // session is not silently lost.
            entries.append(.session(id: id))
        }
    }

    /// Atomic move of a session from its current container to `destination`.
    /// `destination` is interpreted as the desired *final* address inside
    /// the post-move layout, matching the drag UX expectation "drop where
    /// the cursor points". When source and target containers are the same
    /// and the source sits above the target, the index is bumped by one
    /// so the post-remove insertion still lands on the requested slot.
    mutating func move(session id: String, to destination: PickyDockContainer) {
        let origin = container(forSessionID: id)
        _ = removeSession(id)
        let adjusted: PickyDockContainer = {
            guard let origin else { return destination }
            switch (origin, destination) {
            case (.topLevel(let from), .topLevel(let to)) where from <= to:
                return .topLevel(index: to)
            case (.group(let oid, let from), .group(let did, let to))
                where oid == did && from <= to:
                return .group(id: did, memberIndex: to)
            default:
                return destination
            }
        }()
        insertSession(id, into: adjusted)
    }

    /// Update a single group in place by id. No-op when not found.
    mutating func updateGroup(id: String, transform: (inout PickyDockGroup) -> Void) {
        for (idx, entry) in entries.enumerated() {
            if case .group(var g) = entry, g.id == id {
                transform(&g)
                entries[idx] = .group(g)
                return
            }
        }
    }

    /// Remove the group with the given id. When `keepMembers` is true the
    /// members are spliced back into the top-level layout at the group's
    /// previous position (the "Ungroup" action). When false, members are
    /// also removed and the caller is expected to archive the underlying
    /// sessions ("Delete group + archive pickles").
    @discardableResult
    mutating func removeGroup(id: String, keepMembers: Bool) -> [String] {
        for (idx, entry) in entries.enumerated() {
            if case .group(let g) = entry, g.id == id {
                entries.remove(at: idx)
                if keepMembers {
                    let inserts = g.memberSessionIDs.map { PickyDockEntry.session(id: $0) }
                    entries.insert(contentsOf: inserts, at: idx)
                    return []
                } else {
                    return g.memberSessionIDs
                }
            }
        }
        return []
    }

    /// Reorder a group within the top-level entries. `target` is the
    /// desired *final* position of the group in `entries`, matching the
    /// header-drag UX ("drop where my cursor points"). The model removes
    /// the group from its current slot first, then inserts at `target`
    /// clamped to the post-removal bounds, so the final array length is
    /// preserved and the group lands at the requested visual position
    /// regardless of move direction. No-op when the group does not exist.
    mutating func moveGroup(id: String, toTopLevelIndex target: Int) {
        var removedEntry: PickyDockEntry?
        for (idx, entry) in entries.enumerated() {
            if case .group(let g) = entry, g.id == id {
                removedEntry = entry
                entries.remove(at: idx)
                break
            }
        }
        guard let removedEntry else { return }
        let clamped = max(0, min(entries.count, target))
        entries.insert(removedEntry, at: clamped)
    }
}
