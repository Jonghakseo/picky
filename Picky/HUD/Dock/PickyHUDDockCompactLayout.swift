//
//  PickyHUDDockCompactLayout.swift
//  Picky
//
//  Placement contract for the compact (edge-hugging) vertical dock. A row
//  keeps the selected S/M/L width at all times and splits into two lanes: a
//  fixed icon lane pinned to the dock's screen edge, and a label lane that the
//  shell reveals by widening its clip. Rows never animate their own layout.
//

import SwiftUI

/// How a list row arranges its fixed icon lane and its label lane while the
/// dock is in compact mode.
///
/// `nil` in the environment means the classic dock: rows keep their original
/// single-lane layout, paddings, and hit-test holes.
///
/// The row itself always lays out at the preset's `listWidth`. Resting width
/// comes from the shell clipping everything except `iconColumnWidth` at the
/// screen edge, so expanding is a clip animation on one container instead of a
/// width animation on every row. That is also why `isExpanded` may flip a
/// frame before the shell starts moving: the only thing it changes inside a row
/// is whether label-lane *controls* exist, never the row's geometry.
struct PickyHUDDockCompactLayout: Equatable {
    /// Lane that stays visible while the dock rests. Sized for the row glyph
    /// plus its badge, and matched by the shell's resting clip width.
    static let iconColumnWidth: CGFloat = 36

    /// Gap between the icon lane and the nearest label-lane content. The icon
    /// lane owns its full width, so this is the only breathing room between a
    /// title and the glyph column.
    static let labelLaneGap: CGFloat = 4

    /// True while the shell is widened to the preset's full list width.
    var isExpanded: Bool

    /// True when the dock hugs the left screen edge: the icon lane is the row's
    /// leading edge and labels extend trailing. Mirrored for a right-edge dock.
    var iconOnLeadingEdge: Bool

    /// Label-lane content is only reachable once the shell actually shows it.
    /// Controls gated on this never become stray hover, click, keyboard, or
    /// VoiceOver targets behind the clip.
    var showsLabels: Bool { isExpanded }

    /// Leading padding of the label lane's own content.
    func labelLeadingPadding(outer: CGFloat) -> CGFloat {
        iconOnLeadingEdge ? Self.labelLaneGap : outer
    }

    /// Trailing padding of the label lane's own content.
    func labelTrailingPadding(outer: CGFloat) -> CGFloat {
        iconOnLeadingEdge ? outer : Self.labelLaneGap
    }

    /// Distance from the *row's* leading edge to the first label-lane control.
    /// Click-host holes are measured from the row's bounds, so they have to add
    /// the icon lane back in when it sits on that side.
    func rowLeadingInset(outer: CGFloat) -> CGFloat {
        iconOnLeadingEdge ? Self.iconColumnWidth + Self.labelLaneGap : outer
    }

    /// Distance from the row's trailing edge to the last label-lane control.
    func rowTrailingInset(outer: CGFloat) -> CGFloat {
        iconOnLeadingEdge ? outer : Self.iconColumnWidth + Self.labelLaneGap
    }

    /// Corner an icon-lane badge hugs. Always the side facing the labels, so a
    /// badge can never be sliced by the shell's resting clip edge or bleed over
    /// the screen-edge border.
    var badgeAlignment: Alignment { iconOnLeadingEdge ? .topTrailing : .topLeading }

    /// Pushes the badge further away from the clip edge, in the same direction.
    func badgeOffset(_ distance: CGFloat) -> CGSize {
        CGSize(width: iconOnLeadingEdge ? distance : -distance, height: -1)
    }
}

// MARK: - Environment

private struct PickyHUDDockCompactLayoutKey: EnvironmentKey {
    static let defaultValue: PickyHUDDockCompactLayout? = nil
}

extension EnvironmentValues {
    /// Compact placement for list rows, group headers, and group placeholders.
    /// `nil` (the default) keeps every row exactly as the classic dock draws it.
    var pickyDockCompactLayout: PickyHUDDockCompactLayout? {
        get { self[PickyHUDDockCompactLayoutKey.self] }
        set { self[PickyHUDDockCompactLayoutKey.self] = newValue }
    }
}

// MARK: - Lane container

/// Two-lane arrangement shared by rows, group headers, and the empty-group
/// placeholder: a fixed-width icon lane at the dock's screen edge and a label
/// lane that takes the rest of the row.
struct PickyHUDDockCompactLanes<Icon: View, Label: View>: View {
    let layout: PickyHUDDockCompactLayout
    @ViewBuilder let icon: () -> Icon
    @ViewBuilder let label: () -> Label

    var body: some View {
        HStack(spacing: 0) {
            if layout.iconOnLeadingEdge {
                iconLane
                labelLane
            } else {
                labelLane
                iconLane
            }
        }
    }

    private var iconLane: some View {
        icon().frame(width: PickyHUDDockCompactLayout.iconColumnWidth)
    }

    private var labelLane: some View {
        label().frame(maxWidth: .infinity, alignment: .leading)
    }
}
