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
    static let panelSize = CGSize(width: 304, height: 78)
    static let screenMargin: CGFloat = 18
}

enum PickyHUDArchiveUndoToastLayout {
    /// Screen corners are named from the user's reading direction: `leading`
    /// is the visible frame's minimum X and `top` is its maximum Y in AppKit
    /// screen coordinates.
    enum Anchor: Equatable {
        case bottomLeading
        case bottomTrailing
        case topLeading
        case topTrailing
    }

    /// Prefer the corner opposite the dock: right → bottom-leading, left →
    /// bottom-trailing, bottom → top-trailing, top → bottom-trailing. If the
    /// preferred corner is occupied by the current HUD panel, continue around
    /// the remaining corners on that side before accepting an overlap.
    static func anchor(
        dockSide: PickyHUDDockSide,
        dockFrame: CGRect,
        visibleFrame: CGRect,
        panelSize: CGSize = PickyHUDArchiveUndoToastPolicy.panelSize
    ) -> Anchor {
        let candidates: [Anchor]
        switch dockSide {
        case .right:
            candidates = [.bottomLeading, .topLeading, .bottomTrailing, .topTrailing]
        case .left:
            candidates = [.bottomTrailing, .topTrailing, .bottomLeading, .topLeading]
        case .bottom:
            candidates = [.topTrailing, .topLeading, .bottomTrailing, .bottomLeading]
        case .top:
            candidates = [.bottomTrailing, .bottomLeading, .topTrailing, .topLeading]
        }

        return candidates.first {
            !dockFrame.intersects(panelFrame(visibleFrame: visibleFrame, anchor: $0, panelSize: panelSize))
        } ?? candidates[0]
    }

    static func panelFrame(
        visibleFrame: CGRect,
        dockSide: PickyHUDDockSide,
        dockFrame: CGRect,
        panelSize: CGSize = PickyHUDArchiveUndoToastPolicy.panelSize
    ) -> CGRect {
        panelFrame(
            visibleFrame: visibleFrame,
            anchor: anchor(
                dockSide: dockSide,
                dockFrame: dockFrame,
                visibleFrame: visibleFrame,
                panelSize: panelSize
            ),
            panelSize: panelSize
        )
    }

    /// Compatibility fallback for callers without HUD placement context.
    static func panelFrame(visibleFrame: CGRect, panelSize: CGSize = PickyHUDArchiveUndoToastPolicy.panelSize) -> CGRect {
        panelFrame(visibleFrame: visibleFrame, anchor: .bottomTrailing, panelSize: panelSize)
    }

    private static func panelFrame(visibleFrame: CGRect, anchor: Anchor, panelSize: CGSize) -> CGRect {
        let margin = PickyHUDArchiveUndoToastPolicy.screenMargin
        let width = min(panelSize.width, max(0, visibleFrame.width - (margin * 2)))
        let height = min(panelSize.height, max(0, visibleFrame.height - (margin * 2)))
        let x: CGFloat
        let y: CGFloat
        switch anchor {
        case .bottomLeading:
            x = visibleFrame.minX + margin
            y = visibleFrame.minY + margin
        case .bottomTrailing:
            x = visibleFrame.maxX - width - margin
            y = visibleFrame.minY + margin
        case .topLeading:
            x = visibleFrame.minX + margin
            y = visibleFrame.maxY - height - margin
        case .topTrailing:
            x = visibleFrame.maxX - width - margin
            y = visibleFrame.maxY - height - margin
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }
}

struct PickyHUDArchiveUndoToastPanelRoot: View {
    let toast: PickyHUDArchiveUndoToast
    let onUndo: () -> Void

    var body: some View {
        PickyHUDArchiveUndoToastView(toast: toast, onUndo: onUndo)
            .padding(16)
            .frame(
                width: PickyHUDArchiveUndoToastPolicy.panelSize.width,
                height: PickyHUDArchiveUndoToastPolicy.panelSize.height,
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
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session archived. Undo available.")
    }
}
