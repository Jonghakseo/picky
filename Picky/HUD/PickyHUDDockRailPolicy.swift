//
//  PickyHUDDockRailPolicy.swift
//  Picky
//
//  Pure layout and drag geometry used by the dock rail.
//

import Combine
import CoreGraphics

/// Display-local feedback published by the external-drag coordinator in the
/// next wiring slice. Rail rendering observes this only as a preview input;
/// it never uses the projected layout to measure or validate a drop.
struct PickyHUDDockExternalDragRailPresentation: Equatable {
    let token: UUID
    let sessionID: String
    let destination: PickyDockContainer?
}

@MainActor
final class PickyHUDDockExternalDragRailPresentationStore: ObservableObject {
    @Published private(set) var presentation: PickyHUDDockExternalDragRailPresentation?

    func show(token: UUID, sessionID: String, destination: PickyDockContainer?) {
        presentation = .init(token: token, sessionID: sessionID, destination: destination)
    }

    func update(token: UUID, destination: PickyDockContainer?) {
        guard let presentation, presentation.token == token else { return }
        self.presentation = .init(token: token, sessionID: presentation.sessionID, destination: destination)
    }

    func clear(token: UUID? = nil) {
        guard token == nil || presentation?.token == token else { return }
        presentation = nil
    }
}

enum PickyHUDDockExternalDragRailGeometryPolicy {
    /// Frozen base geometry belongs to Overlay Manager while an external drag
    /// is active. Publishing the rail's preview-reflow preferences would
    /// otherwise replace that base snapshot with its own consequence.
    static func shouldPublishExternalGeometry(hasActivePresentation: Bool) -> Bool {
        !hasActivePresentation
    }
}

enum PickyHUDDockRailLayoutPolicy {
    /// The rail has one folder tile per group, plus one compact header for
    /// that tile. Member count deliberately does not participate in this
    /// calculation, so a growing group cannot stretch the rail.
    static func contentLength(
        sessionCount: Int,
        groupCount: Int = 0,
        emptyGroupCount: Int = 0,
        isAddSlotExpanded: Bool,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        if dockSide.orientation == .horizontal {
            return PickyHUDDockLayout.horizontalDockRailLength(
                sessionCount: sessionCount,
                isAddSlotExpanded: isAddSlotExpanded,
                metrics: metrics
            )
        }
        let measuredEmptyGroupCount = max(0, min(emptyGroupCount, sessionCount))
        let emptyGroupHeightReduction = CGFloat(measuredEmptyGroupCount)
            * (metrics.sessionTileHeight - metrics.emptyGroupSlotHeight)
        return PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessionCount,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        ) - emptyGroupHeightReduction + PickyHUDDockLayout.dockGroupHeaderExtraLength(
            groupHeaderCount: groupCount,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    static func verticalCrossSize(
        groupCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        PickyHUDDockLayout.verticalDockRailCrossSize(
            hasGroupHeaders: groupCount > 0,
            metrics: metrics,
            fontScale: fontScale
        )
    }

    static func horizontalCrossSize(
        groupCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = PickyAppFontScaleStore.staticCGScale
    ) -> CGFloat {
        PickyHUDDockLayout.horizontalDockRailCrossSize(
            hasGroupHeaders: groupCount > 0,
            metrics: metrics,
            fontScale: fontScale
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

    /// A one-Pickle group renders its member as a full session tile while the
    /// persisted projection still owns one folder slot. Add a synthetic session
    /// slot beside that folder slot so native session drag can start from the
    /// visible tile without removing the group's drop target.
    static func interactionSlots(
        persistedProjection: PickyDockProjection,
        layout: PickyDockLayout,
        visibleSessionIDs: Set<String>
    ) -> [PickyDockSlot] {
        var result: [PickyDockSlot] = []
        for slot in persistedProjection.slots {
            result.append(slot)
            guard let groupID = slot.groupID,
                  let group = layout.group(withID: groupID)
            else { continue }
            let visibleMemberIDs = group.memberSessionIDs.filter(visibleSessionIDs.contains)
            guard case .singleSession(let sessionID) = PickyHUDDockGroupTilePresentation.resolve(
                visibleMemberIDs: visibleMemberIDs
            ), let memberIndex = group.memberSessionIDs.firstIndex(of: sessionID)
            else { continue }
            result.append(PickyDockSlot(
                target: .session(
                    id: sessionID,
                    container: .group(id: groupID, memberIndex: memberIndex)
                ),
                visibleIndex: slot.visibleIndex
            ))
        }
        return result
    }

    /// A grouped Pickle is absent from the normal rail universe because its
    /// folder owns the top-level slot. External top-level preview is the one
    /// exception: inject it once so the existing rail placeholder/reflow can
    /// show the prospective ungrouped position without changing normal or
    /// folder-target projection.
    static func externalPreviewVisibleSessionIDs(
        base: [String],
        draggedSessionID: String?,
        destination: PickyDockContainer?
    ) -> [String] {
        guard let draggedSessionID,
              case .topLevel? = destination,
              !base.contains(draggedSessionID)
        else { return base }
        return base + [draggedSessionID]
    }

    /// Folder acceptance does not create a new linear slot. Keep the persisted
    /// source placeholder until release so the rail and add slot remain stable
    /// while the pointer crosses a folder. Only top-level destinations reflow
    /// the preview to show the prospective insertion position.
    static func sessionPreviewLayout(
        layout: PickyDockLayout,
        draggedSessionID: String,
        destination: PickyDockContainer
    ) -> PickyDockLayout {
        guard layout.container(forSessionID: draggedSessionID) != destination else { return layout }
        guard case .topLevel = destination else { return layout }
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
    /// that includes a folder. Pickle-only pairs retain their existing
    /// center-based reorder threshold. Candidate indices describe the final
    /// post-move layout, so dropping at a boundary inserts before its right entry.
    static func topLevelInsertionCandidates(
        visibleTopEntryIDs: [String],
        referenceCenters: [String: CGFloat],
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
            guard let leftCenter = referenceCenters[leftID],
                  let rightCenter = referenceCenters[rightID],
                  leftCenter.isFinite,
                  rightCenter.isFinite,
                  let leftLayoutIndex = layoutEntryIndex(forVisibleTopEntryID: leftID, in: layout),
                  let rightLayoutIndex = layoutEntryIndex(forVisibleTopEntryID: rightID, in: layout),
                  isGroupEntry(at: leftLayoutIndex, in: layout)
                    || isGroupEntry(at: rightLayoutIndex, in: layout)
            else { return nil }
            let sourcePrecedesBoundary = draggedTopLevelIndex.map { $0 < rightLayoutIndex } ?? false
            let finalIndex = rightLayoutIndex - (sourcePrecedesBoundary ? 1 : 0)
            return .init(
                topLevelIndex: finalIndex,
                center: (leftCenter + rightCenter) * 0.5
            )
        }
    }

    private static func isGroupEntry(at index: Int, in layout: PickyDockLayout) -> Bool {
        guard layout.entries.indices.contains(index),
              case .group = layout.entries[index]
        else { return false }
        return true
    }

    /// Projects the opened Pickle into its owning folder so the collapsed
    /// rail preserves selection context without expanding the member list.
    static func selectedGroupID(
        openedSessionID: String?,
        draggingSessionID: String?,
        layout: PickyDockLayout
    ) -> String? {
        guard draggingSessionID == nil, let openedSessionID else { return nil }
        for entry in layout.entries {
            guard case .group(let group) = entry else { continue }
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
        referenceCenters: [String: CGFloat],
        layout: PickyDockLayout
    ) -> Int? {
        var nearestEntryID: String?
        var minimumDistance = CGFloat.infinity
        for entryID in visibleTopEntryIDs {
            guard let center = referenceCenters[entryID] else { continue }
            let distance = abs(center - cursorAxis)
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
    /// it renders as a Pickle or folder. The dragged item stays cursor-driven.
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

    /// A grouping preview can temporarily remove a top-level Pickle from the
    /// rendered projection. Keep the rail at least as large as its persisted
    /// drag-start projection so the capsule and add slot do not collapse while
    /// the pointer merely crosses a folder on the way to another top-level slot.
    static func sizingSlotCount(
        renderedSlotCount: Int,
        persistedSlotCount: Int,
        isSessionDragging: Bool
    ) -> Int {
        guard isSessionDragging else { return renderedSlotCount }
        return max(renderedSlotCount, persistedSlotCount)
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

    /// A floating reorder can only begin from measured geometry. Starting
    /// without a finite source center would position the preview at the rail
    /// fallback rather than beneath the picked-up Pickle.
    static func validSourceCenter(_ center: CGPoint?) -> CGPoint? {
        guard let center, center.x.isFinite, center.y.isFinite else { return nil }
        return center
    }

    /// The floating Pickle starts at the full source center captured at pickup,
    /// then follows the cursor translation on both axes. Keeping this separate
    /// from the primary-axis reorder center preserves frozen hit-test geometry
    /// while folder label chrome can offset a horizontal source vertically.
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

    static func pullOutThreshold(metrics: PickyHUDDockMetrics) -> CGFloat {
        metrics.railWidth * 0.5 + 40
    }
}
