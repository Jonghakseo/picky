//
//  PickyHUDDockGroupListPolicy.swift
//  Picky
//
//  Pure geometry for the dock group list panel: how large it is, where it
//  anchors against its folder tile, and how it stays on screen.
//

import AppKit

enum PickyHUDDockGroupListPolicy {
    struct RowWidthContent: Equatable {
        let title: String
        let subtitle: String
        let isUnread: Bool
    }

    /// Panel size for a group, saturating at `groupListMaxVisibleRows` rows so
    /// a large group never produces a taller panel than a medium one. Callers
    /// without render content receive the maximum width geometry.
    static func panelSize(
        memberCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat = 1,
        width: CGFloat? = nil
    ) -> CGSize {
        let rows = min(max(memberCount, 0), PickyHUDDockLayout.groupListMaxVisibleRows)
        return CGSize(
            width: min(max(0, width ?? metrics.groupListPanelWidth), metrics.groupListPanelWidth),
            height: panelChromeHeight(metrics: metrics)
                + rowStackHeight(rowCount: rows, metrics: metrics, fontScale: fontScale)
        )
    }

    /// Natural group-list width. The header and every row reserve their exact
    /// text and control chrome, while the authored group-list width remains the
    /// hard upper bound.
    static func panelWidth(
        groupName: String,
        memberCount: Int,
        rows: [RowWidthContent],
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let widestContent = max(
            headerWidth(
                groupName: groupName,
                memberCount: memberCount,
                metrics: metrics,
                fontScale: fontScale
            ),
            rows.map {
                groupRowWidth(content: $0, metrics: metrics, fontScale: fontScale)
            }.max() ?? 0
        )
        return min(metrics.groupListPanelWidth, ceil(widestContent))
    }

    /// Natural mini-preview width. It is the same row geometry without the
    /// unread marker and trailing group-list action rail.
    static func previewWidth(
        title: String,
        subtitle: String,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let textWidth = rowTextWidth(title: title, subtitle: subtitle, fontScale: fontScale)
        let naturalWidth = (metrics.groupListPanelPadding * 2)
            + (metrics.groupListRowHorizontalPadding * 2)
            + metrics.groupListRowGlyphSide
            + metrics.groupListRowContentSpacing
            + textWidth
        return min(metrics.groupListPanelWidth, ceil(naturalWidth))
    }

    @MainActor
    static func panelSize(
        group: PickyDockGroup,
        rows: [PickyHUDDockGroupListRowModel],
        unreadSessionIDs: Set<String>,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat,
        relativeTime: (Date) -> String
    ) -> CGSize {
        let widthRows = rows.map { row in
            RowWidthContent(
                title: row.title,
                subtitle: PickyHUDDockGroupListRowPresentation.subtitle(
                    cwdLeaf: row.cwdLeaf,
                    relativeTime: relativeTime(row.updatedAt)
                ),
                isUnread: unreadSessionIDs.contains(row.id)
            )
        }
        return panelSize(
            memberCount: max(1, rows.count),
            metrics: metrics,
            fontScale: fontScale,
            width: panelWidth(
                groupName: group.displayName,
                memberCount: rows.count,
                rows: widthRows,
                metrics: metrics,
                fontScale: fontScale
            )
        )
    }

    @MainActor
    static func previewWidth(
        session: PickyHUDDockSession,
        relativeTime: String,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let row = PickyHUDDockGroupListRowModel(session: session, updatedAt: session.previewUpdatedAt)
        return previewWidth(
            title: row.title,
            subtitle: PickyHUDDockGroupListRowPresentation.subtitle(
                cwdLeaf: row.cwdLeaf,
                relativeTime: relativeTime
            ),
            metrics: metrics,
            fontScale: fontScale
        )
    }

    private static func headerWidth(
        groupName: String,
        memberCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let nameWidth = textWidth(
            groupName,
            font: PickyHUDTypography.labelSemiboldNSFont(fontScale: fontScale)
        ) + (DS.Spacing.space1 * 2)
        let countWidth = textWidth(
            String(memberCount),
            font: PickyHUDTypography.metaNSFont(fontScale: fontScale)
        )
        return (metrics.groupListPanelPadding * 2)
            + (metrics.groupListHeaderHeight * 2)
            + nameWidth
            + countWidth
            + (DS.Spacing.space1 * 3)
    }

    private static func groupRowWidth(
        content: RowWidthContent,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        let elementCount = content.isUnread ? 4 : 3
        return (metrics.groupListPanelPadding * 2)
            + (metrics.groupListRowHorizontalPadding * 2)
            + metrics.groupListRowGlyphSide
            + rowTextWidth(title: content.title, subtitle: content.subtitle, fontScale: fontScale)
            + (content.isUnread ? 7 : 0)
            + trailingRailWidth(metrics: metrics)
            + (CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing)
    }

    private static func rowTextWidth(title: String, subtitle: String, fontScale: CGFloat) -> CGFloat {
        max(
            textWidth(title, font: PickyHUDTypography.bodyCompactNSFont(fontScale: fontScale)),
            textWidth(subtitle, font: PickyHUDTypography.metaNSFont(fontScale: fontScale))
        )
    }

    private static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }

    /// The content stack uses body and meta type roles. At compact dock
    /// presets, their measured line heights exceed the authored row minimum;
    /// retain that intrinsic height so the child panel and its row centers stay
    /// in sync at every global app font scale.
    static func rowHeight(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        max(metrics.groupListRowHeight, rowContentHeight(metrics: metrics, fontScale: fontScale))
    }

    /// The stack's total includes the deliberate `space.1` separation between
    /// rows, so the final rendered member never clips at the panel edge.
    static func rowStackHeight(
        rowCount: Int,
        metrics: PickyHUDDockMetrics,
        fontScale: CGFloat
    ) -> CGFloat {
        guard rowCount > 0 else { return 0 }
        return CGFloat(rowCount) * rowHeight(metrics: metrics, fontScale: fontScale)
            + CGFloat(rowCount - 1) * metrics.groupListRowSpacing
    }

    static func rowContentHeight(metrics: PickyHUDDockMetrics, fontScale: CGFloat) -> CGFloat {
        let titleFont = PickyHUDTypography.bodyNSFont(fontScale: fontScale)
        let subtitleFont = PickyHUDTypography.metaNSFont(fontScale: fontScale)
        return lineHeight(for: titleFont)
            + metrics.groupListRowVerticalPadding // space.1 between text roles
            + lineHeight(for: subtitleFont)
            + (metrics.groupListRowVerticalPadding * 2)
    }

    /// The shortcut column reserves no more than the widest supported list
    /// shortcut (`⌘9`), measured with the same badge role as its SwiftUI text.
    static func shortcutHintWidth(fontScale: CGFloat) -> CGFloat {
        ceil(("⌘9" as NSString).size(withAttributes: [
            .font: PickyHUDTypography.badgeSemiboldNSFont(fontScale: fontScale),
        ]).width)
    }

    /// Width of the row's fixed trailing rail. At rest this rail shows a
    /// shortcut hint; hover and keyboard highlight replace it with two actions.
    static func trailingRailWidth(metrics: PickyHUDDockMetrics) -> CGFloat {
        (metrics.groupListRowQuickActionSide * 2) + metrics.groupListRowQuickActionSpacing
    }

    /// Width available to the title after fixed row chrome. Rows and the
    /// header share the panel's outer padding as symmetric horizontal insets.
    static func titleColumnWidth(
        metrics: PickyHUDDockMetrics,
        isUnread: Bool,
        fontScale: CGFloat,
        panelWidth: CGFloat? = nil
    ) -> CGFloat {
        let contentWidth = (panelWidth ?? metrics.groupListPanelWidth) - (metrics.groupListPanelPadding * 2)
        let fixedWidths = (metrics.groupListRowHorizontalPadding * 2)
            + metrics.groupListRowGlyphSide
            + trailingRailWidth(metrics: metrics)
            + (isUnread ? 7 : 0)
        let elementCount = isUnread ? 4 : 3
        let spacing = CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing
        return max(0, contentWidth - fixedWidths - spacing)
    }

    /// The shared AppKit click host owns opening, long-press archiving, and
    /// reorder handoff before the row's SwiftUI action rail. The separate
    /// trailing-padding host below preserves those gestures everywhere outside
    /// the two quick-action hit regions without covering either button.
    static func clickHostWidth(
        metrics: PickyHUDDockMetrics,
        isUnread: Bool,
        fontScale: CGFloat,
        panelWidth: CGFloat? = nil
    ) -> CGFloat {
        let elementCount = isUnread ? 4 : 3
        return metrics.groupListRowHorizontalPadding
            + metrics.groupListRowGlyphSide
            + titleColumnWidth(
                metrics: metrics,
                isUnread: isUnread,
                fontScale: fontScale,
                panelWidth: panelWidth
            )
            + (isUnread ? 7 : 0)
            + (CGFloat(elementCount - 1) * metrics.groupListRowContentSpacing)
    }

    static func trailingPaddingClickHostWidth(metrics: PickyHUDDockMetrics) -> CGFloat {
        metrics.groupListRowHorizontalPadding
    }

    private static func lineHeight(for font: NSFont) -> CGFloat {
        font.ascender - font.descender + font.leading
    }

    static func panelChromeHeight(metrics: PickyHUDDockMetrics) -> CGFloat {
        (metrics.groupListPanelPadding * 2)
            + metrics.groupListHeaderHeight
            + metrics.groupListHeaderBottomSpacing
    }

    /// The panel and its owning folder block (tile plus label) consume the
    /// same mouse down. Keeping that interaction frame separate from the
    /// tile-only panel anchor prevents the outside monitor racing its toggle.
    static func shouldDismissForMouseDown(
        at screenPoint: CGPoint,
        panelFrame: CGRect,
        owningInteractionFrame: CGRect?
    ) -> Bool {
        !panelFrame.contains(screenPoint)
            && !(owningInteractionFrame?.contains(screenPoint) ?? false)
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
