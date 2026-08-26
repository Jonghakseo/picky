//
//  PickyDockGrouping.swift
//  Picky
//
//  Models + layout for user-created Pickle groups in the dock rail.
//
//  Source-of-truth ordering for the dock is `PickyDockLayout.entries`, which
//  interleaves ungrouped session refs and group definitions top-to-bottom.
//  Each group owns its own ordered `memberSessionIDs`. The HUD projects
//  `visibleSessions` (which agentd authorities own) through this layout to
//  build the rendered dock tree.
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
    /// Small filled-circle swatch (macOS Finder-label style) in the accent
    /// color, shown beside each entry in the color picker submenu.
    var menuSwatchImage: NSImage {
        let diameter: CGFloat = 10
        let size = NSSize(width: diameter, height: diameter)
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor(accent).setFill()
        NSBezierPath(ovalIn: NSRect(origin: .zero, size: size)).fill()
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

    /// Converts legacy expand/collapse persistence to the folder-only rail.
    /// List-open state is display-local and transient, so every loaded group
    /// returns to the persisted resting state with members not displayed.
    func normalizedForFolderRail() -> PickyDockLayout {
        var normalized = self
        for index in normalized.entries.indices {
            guard case var .group(group) = normalized.entries[index] else { continue }
            group.isCollapsed = true
            normalized.entries[index] = .group(group)
        }
        return normalized
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

/// Logical address of an icon (or icon slot) inside the dock layout.
/// `.topLevel(index)` means "ungrouped slot at top-level position `index`".
/// `.group(id, memberIndex)` means "inside group `id` at member position".
enum PickyDockContainer: Equatable {
    case topLevel(index: Int)
    case group(id: String, memberIndex: Int)
}

// MARK: - Render projection

/// One top-level entry rendered in the dock rail. Groups always render as a
/// single folder tile, regardless of their stored legacy `isCollapsed` value.
enum PickyDockRenderItem: Equatable {
    case session(id: String)
    case group(PickyDockGroup)

    /// Stable SwiftUI identity. Top-level moves must not replace the view that
    /// owns an in-flight drag, completion animation, or archive hold.
    var stableID: String {
        switch self {
        case .session(let id): "session:\(id)"
        case .group(let group): "group:\(group.id)"
        }
    }
}

/// A keyboard/drag target for a top-level rail slot. Unlike the old model, a
/// folder never borrows one of its members' identity or shortcut number.
enum PickyDockSlotTarget: Equatable {
    case session(id: String, container: PickyDockContainer)
    case group(id: String)
}

/// Per-top-level position record for shortcut numbering and drag hit-testing.
struct PickyDockSlot: Equatable {
    let target: PickyDockSlotTarget
    /// 0-based axis position. This is the index `⌘N` maps to.
    let visibleIndex: Int

    var sessionID: String? {
        guard case let .session(id, _) = target else { return nil }
        return id
    }

    var groupID: String? {
        guard case let .group(id) = target else { return nil }
        return id
    }

    var container: PickyDockContainer? {
        guard case let .session(_, container) = target else { return nil }
        return container
    }
}

/// Result of projecting the persisted layout against the currently-visible
/// session universe. Every top-level entry, including an empty group, owns one
/// render item and one slot.
struct PickyDockProjection: Equatable {
    var items: [PickyDockRenderItem]
    var slots: [PickyDockSlot]

    static let empty = PickyDockProjection(items: [], slots: [])

    /// The top-level rail item that contains a session. Grouped sessions must
    /// reveal their folder rather than attempting to scroll to a hidden row.
    func scrollTargetID(forSessionID sessionID: String) -> String? {
        if items.contains(.session(id: sessionID)) { return "session:\(sessionID)" }
        for item in items {
            guard case .group(let group) = item,
                  group.memberSessionIDs.contains(sessionID)
            else { continue }
            return "group:\(group.id)"
        }
        return nil
    }
}

enum PickyDockProjector {
    /// Build the folder-only rail plan. `isCollapsed` remains persisted for CLI
    /// compatibility, but is intentionally ignored while rendering.
    static func project(
        layout: PickyDockLayout,
        visibleSessionIDs: [String]
    ) -> PickyDockProjection {
        let visibleSet = Set(visibleSessionIDs)
        var items: [PickyDockRenderItem] = []
        var slots: [PickyDockSlot] = []
        var seen: Set<String> = []
        var slotIndex = 0

        for (layoutIndex, entry) in layout.entries.enumerated() {
            switch entry {
            case .session(let id):
                guard visibleSet.contains(id) else { continue }
                items.append(.session(id: id))
                slots.append(PickyDockSlot(
                    target: .session(id: id, container: .topLevel(index: layoutIndex)),
                    visibleIndex: slotIndex
                ))
                seen.insert(id)
                slotIndex += 1
            case .group(let group):
                items.append(.group(group))
                slots.append(PickyDockSlot(target: .group(id: group.id), visibleIndex: slotIndex))
                seen.formUnion(group.memberSessionIDs.filter { visibleSet.contains($0) })
                slotIndex += 1
            }
        }

        // Brand-new sessions not yet reconciled into the layout land at the
        // bottom-end so the visual ordering matches the user expectation.
        for id in visibleSessionIDs where !seen.contains(id) {
            items.append(.session(id: id))
            slots.append(PickyDockSlot(
                target: .session(id: id, container: .topLevel(index: layout.entries.count)),
                visibleIndex: slotIndex
            ))
            slotIndex += 1
        }

        return PickyDockProjection(items: items, slots: slots)
    }

    /// Active Pickles in persisted dock order for the cycle shortcut. Groups
    /// contribute their stored member order, then active Pickles missing from
    /// the layout are appended in the caller's fallback order.
    static func cycleSessionIDs(layout: PickyDockLayout, activeSessionIDs: [String]) -> [String] {
        let activeSet = Set(activeSessionIDs)
        var result: [String] = []
        var seen: Set<String> = []
        func appendIfActive(_ id: String) {
            guard activeSet.contains(id), seen.insert(id).inserted else { return }
            result.append(id)
        }
        for entry in layout.entries {
            switch entry {
            case .session(let id): appendIfActive(id)
            case .group(let group): group.memberSessionIDs.forEach(appendIfActive)
            }
        }
        activeSessionIDs.forEach(appendIfActive)
        return result
    }
}

// MARK: - Drag drop resolution

/// Pure resolver for "where would the dragged Pickle land right now?" given the
/// frozen drag-start geometry. Extracted from the HUD so the drop decision —
/// including the group-edge escape behavior — can be unit-tested without the
/// SwiftUI view.
enum PickyDockDropResolver {
    /// A real (session) drop slot and its measured primary-axis center.
    struct SlotCandidate: Equatable {
        let container: PickyDockContainer
        let center: CGFloat
    }

    /// A top-level insertion boundary between two adjacent rendered entries.
    /// Folder-only rails need these explicit candidates because groups do not
    /// expose session slot containers of their own.
    struct TopLevelInsertionCandidate: Equatable {
        let topLevelIndex: Int
        let center: CGFloat
    }

    /// A group folder tile and its center. Dropping here inserts into that
    /// group's members.
    struct EmptyGroupCandidate: Equatable {
        let groupID: String
        /// Full stored member index, translated from the folder's visible
        /// insertion position so archived members keep their relative order.
        let memberIndex: Int
        let center: CGFloat
        /// Exact visible badge half extent on the rail's primary axis. `nil`
        /// retains the resolver fallback for non-rail callers and older tests.
        let halfExtent: CGFloat?

        init(
            groupID: String,
            memberIndex: Int = 0,
            center: CGFloat,
            halfExtent: CGFloat? = nil
        ) {
            self.groupID = groupID
            self.memberIndex = memberIndex
            self.center = center
            self.halfExtent = halfExtent
        }
    }

    /// Resolve the prospective drop container for a Pickle dragged to
    /// `cursorAxis` (primary-axis position). Returns nil only when there are
    /// no candidates at all.
    ///
    /// The nearest candidate center wins. Group candidates are bounded to the
    /// rendered folder tile: crossing an edge folder's outer bound creates a
    /// top-level insertion before/after it instead of extending the folder drop
    /// zone infinitely beyond the dock.
    static func resolveDropContainer(
        draggedSessionID: String,
        cursorAxis: CGFloat,
        slotCandidates: [SlotCandidate],
        topLevelInsertionCandidates: [TopLevelInsertionCandidate] = [],
        emptyGroupCandidates: [EmptyGroupCandidate],
        nonEmptyGroupCandidates: [EmptyGroupCandidate] = [],
        layout: PickyDockLayout,
        slotPitch: CGFloat,
        groupDropHalfExtent: CGFloat? = nil
    ) -> PickyDockContainer? {
        var nearest: PickyDockContainer?
        var minDistance = CGFloat.infinity
        let groupCandidates = emptyGroupCandidates + nonEmptyGroupCandidates
        let resolvedGroupDropHalfExtent = max(0, groupDropHalfExtent ?? slotPitch * 0.5)
        func halfExtent(for candidate: EmptyGroupCandidate) -> CGFloat {
            max(0, candidate.halfExtent ?? resolvedGroupDropHalfExtent)
        }

        for candidate in slotCandidates {
            let distance = abs(candidate.center - cursorAxis)
            if distance < minDistance {
                minDistance = distance
                nearest = candidate.container
            }
        }

        for candidate in topLevelInsertionCandidates {
            let distance = abs(candidate.center - cursorAxis)
            if distance < minDistance {
                minDistance = distance
                nearest = .topLevel(index: candidate.topLevelIndex)
            }
        }

        // The visible folder badge is an explicit acceptance surface. Once the
        // pointer is inside it, grouping wins over a nearby linear boundary so
        // the target does not flip at the badge edge.
        var containedGroup: (candidate: EmptyGroupCandidate, distance: CGFloat)?
        for candidate in groupCandidates {
            let distance = abs(candidate.center - cursorAxis)
            guard distance <= halfExtent(for: candidate) else { continue }
            if containedGroup == nil || distance < containedGroup!.distance {
                containedGroup = (candidate, distance)
            }
        }
        if let containedGroup {
            minDistance = containedGroup.distance
            nearest = .group(
                id: containedGroup.candidate.groupID,
                memberIndex: containedGroup.candidate.memberIndex
            )
        }

        // Retain the member-edge resolver for list-row reordering. Rail folder
        // tiles themselves are represented by `EmptyGroupCandidate` above.
        if let edgeInsertion = resolveGroupEdgeInsertion(
            draggedSessionID: draggedSessionID,
            cursorAxis: cursorAxis,
            slotCandidates: slotCandidates,
            layout: layout,
            edgeMargin: slotPitch * 0.4
        ) {
            nearest = edgeInsertion
        }

        let realCenters = slotCandidates.map(\.center)
        let minCenter = realCenters.min()
        let maxCenter = realCenters.max()
        let escapeMargin = slotPitch * 0.6

        switch layout.entries.first {
        case .group(let group):
            if let candidate = groupCandidates.first(where: { $0.groupID == group.id }),
               cursorAxis < candidate.center - halfExtent(for: candidate) {
                nearest = .topLevel(index: 0)
            } else if groupCandidates.first(where: { $0.groupID == group.id }) == nil,
                      let minCenter,
                      cursorAxis < minCenter - escapeMargin,
                      canEscapePastEdge(layout.entries.first, draggedSessionID: draggedSessionID) {
                nearest = .topLevel(index: 0)
            }
        case .session, nil:
            if let minCenter,
               cursorAxis < minCenter - escapeMargin,
               canEscapePastEdge(layout.entries.first, draggedSessionID: draggedSessionID) {
                nearest = .topLevel(index: 0)
            }
        }

        switch layout.entries.last {
        case .group(let group):
            if let candidate = groupCandidates.first(where: { $0.groupID == group.id }),
               cursorAxis > candidate.center + halfExtent(for: candidate) {
                nearest = .topLevel(index: layout.entries.count)
            } else if groupCandidates.first(where: { $0.groupID == group.id }) == nil,
                      let maxCenter,
                      cursorAxis > maxCenter + escapeMargin,
                      canEscapePastEdge(layout.entries.last, draggedSessionID: draggedSessionID) {
                nearest = .topLevel(index: layout.entries.count)
            }
        case .session, nil:
            if let maxCenter,
               cursorAxis > maxCenter + escapeMargin,
               canEscapePastEdge(layout.entries.last, draggedSessionID: draggedSessionID) {
                nearest = .topLevel(index: layout.entries.count)
            }
        }

        return nearest
    }

    private static func resolveGroupEdgeInsertion(
        draggedSessionID: String,
        cursorAxis: CGFloat,
        slotCandidates: [SlotCandidate],
        layout: PickyDockLayout,
        edgeMargin: CGFloat
    ) -> PickyDockContainer? {
        struct GroupSlot {
            let memberIndex: Int
            let center: CGFloat
        }

        var slotsByGroupID: [String: [GroupSlot]] = [:]
        for candidate in slotCandidates {
            guard case .group(let groupID, let memberIndex) = candidate.container else { continue }
            slotsByGroupID[groupID, default: []].append(.init(
                memberIndex: memberIndex,
                center: candidate.center
            ))
        }

        var best: (container: PickyDockContainer, distance: CGFloat)?
        func consider(_ container: PickyDockContainer, distance: CGFloat) {
            guard distance >= 0 else { return }
            if best == nil || distance < best!.distance {
                best = (container, distance)
            }
        }

        for (groupID, slots) in slotsByGroupID {
            guard let group = layout.group(withID: groupID) else { continue }
            let sorted = slots.sorted { $0.center < $1.center }
            guard let first = sorted.first, let last = sorted.last else { continue }
            let isDraggedMember = group.memberSessionIDs.contains(draggedSessionID)
            let isFirstEntry = isGroup(layout.entries.first, id: groupID)
            let isLastEntry = isGroup(layout.entries.last, id: groupID)

            if cursorAxis < first.center,
               cursorAxis >= first.center - edgeMargin || (isFirstEntry && !isDraggedMember) {
                consider(.group(id: groupID, memberIndex: 0), distance: first.center - cursorAxis)
            }

            if cursorAxis > last.center,
               cursorAxis <= last.center + edgeMargin || (isLastEntry && !isDraggedMember) {
                consider(
                    .group(id: groupID, memberIndex: last.memberIndex + 1),
                    distance: cursorAxis - last.center
                )
            }
        }

        return best?.container
    }

    private static func isGroup(_ entry: PickyDockEntry?, id: String) -> Bool {
        guard case .group(let group) = entry else { return false }
        return group.id == id
    }

    /// Whether dragging past `entry` (the first or last dock entry) should
    /// escape to the top level. True when the edge is an ungrouped session, or
    /// when it is a group the dragged Pickle is being extracted from. False
    /// when the edge is a group the dragged Pickle is being dropped into.
    static func canEscapePastEdge(_ entry: PickyDockEntry?, draggedSessionID: String) -> Bool {
        guard let entry else { return true }
        switch entry {
        case .session:
            return true
        case .group(let group):
            return group.memberSessionIDs.contains(draggedSessionID)
        }
    }
}
