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

/// Compact icon button that sits just inside the corner of a message bubble.
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
    /// Reveals a small "open as report" icon just INSIDE the bubble's specified
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

private extension HoverPhase {
    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

private struct PickyOpenAsReportHoverIconModifier: ViewModifier {
    let onOpen: (() -> Void)?
    let alignment: Alignment

    /// Two separate hover trackers because the icon sits inside the corner
    /// via `.offset` and SwiftUI's overlay can briefly report no-hover during
    /// rapid pointer transitions between bubble and icon. ORing both keeps
    /// the icon visible while the cursor is over either surface.
    @State private var isBubbleHovered = false
    @State private var isIconHovered = false

    private var shouldShowIcon: Bool { isBubbleHovered || isIconHovered }

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let onOpen, shouldShowIcon {
                    PickyOpenAsReportHoverIcon(action: onOpen)
                        .onContinuousHover { phase in
                            isIconHovered = phase.isActive
                        }
                        .offset(iconOffset)
                        .transition(.opacity)
                }
            }
            // Bubble background is drawn via `.background(...)` which doesn't
            // contribute to SwiftUI hit-testing on its own. Without an explicit
            // contentShape the bubble's empty padding/whitespace falls into a
            // hit-test gap, so hover only fires while the cursor is over
            // the inline Text glyphs. Filling the modified frame with a
            // Rectangle contentShape keeps the entire bubble hover-detectable
            // while child views still win their own hits first (text
            // selection, contextMenu).
            .contentShape(Rectangle())
            // `onContinuousHover` instead of `onHover`: the bubble body uses
            // `.textSelection(.enabled)` which backs the Text views with an
            // NSTextView whose own NSTrackingArea swallows the parent's
            // enter/exit events. `onHover` therefore only fires when the
            // cursor lands on the small padding margin around the text, which
            // users almost never hit. `onContinuousHover` polls the pointer
            // position continuously and reports `.active` even while the
            // cursor sits over selectable glyphs, so the affordance shows up
            // as soon as the bubble is hovered.
            .onContinuousHover { phase in
                isBubbleHovered = phase.isActive
            }
            .animation(.easeOut(duration: 0.12), value: shouldShowIcon)
    }

    /// Inset the icon so it sits visibly INSIDE the bubble's corner with a
    /// small margin. Previously the icon was nudged OUTSIDE the bubble which
    /// made it both visually disconnected and easy to miss with the cursor.
    /// Inset values are negative on the trailing axis (move left from the
    /// trailing edge) and positive on the vertical axis (move down from the
    /// top edge) so the icon hugs the corner without crossing it.
    private var iconOffset: CGSize {
        switch alignment {
        case .topLeading:
            return CGSize(width: 4, height: 4)
        case .topTrailing:
            return CGSize(width: -4, height: 4)
        default:
            return .zero
        }
    }
}
