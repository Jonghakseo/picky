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

/// Compact icon button that floats at the corner of a message bubble. The
/// button itself is small (~18pt) and uses the same arrow-square glyph as the
/// existing footer chip (`PickyOpenAsReportButton`) so the affordance stays
/// recognizable across both surfaces.
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
    /// Reveals a small "open as report" icon at the specified corner of the
    /// bubble while the user hovers over it. Pass `nil` for `onOpen` to disable
    /// the affordance (e.g. for messages without text content).
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

    @State private var isBubbleHovered = false

    func body(content: Content) -> some View {
        content
            .overlay(alignment: alignment) {
                if let onOpen, isBubbleHovered {
                    PickyOpenAsReportHoverIcon(action: onOpen)
                        .padding(4)
                        .transition(.opacity)
                }
            }
            .onHover { hovering in
                isBubbleHovered = hovering
            }
            .animation(.easeOut(duration: 0.12), value: isBubbleHovered)
    }
}
