//
//  PickyHUDArchiveUndoToast.swift
//  Picky
//
//  Screen-level undo toast shown after archiving a HUD session.
//

import SwiftUI

struct PickyHUDArchiveUndoToast: Identifiable, Equatable {
    let id = UUID()
    let sessionID: String
    let title: String
}

enum PickyHUDArchiveUndoToastPolicy {
    static let durationNanoseconds: UInt64 = 6_000_000_000
    /// Logical size of the visible toast card used for corner placement.
    static let panelSize = CGSize(width: 304, height: 78)
    static let screenMargin: CGFloat = 18
    /// Radius/offset of the card drop shadow (see `PickyHUDArchiveUndoToastView`).
    static let shadowRadius: CGFloat = 12
    static let shadowYOffset: CGFloat = 8
    /// Transparent breathing room the host window adds around the card on all
    /// sides so the drop shadow renders without being clipped at the window
    /// bounds. The window is outset by this amount from the placed card frame.
    static let shadowInset: CGFloat = shadowRadius + shadowYOffset
    /// Full host window size, including the shadow breathing room.
    static var windowSize: CGSize {
        CGSize(
            width: panelSize.width + shadowInset * 2,
            height: panelSize.height + shadowInset * 2
        )
    }
}

enum PickyHUDArchiveUndoToastLayout {
    /// Frame for the visible toast card, centered over the HUD dock so the undo
    /// affordance always appears where the user is already looking. The result
    /// is clamped fully inside `visibleFrame` with a standard margin. The toast
    /// panel's window level sits above the dock, so overlapping the dock is
    /// intended and keeps the affordance discoverable regardless of dock side.
    ///
    /// When `dockFrame` is null (no HUD panel yet) the card falls back to the
    /// center of the visible frame.
    static func cardFrame(
        visibleFrame: CGRect,
        dockFrame: CGRect,
        cardSize: CGSize = PickyHUDArchiveUndoToastPolicy.panelSize,
        margin: CGFloat = PickyHUDArchiveUndoToastPolicy.screenMargin
    ) -> CGRect {
        let width = min(cardSize.width, max(0, visibleFrame.width - (margin * 2)))
        let height = min(cardSize.height, max(0, visibleFrame.height - (margin * 2)))
        let anchor = dockFrame.isNull ? visibleFrame : dockFrame
        var x = anchor.midX - (width / 2)
        var y = anchor.midY - (height / 2)
        x = min(max(x, visibleFrame.minX + margin), visibleFrame.maxX - width - margin)
        y = min(max(y, visibleFrame.minY + margin), visibleFrame.maxY - height - margin)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PickyHUDArchiveUndoToastPanelRoot: View {
    let toast: PickyHUDArchiveUndoToast
    let onUndo: () -> Void

    var body: some View {
        PickyHUDArchiveUndoToastView(toast: toast, onUndo: onUndo)
            .frame(
                width: PickyHUDArchiveUndoToastPolicy.panelSize.width,
                height: PickyHUDArchiveUndoToastPolicy.panelSize.height,
                alignment: .center
            )
            .padding(PickyHUDArchiveUndoToastPolicy.shadowInset)
            .frame(
                width: PickyHUDArchiveUndoToastPolicy.windowSize.width,
                height: PickyHUDArchiveUndoToastPolicy.windowSize.height,
                alignment: .center
            )
            .transition(.opacity.combined(with: .move(edge: .trailing)))
    }
}

struct PickyHUDArchiveUndoToastView: View {
    let toast: PickyHUDArchiveUndoToast
    let onUndo: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "archivebox.fill")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.warningText)
                .frame(width: 22, height: 22)
                .background(Circle().fill(DS.Colors.warning.opacity(0.15)))

            VStack(alignment: .leading, spacing: 1) {
                Text("hud.archiveToast.title")
                    .pickyFont(size: 11.5, weight: .semibold, design: .rounded)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(toast.title)
                    .pickyFont(size: 10, weight: .medium, design: .rounded)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 128, alignment: .leading)

            Button("hud.archiveToast.undo", action: onUndo)
                .buttonStyle(.plain)
                .pickyFont(size: 10.5, weight: .semibold, design: .rounded)
                .foregroundColor(DS.Colors.accentText)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Colors.accentText.opacity(0.12))
                        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.accentText.opacity(0.24), lineWidth: 0.7))
                )
                .hoverAffordance()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            PickyHUDMaterialFill(
                    shape: RoundedRectangle(cornerRadius: 15, style: .continuous),
                    fallback: DS.Colors.surface1
                )
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(DS.Colors.surface1.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8))
        )
        .shadow(
            color: Color.black.opacity(0.18),
            radius: PickyHUDArchiveUndoToastPolicy.shadowRadius,
            x: 0,
            y: PickyHUDArchiveUndoToastPolicy.shadowYOffset
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session archived. Undo available.")
    }
}
