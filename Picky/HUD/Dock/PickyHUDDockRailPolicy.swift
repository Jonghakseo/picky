//
//  PickyHUDDockRailPolicy.swift
//  Picky
//
//  Pure layout and drag geometry used by the dock rail.
//

import CoreGraphics

/// Primary-axis span of a rendered top-level entry in rail coordinates. A
/// group spans its header and any expanded member rows.
struct PickyDockAxisExtent: Equatable {
    var lower: CGFloat
    var upper: CGFloat

    var center: CGFloat { (lower + upper) * 0.5 }
    var isFinite: Bool { lower.isFinite && upper.isFinite }
}

enum PickyHUDDockRailLayoutPolicy {
    /// Primary-axis length of the list content (rows, headers, placeholders)
    /// without the shell chrome. Mirrors the SwiftUI list layout, including
    /// the empty dock, which renders its `+` action at one row's size.
    static func listLength(
        projection: PickyDockProjection,
        activeSessionIDs: Set<String>,
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        switch orientation {
        case .vertical:
            let row = metrics.rowHeight(fontScale: fontScale)
            guard !projection.items.isEmpty else { return row }
            let header = metrics.groupHeaderHeight(fontScale: fontScale)
            var length: CGFloat = 0
            var entryCount = 0
            let lastIndex = projection.items.count - 1
            for (index, item) in projection.items.enumerated() {
                switch item {
                case .session:
                    length += row
                    entryCount += 1
                case .group(let group):
                    length += header
                    entryCount += 1
                    guard !group.isCollapsed else {
                        if index > 0 { length += metrics.groupHeaderTopGap }
                        continue
                    }
                    let members = projection.visibleMemberIDs(inGroup: group.id).count
                    let rows = max(1, members) // an empty expanded group shows a drop placeholder
                    length += CGFloat(rows) * row + CGFloat(rows) * metrics.rowSpacing
                    length += metrics.groupCardInnerBottom
                    if index > 0 { length += metrics.groupCardOuterGap }
                    if index < lastIndex { length += metrics.groupCardOuterGap }
                }
            }
            return length + CGFloat(max(0, entryCount - 1)) * metrics.rowSpacing
        case .horizontal:
            let chip = metrics.horizontalCompactCellSide(fontScale: fontScale)
            guard !projection.items.isEmpty else { return chip }
            var length: CGFloat = 0
            let lastIndex = projection.items.count - 1
            for (index, item) in projection.items.enumerated() {
                switch item {
                case .session:
                    length += chip
                case .group(let group):
                    length += chip
                    guard !group.isCollapsed else { continue }
                    let members = projection.visibleMemberIDs(inGroup: group.id).count
                    let chips = max(1, members)
                    length += CGFloat(chips) * chip
                    // An empty group's placeholder already creates a Pickle.
                    if members > 0 { length += metrics.horizontalGroupAddSlotWidth(fontScale: fontScale) }
                    if index > 0 { length += metrics.groupCardOuterGap }
                    if index < lastIndex { length += metrics.groupCardOuterGap }
                }
            }
            return length
        }
    }

    static func contentLength(
        projection: PickyDockProjection,
        activeSessionIDs: Set<String>,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        let list = listLength(
            projection: projection,
            activeSessionIDs: activeSessionIDs,
            orientation: dockSide.orientation,
            metrics: metrics,
            fontScale: fontScale
        )
        return list + fixedChromeLength(
            dockSide: dockSide,
            metrics: metrics,
            hasDockAddUtility: !projection.items.isEmpty,
            fontScale: fontScale
        )
    }

    static func crossSize(
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        dockSide.orientation == .horizontal
            ? PickyHUDDockLayout.horizontalDockRailCrossSize(metrics: metrics, fontScale: fontScale)
            : PickyHUDDockLayout.verticalDockRailCrossSize(metrics: metrics)
    }

    /// Handle, collapse notch, separator and utilities. Utilities follow the
    /// rail axis: stacked in a compact vertical rail, side by side horizontally.
    /// An empty dock moves its `+` into the list, leaving only archive here.
    static func fixedChromeLength(
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        hasDockAddUtility: Bool,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        if dockSide.orientation == .horizontal {
            return metrics.horizontalCompactHandleWidth + metrics.horizontalCompactSeparatorWidth
                + metrics.horizontalCompactCellSide(fontScale: fontScale) * (hasDockAddUtility ? 2 : 1)
                + metrics.collapseHitDepth
        }
        let utilities = hasDockAddUtility
            ? metrics.utilityButtonSide * 2 + metrics.utilitySpacing
            : metrics.utilityButtonSide
        return metrics.handleInset + metrics.collapseInset + utilities
            + metrics.chromeSpacing * 2 + metrics.chromeSeparatorThickness
    }
}

/// A nominal identity for the persisted dock structure. Drag cancellation
/// deliberately accepts this type rather than a render projection, so a
/// self-reflowing preview cannot accidentally become its observation source.
struct PickyHUDDockPersistedStructure: Equatable {
    let topEntryIDs: [String]
}

enum PickyHUDDockRenderPolicy {
    static func visibleTopEntryIDs(in items: [PickyDockRenderItem]) -> [String] {
        items.map { item in
            switch item {
            case .session(let sessionID): "session:\(sessionID)"
            case .group(let group): "group:\(group.id)"
            }
        }
    }

    /// Captures the persisted structure that drag cancellation observes.
    /// `PickyHUDDockRailView.projection` may be a self-reflowing preview while
    /// a drag is active, and is intentionally not interchangeable with this
    /// nominal persisted identity.
    static func persistedStructure(in persistedProjection: PickyDockProjection) -> PickyHUDDockPersistedStructure {
        PickyHUDDockPersistedStructure(
            topEntryIDs: visibleTopEntryIDs(in: persistedProjection.items)
        )
    }

    /// Top-level and expanded-group destinations move the clear placeholder so
    /// neighbors make room. A collapsed group accepts the Pickle without a
    /// linear slot, so the source placeholder stays until release.
    static func sessionPreviewLayout(
        layout: PickyDockLayout,
        draggedSessionID: String,
        destination: PickyDockContainer
    ) -> PickyDockLayout {
        guard layout.container(forSessionID: draggedSessionID) != destination else { return layout }
        switch destination {
        case .topLevel:
            break
        case .group(let groupID, _):
            guard let group = layout.group(withID: groupID), !group.isCollapsed else { return layout }
        }
        var preview = layout
        preview.move(session: draggedSessionID, to: destination)
        return preview
    }

    static func layoutEntryIndex(forVisibleTopEntryID entryID: String, in layout: PickyDockLayout) -> Int? {
        layout.entries.firstIndex { entry in
            switch entry {
            case .session(let id): "session:\(id)" == entryID
            case .group(let group): "group:\(group.id)" == entryID
            }
        }
    }

    /// Builds one stable top-level insertion target for each adjacent pair
    /// that includes a group, at the gap between the two entries' outer edges.
    /// Pickle-only pairs retain their center-based reorder threshold. Candidate
    /// indices describe the final post-move layout, so dropping at a boundary
    /// inserts before its right entry.
    static func topLevelInsertionCandidates(
        visibleTopEntryIDs: [String],
        referenceExtents: [String: PickyDockAxisExtent],
        draggedSessionID: String,
        layout: PickyDockLayout
    ) -> [PickyDockDropResolver.TopLevelInsertionCandidate] {
        let draggedTopLevelIndex: Int? = {
            guard case .topLevel(let index) = layout.container(forSessionID: draggedSessionID)
            else { return nil }
            return index
        }()
        return zip(visibleTopEntryIDs, visibleTopEntryIDs.dropFirst()).compactMap { pair in
            let (leftID, rightID) = pair
            guard let left = referenceExtents[leftID],
                  let right = referenceExtents[rightID],
                  left.isFinite,
                  right.isFinite,
                  let leftLayoutIndex = layoutEntryIndex(forVisibleTopEntryID: leftID, in: layout),
                  let rightLayoutIndex = layoutEntryIndex(forVisibleTopEntryID: rightID, in: layout),
                  isGroupEntry(at: leftLayoutIndex, in: layout)
                    || isGroupEntry(at: rightLayoutIndex, in: layout)
            else { return nil }
            let sourcePrecedesBoundary = draggedTopLevelIndex.map { $0 < rightLayoutIndex } ?? false
            let finalIndex = rightLayoutIndex - (sourcePrecedesBoundary ? 1 : 0)
            return .init(
                topLevelIndex: finalIndex,
                center: (left.upper + right.lower) * 0.5
            )
        }
    }

    private static func isGroupEntry(at index: Int, in layout: PickyDockLayout) -> Bool {
        guard layout.entries.indices.contains(index),
              case .group = layout.entries[index]
        else { return false }
        return true
    }

    /// Projects the opened Pickle into its collapsed group so the header keeps
    /// the selection context without expanding the member list.
    static func selectedGroupID(
        openedSessionID: String?,
        draggingSessionID: String?,
        layout: PickyDockLayout
    ) -> String? {
        guard draggingSessionID == nil, let openedSessionID else { return nil }
        for entry in layout.entries {
            guard case .group(let group) = entry, group.isCollapsed else { continue }
            if group.memberSessionIDs.contains(openedSessionID) { return group.id }
        }
        return nil
    }

    /// Projects the pending drag destination into the one folder that should
    /// advertise acceptance. Ordinary hover remains independent from this
    /// explicit drag state.
    static func dropTargetedGroupID(
        draggingSessionID: String?,
        destination: PickyDockContainer?
    ) -> String? {
        guard draggingSessionID != nil,
              case .group(let groupID, _) = destination
        else { return nil }
        return groupID
    }

    /// Frozen drag centers only describe the captured ordered top-level entries.
    /// A daemon or CLI structural update invalidates that geometry, so callers
    /// must cancel rather than resolving a current entry through stale centers.
    static func shouldCancelDrag(
        referenceTopEntryIDs: [String],
        currentTopEntryIDs: [String]
    ) -> Bool {
        !referenceTopEntryIDs.isEmpty && referenceTopEntryIDs != currentTopEntryIDs
    }

    /// Resolves a group drag from geometry captured before the preview starts.
    /// Keeping hit-testing separate from the live preview prevents a moved tile
    /// from changing the target under the pointer on the next event.
    static func nearestLayoutEntryIndex(
        cursorAxis: CGFloat,
        visibleTopEntryIDs: [String],
        referenceExtents: [String: PickyDockAxisExtent],
        layout: PickyDockLayout
    ) -> Int? {
        var nearestEntryID: String?
        var minimumDistance = CGFloat.infinity
        for entryID in visibleTopEntryIDs {
            guard let extent = referenceExtents[entryID] else { continue }
            let distance = abs(extent.center - cursorAxis)
            if distance < minimumDistance {
                minimumDistance = distance
                nearestEntryID = entryID
            }
        }
        guard let nearestEntryID else { return nil }
        return layoutEntryIndex(forVisibleTopEntryID: nearestEntryID, in: layout)
    }
}

enum PickyHUDDockReorderAnimationPolicy {
    /// Every top-level sibling uses one movement policy regardless of whether
    /// it renders as a Pickle or group. The dragged item stays cursor-driven.
    static func shouldAnimate(
        item: PickyDockRenderItem,
        draggingSessionID: String?,
        draggingGroupID: String?,
        reduceMotion: Bool
    ) -> Bool {
        guard !reduceMotion, draggingSessionID != nil || draggingGroupID != nil else { return false }
        switch item {
        case .session(let sessionID):
            return sessionID != draggingSessionID
        case .group(let group):
            return group.id != draggingGroupID
        }
    }

    /// A drag preview can move a row into or out of a collapsed group. Keep the
    /// rail at least as long as its persisted drag-start content so the capsule
    /// does not shrink while the pointer merely crosses a header.
    static func sizingLength(
        renderedLength: CGFloat,
        persistedLength: CGFloat,
        isSessionDragging: Bool
    ) -> CGFloat {
        guard isSessionDragging else { return renderedLength }
        return max(renderedLength, persistedLength)
    }
}

enum PickyHUDDockDragGeometry {
    static func slotPitch(
        orientation: PickyHUDDockOrientation,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        switch orientation {
        case .horizontal: metrics.horizontalCompactCellSide(fontScale: fontScale)
        case .vertical: metrics.rowHeight(fontScale: fontScale) + metrics.rowSpacing
        }
    }

    static func axisDelta(_ translation: CGSize, orientation: PickyHUDDockOrientation) -> CGFloat {
        switch orientation {
        case .horizontal: translation.width
        case .vertical: translation.height
        }
    }

    /// A floating reorder can only begin from measured geometry. Starting
    /// without a finite source center would position the preview at the rail
    /// fallback rather than beneath the picked-up Pickle.
    static func validSourceCenter(_ center: CGPoint?) -> CGPoint? {
        guard let center, center.x.isFinite, center.y.isFinite else { return nil }
        return center
    }

    /// The floating Pickle starts at the full source center captured at pickup,
    /// then follows the cursor translation on both axes. Keeping this separate
    /// from the primary-axis reorder center preserves frozen hit-test geometry.
    static func floatingIconCenter(
        dragStartCenter: CGPoint,
        translation: CGSize
    ) -> CGPoint {
        CGPoint(
            x: dragStartCenter.x + translation.width,
            y: dragStartCenter.y + translation.height
        )
    }

    /// Compensates for a reordered item's new Stack-assigned home in the same
    /// layout pass, keeping its visual center under the cursor without waiting
    /// for a geometry preference to publish on a later pass.
    static func cursorLockedOffset(
        translation: CGSize,
        dragStartCenter: CGFloat,
        currentHomeCenter: CGFloat,
        orientation: PickyHUDDockOrientation
    ) -> CGSize {
        let primaryOffset = axisDelta(translation, orientation: orientation)
            - (currentHomeCenter - dragStartCenter)
        switch orientation {
        case .horizontal:
            return CGSize(width: primaryOffset, height: translation.height)
        case .vertical:
            return CGSize(width: translation.width, height: primaryOffset)
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

    /// Half the rail's cross size plus a margin: the row must clearly leave the dock.
    static func pullOutThreshold(
        metrics: PickyHUDDockMetrics,
        orientation: PickyHUDDockOrientation,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        let cross = orientation == .vertical
            ? metrics.railWidth
            : metrics.horizontalCompactCellSide(fontScale: fontScale)
        return cross * 0.5 + 40
    }
}
