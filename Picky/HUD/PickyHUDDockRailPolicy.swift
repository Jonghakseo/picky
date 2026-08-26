//
//  PickyHUDDockRailPolicy.swift
//  Picky
//
//  Pure layout and drag geometry used by the dock rail.
//

import CoreGraphics

enum PickyHUDDockRailLayoutPolicy {
    /// The rail has one folder tile per group, plus one compact header for
    /// that tile. Member count deliberately does not participate in this
    /// calculation, so a growing group cannot stretch the rail.
    static func contentLength(
        sessionCount: Int,
        groupCount: Int = 0,
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
        return PickyHUDDockLayout.dockRailHeight(
            sessionCount: sessionCount,
            isAddSlotExpanded: isAddSlotExpanded,
            metrics: metrics
        ) + PickyHUDDockLayout.dockGroupHeaderExtraLength(
            groupHeaderCount: groupCount,
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

    static func layoutEntryIndex(forVisibleTopEntryID entryID: String, in layout: PickyDockLayout) -> Int? {
        layout.entries.firstIndex { entry in
            switch entry {
            case .session(let id): "session:\(id)" == entryID
            case .group(let group): "group:\(group.id)" == entryID
            }
        }
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
