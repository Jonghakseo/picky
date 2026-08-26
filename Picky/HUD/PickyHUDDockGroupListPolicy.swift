//
//  PickyHUDDockGroupListPolicy.swift
//  Picky
//
//  Pure geometry for the dock group list panel: how large it is, where it
//  anchors against its folder tile, and how it stays on screen.
//

import AppKit

enum PickyHUDDockGroupListPolicy {
    /// Panel size for a group, saturating at `groupListMaxVisibleRows` rows so
    /// a large group never produces a taller panel than a medium one.
    static func panelSize(
        memberCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = 1
    ) -> CGSize {
        let rows = min(max(memberCount, 0), PickyHUDDockLayout.groupListMaxVisibleRows)
        return CGSize(
            width: metrics.groupListPanelWidth,
            height: panelChromeHeight(metrics: metrics)
                + (CGFloat(rows) * rowHeight(metrics: metrics, fontScale: fontScale))
        )
    }

    /// The content stack uses body and meta type roles. At compact dock
    /// presets, their measured line heights exceed the authored row minimum;
    /// retain that intrinsic height so the child panel and its row centers stay
    /// in sync at every global app font scale.
    static func rowHeight(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        max(metrics.groupListRowHeight, rowContentHeight(fontScale: fontScale))
    }

    static func rowContentHeight(fontScale: CGFloat) -> CGFloat {
        let titleFont = PickyHUDTypography.bodyNSFont(fontScale: fontScale)
        let subtitleFont = PickyHUDTypography.metaNSFont(fontScale: fontScale)
        return lineHeight(for: titleFont)
            + 4 // space.1 between the body and meta text roles
            + lineHeight(for: subtitleFont)
    }

    /// The shortcut column reserves no more than the widest supported list
    /// shortcut (`⌘9`), measured with the same badge role as its SwiftUI text.
    static func shortcutHintWidth(fontScale: CGFloat) -> CGFloat {
        ceil(("⌘9" as NSString).size(withAttributes: [
            .font: PickyHUDTypography.badgeSemiboldNSFont(fontScale: fontScale),
        ]).width)
    }

    /// Width available to the title after fixed row chrome. Rows use the
    /// panel's outer padding as their sole horizontal inset, so the state
    /// background and text column share the same content bounds.
    static func titleColumnWidth(
        metrics: PickyHUDDockMetrics,
        isUnread: Bool,
        fontScale: CGFloat
    ) -> CGFloat {
        let contentWidth = metrics.groupListPanelWidth - (metrics.groupListPanelPadding * 2)
        let fixedWidths = metrics.groupListRowGlyphSide
            + shortcutHintWidth(fontScale: fontScale)
            + (isUnread ? 7 : 0)
        let elementCount = isUnread ? 4 : 3
        let spacing = CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing
        return max(0, contentWidth - fixedWidths - spacing)
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    static func panelChromeHeight(metrics: PickyHUDDockMetrics) -> CGFloat {
        (metrics.groupListPanelPadding * 2)
            + metrics.groupListHeaderHeight
            + metrics.groupListHeaderBottomSpacing
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
