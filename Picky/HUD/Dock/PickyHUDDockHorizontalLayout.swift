//
//  PickyHUDDockHorizontalLayout.swift
//  Picky
//
//  Placement contract for the bounded horizontal dock. The rail keeps one
//  fixed square cell per entry and never widens with titles: a cell draws the
//  status glyph, the group folder, or the empty-group `+`, and the name is
//  read elsewhere (the shared title preview the rail opens above or below the
//  cells). The rail's resting length therefore depends only on how many
//  entries exist, not on how long their titles are.
//
//  `EnvironmentValues.pickyDockHorizontalLayout` is the only switch. It is
//  `false` by default, and it is deliberately ignored by vertical docks, so
//  the classic horizontal chips and every vertical layout stay untouched
//  unless the rail opts in.
//

import SwiftUI

/// Shared placement constants for a bounded horizontal cell.
///
/// Cell *side* is not here: it comes from
/// `PickyHUDDockMetrics.horizontalCompactCellSide(fontScale:)`, so S/M/L and
/// the app font scale stay in one metrics table.
enum PickyHUDDockHorizontalCompactLayout {
    /// Gap between a cell's bounds and its hover/selection fill. The native
    /// host still owns the full square, so neighbouring cells read as separate
    /// targets without leaving dead pixels between them.
    static let fillInset: CGFloat = 3

    /// Corner for the unread / attention badge inside a cell.
    static let badgeAlignment: Alignment = .topTrailing

    /// Corner for the secondary mark (sticky pin or ⌘ number).
    static let markerAlignment: Alignment = .bottomTrailing

    /// Pushes a top-trailing badge outward along both axes.
    static func badgeOffset(_ distance: CGFloat) -> CGSize {
        CGSize(width: distance, height: -distance)
    }

    /// Pushes a bottom-trailing mark outward along both axes.
    static func markerOffset(_ distance: CGFloat) -> CGSize {
        CGSize(width: distance, height: distance)
    }
}

// MARK: - Environment

private struct PickyHUDDockHorizontalLayoutKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Opts the horizontal dock into bounded square cells.
    ///
    /// `false` (the default) keeps the classic horizontal chips with their
    /// inline titles. Vertical docks ignore this value entirely; their compact
    /// placement stays in `pickyDockCompactLayout`.
    var pickyDockHorizontalLayout: Bool {
        get { self[PickyHUDDockHorizontalLayoutKey.self] }
        set { self[PickyHUDDockHorizontalLayoutKey.self] = newValue }
    }
}

// MARK: - Shared group folder glyph

/// Group identity that survives a dock with no room for names: the group color
/// on a folder that is filled while collapsed and outlined while expanded,
/// plus the collapsed unread mark.
///
/// Shared by the compact vertical header's icon lane and the bounded
/// horizontal header cell, so both read the same unread rule: per-Pickle marks
/// live on the member rows, and the folder only summarises them while those
/// rows are hidden.
struct PickyHUDDockGroupFolderGlyph: View {
    let group: PickyDockGroup
    /// See `PickyHUDDockRowStatusPresentation.groupUnreadCount`.
    let unreadCount: Int
    /// Side of the glyph's own slot, matched to the row action size.
    let side: CGFloat
    let unreadDotSide: CGFloat
    let badgeAlignment: Alignment
    let badgeOffset: CGSize

    private var showsUnreadBadge: Bool { group.isCollapsed && unreadCount > 0 }

    var body: some View {
        Image(systemName: group.isCollapsed ? "folder.fill" : "folder")
            .font(PickyHUDTypography.supporting)
            .foregroundStyle(group.color.accent)
            .frame(width: side, height: side)
            .overlay(alignment: badgeAlignment) {
                if showsUnreadBadge {
                    Circle()
                        .fill(DS.Colors.notification)
                        .frame(width: unreadDotSide, height: unreadDotSide)
                        .offset(x: badgeOffset.width, y: badgeOffset.height)
                }
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
