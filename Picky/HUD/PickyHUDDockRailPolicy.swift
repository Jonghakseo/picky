//
//  PickyHUDDockRailPolicy.swift
//  Picky
//
//  Pure layout, render-plan, and drag geometry used by the stateful dock rail.
//  Keeping these decisions outside the SwiftUI view preserves one state owner
//  while making the dock invariants independently testable.
//

import CoreGraphics

enum PickyHUDDockRailLayoutPolicy {
    static func groupHeaderCount(in items: [PickyDockRenderItem]) -> Int {
        items.reduce(0) { count, item in
            switch item {
            case .groupHeader, .collapsedGroup: count + 1
            default: count
            }
        }
    }

    static func emptyGroupDropTileCount(in projection: PickyDockProjection) -> Int {
        projection.items.reduce(0) { count, item in
            switch item {
            case .groupHeader(let group):
                let hasProjectedMember = projection.slots.contains { slot in
                    if case .group(let id, _) = slot.container { return id == group.id }
                    return false
                }
                return count + (hasProjectedMember ? 0 : 1)
            case .collapsedGroup(_, let topMember):
                return count + (topMember == nil ? 1 : 0)
            default:
                return count
            }
        }
    }

    static func contentLength(
        sessionCount: Int,
        isAddSlotExpanded: Bool,
        dockSide: PickyHUDDockSide,
        projection: PickyDockProjection,
        metrics: PickyHUDDockMetrics
    ) -> CGFloat {
        let headerCount = groupHeaderCount(in: projection.items)
        let emptyTileCount = emptyGroupDropTileCount(in: projection)
        if dockSide.orientation == .horizontal {
            let emptyDropExtraLength = CGFloat(emptyTileCount) * (metrics.sessionTileWidth + metrics.sessionSpacing)
            return PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: sessionCount,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics
            ) + emptyDropExtraLength
        }
        let headersExtraLength = PickyHUDDockLayout.dockGroupHeaderExtraLength(groupHeaderCount: headerCount)
        let emptyDropExtraLength = CGFloat(emptyTileCount) * (metrics.sessionTileHeight + metrics.sessionSpacing)
        return PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessionCount,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        ) + headersExtraLength + emptyDropExtraLength
    }

    static func horizontalCrossSize(
        projection: PickyDockProjection,
        metrics: PickyHUDDockMetrics
    ) -> CGFloat {
        PickyHUDDockLayout.horizontalDockRailCrossSize(
            hasGroupHeaders: groupHeaderCount(in: projection.items) > 0,
            metrics: metrics
        )
    }

    static func fixedChromeLength(
        isAddSlotExpanded: Bool,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics
    ) -> CGFloat {
        if dockSide.orientation == .horizontal {
            return (metrics.topPadding * 2)
                + metrics.handleAreaHeight
                + 4
                + PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
        }
        return metrics.topPadding
            + metrics.handleAreaHeight
            + 2
            + metrics.addSlotTopPadding
            + PickyHUDDockLayout.addSlotFrameHeight(isExpanded: isAddSlotExpanded, metrics: metrics)
            + metrics.bottomPadding
    }
}

enum PickyHUDDockRenderPolicy {
    static func emptyGroupDropTargetID(groupID: String) -> String {
        "_empty_group:\(groupID)"
    }

    static func parseEmptyGroupDropTargetID(_ id: String) -> String? {
        guard id.hasPrefix("_empty_group:") else { return nil }
        return String(id.dropFirst("_empty_group:".count))
    }

    static func renderUnits(from items: [PickyDockRenderItem]) -> [PickyHUDDockRenderUnit] {
        var units: [PickyHUDDockRenderUnit] = []
        var activeGroup: PickyDockGroup?
        var activeMembers: [PickyHUDDockGroupMemberRef] = []

        func flushGroup() {
            if let group = activeGroup {
                units.append(.init(kind: .group(group: group, members: activeMembers)))
                activeGroup = nil
                activeMembers = []
            }
        }

        for item in items {
            switch item {
            case .session(let id):
                flushGroup()
                units.append(.init(kind: .session(id: id)))
            case .groupHeader(let group):
                flushGroup()
                activeGroup = group
                activeMembers = []
            case .groupMember(_, let sessionID, _):
                if activeGroup != nil {
                    activeMembers.append(.init(sessionID: sessionID))
                } else {
                    units.append(.init(kind: .session(id: sessionID)))
                }
            case .collapsedGroup(let group, let topMember):
                flushGroup()
                let members = topMember.map { [PickyHUDDockGroupMemberRef(sessionID: $0)] } ?? []
                units.append(.init(kind: .group(group: group, members: members)))
            }
        }
        flushGroup()
        return units
    }

    static func groupDrawerSpan(
        group: PickyDockGroup,
        members: [PickyHUDDockGroupMemberRef],
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics
    ) -> CGFloat {
        guard dockSide.orientation == .horizontal else { return metrics.sessionTileWidth }
        if group.isCollapsed || members.isEmpty { return metrics.sessionTileWidth }
        let count = CGFloat(members.count)
        return count * metrics.sessionTileWidth + max(0, count - 1) * metrics.sessionSpacing
    }

    static func visibleTopEntryIDs(in items: [PickyDockRenderItem]) -> [String] {
        items.compactMap { item in
            switch item {
            case .session(let sessionID): "session:\(sessionID)"
            case .groupHeader(let group), .collapsedGroup(let group, _): "group:\(group.id)"
            case .groupMember: nil
            }
        }
    }

    static func layoutEntryIndex(forVisibleTopEntryID entryID: String, in layout: PickyDockLayout) -> Int? {
        layout.entries.firstIndex { entry in
            switch entry {
            case .session(let id): "session:\(id)" == entryID
            case .group(let group): "group:\(group.id)" == entryID
            }
        }
    }
}

enum PickyHUDDockDragGeometry {
    static func slotPitch(orientation: PickyHUDDockOrientation, metrics: PickyHUDDockMetrics) -> CGFloat {
        switch orientation {
        case .horizontal: metrics.sessionTileWidth + metrics.sessionSpacing
        case .vertical: metrics.sessionTileHeight + metrics.sessionSpacing
        }
    }

    static func axisDelta(_ translation: CGSize, orientation: PickyHUDDockOrientation) -> CGFloat {
        switch orientation {
        case .horizontal: translation.width
        case .vertical: translation.height
        }
    }

    static func pullOutDistance(_ translation: CGSize, dockSide: PickyHUDDockSide) -> CGFloat {
        switch dockSide {
        case .left: translation.width
        case .right: -translation.width
        case .top: translation.height
        case .bottom: -translation.height
        }
    }

    static func pullOutThreshold(metrics: PickyHUDDockMetrics) -> CGFloat {
        metrics.railWidth * 0.5 + 40
    }
}
