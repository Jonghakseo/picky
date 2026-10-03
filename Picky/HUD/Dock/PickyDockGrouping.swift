//
//  PickyDockGrouping.swift
//  Picky
//
//  Render projection and drag-drop resolution for the dock rail.
//
//  The persisted layout model (`PickyDockLayout`, `PickyDockGroup`,
//  `PickyDockEntry`, `PickyDockGroupColor`) lives in
//  `Picky/Sessions/Dock/PickyDockLayout.swift`. This file projects that layout
//  through `visibleSessions` (which agentd authorities own) into the rendered
//  dock tree, and resolves drag-drop targets back onto the layout.
//

import Foundation

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
