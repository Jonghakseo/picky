//
//  PickyHUDDockGroupListPolicy.swift
//  Picky
//
//  Pure geometry for the dock group list panel: how large it is, where it
//  anchors against its folder tile, and how it stays on screen.
//

import CoreGraphics

enum PickyHUDDockGroupListPolicy {
    /// Panel size for a group, saturating at `groupListMaxVisibleRows` rows so
    /// a large group never produces a taller panel than a medium one.
    static func panelSize(memberCount: Int, metrics: PickyHUDDockMetrics) -> CGSize {
        let rows = min(max(memberCount, 0), PickyHUDDockLayout.groupListMaxVisibleRows)
        return CGSize(
            width: metrics.groupListPanelWidth,
            height: (metrics.groupListPanelPadding * 2)
                + metrics.groupListHeaderHeight
                + (CGFloat(rows) * metrics.groupListRowHeight)
        )
    }

    /// True when the group has more members than the panel can show at once.
    static func needsScroll(memberCount: Int) -> Bool {
        memberCount > PickyHUDDockLayout.groupListMaxVisibleRows
    }

    /// Anchors the panel to the folder's rail-facing edge and opens it toward
    /// the screen interior. Frames use a top-left origin (SwiftUI style).
    static func anchoredOrigin(
        folderFrame: CGRect,
        railFrame: CGRect,
        panelSize: CGSize,
        dockSide: PickyHUDDockSide,
        panelGap: CGFloat
    ) -> CGPoint {
        switch dockSide {
        case .left:
            CGPoint(x: railFrame.maxX + panelGap, y: folderFrame.minY)
        case .right:
            CGPoint(x: railFrame.minX - panelGap - panelSize.width, y: folderFrame.minY)
        case .top:
            CGPoint(x: folderFrame.minX, y: railFrame.maxY + panelGap)
        case .bottom:
            CGPoint(x: folderFrame.minX, y: railFrame.minY - panelGap - panelSize.height)
        }
    }

    /// Keeps the panel inside `bounds` by sliding it along the rail's primary
    /// axis only. The anchored edge never moves and the open direction never
    /// flips, so the panel always appears on the same side of the rail.
    static func clampedOrigin(
        _ origin: CGPoint,
        panelSize: CGSize,
        bounds: CGRect,
        dockSide: PickyHUDDockSide,
        margin: CGFloat
    ) -> CGPoint {
        let inset = bounds.insetBy(dx: margin, dy: margin)
        switch dockSide.orientation {
        case .vertical:
            let maxY = max(inset.minY, inset.maxY - panelSize.height)
            return CGPoint(x: origin.x, y: min(max(origin.y, inset.minY), maxY))
        case .horizontal:
            let maxX = max(inset.minX, inset.maxX - panelSize.width)
            return CGPoint(x: min(max(origin.x, inset.minX), maxX), y: origin.y)
        }
    }
}
