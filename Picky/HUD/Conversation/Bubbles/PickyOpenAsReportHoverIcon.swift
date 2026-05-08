//
//  PickyOpenAsReportHoverIcon.swift
//  Picky
//
//  Hover-revealed corner button that opens a single conversation message in the
//  full markdown report viewer. Used by user and agent bubble views so any
//  text-bearing message can be expanded on demand without permanently adding a
//  visible action chip to every bubble.
//

import SwiftUI

/// Compact icon button that floats just outside the corner of a message bubble.
/// The button itself is small (~20pt) and uses the SF Symbol arrow-square glyph
/// commonly associated with "open in a separate window/view".
///
/// This is the only "open as report" affordance in the conversation card after
/// the latest-reply footer chip was removed; every truncated text-bearing
/// message uses it to expand into the full markdown viewer.
struct PickyOpenAsReportHoverIcon: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "arrow.up.right.square")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.accentText.opacity(0.95))
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(DS.Colors.surface1.opacity(0.95))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .stroke(DS.Colors.accentText.opacity(0.28), lineWidth: 0.5)
                )
        }
        .buttonStyle(.plain)
        .help("Open this message as report")
        .pointerCursor()
    }
}

extension View {
    /// Reveals a small "open as report" icon just OUTSIDE the bubble's specified
    /// corner while the user hovers over either the bubble or the icon itself.
    /// Pass `nil` for `onOpen` to disable the affordance (e.g. for messages
    /// whose preview isn't truncated and so don't need an expand action).
    func openAsReportHoverIcon(
        onOpen: (() -> Void)?,
        alignment: Alignment = .topTrailing
    ) -> some View {
        modifier(PickyOpenAsReportHoverIconModifier(onOpen: onOpen, alignment: alignment))
    }
}

private struct PickyOpenAsReportHoverIconModifier: ViewModifier {
    let onOpen: (() -> Void)?
    let alignment: Alignment

    /// Two separate hover trackers because the icon sits OUTSIDE the bubble's
    /// frame via `.offset`, so cursor moves between bubble → icon would
    /// otherwise see a brief gap where neither view is hovered. ORing both
    /// keeps the icon visible while the cursor is over either surface.
    @State private var isBubbleHovered = false
    @State private var isIconHovered = false

    private var shouldShowIcon: Bool { isBubbleHovered || isIconHovered }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let onOpen, shouldShowIcon {
                    PickyOpenAsReportHoverIcon(action: onOpen)
                        .onHover { hovering in isIconHovered = hovering }
                        .offset(iconOffset)
                        .transition(.opacity)
                }
            }
            .onHover { hovering in isBubbleHovered = hovering }
            .animation(.easeOut(duration: 0.12), value: shouldShowIcon)
    }

    /// Pushes the icon a few points beyond the bubble's edge so it visibly
    /// sits OUTSIDE the corner rather than overlapping the bubble's painted
    /// area. The vertical nudge is matched on both sides so the icon's
    /// vertical centerline lines up with the bubble's top edge regardless of
    /// which corner alignment was requested.
    private var iconOffset: CGSize {
        switch alignment {
        case .topLeading:
            return CGSize(width: -12, height: -12)
        case .topTrailing:
            return CGSize(width: 12, height: -12)
        default:
            return .zero
        }
    }
}
