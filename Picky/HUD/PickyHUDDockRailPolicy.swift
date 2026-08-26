//
//  PickyHUDDockRailPolicy.swift
//  Picky
//
//  Pure layout and drag geometry used by the dock rail.
//

import CoreGraphics

enum PickyHUDDockRailLayoutPolicy {
    static func contentLength(
        sessionCount: Int,
        isAddSlotExpanded: Bool,
        dockSide: PickyHUDDockSide,
        metrics: PickyHUDDockMetrics
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
    static func visibleTopEntryIDs(in items: [PickyDockRenderItem]) -> [String] {
        items.map { item in
            switch item {
            case .session(let sessionID): "session:\(sessionID)"
            case .group(let group): "group:\(group.id)"
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
