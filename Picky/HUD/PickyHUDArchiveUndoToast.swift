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
    static func panelFrame(visibleFrame: CGRect, panelSize: CGSize = PickyHUDArchiveUndoToastPolicy.panelSize) -> CGRect {
        let margin = PickyHUDArchiveUndoToastPolicy.screenMargin
        let width = min(panelSize.width, max(0, visibleFrame.width - (margin * 2)))
        let height = min(panelSize.height, max(0, visibleFrame.height - (margin * 2)))
        return CGRect(
            x: visibleFrame.maxX - width - margin,
            y: visibleFrame.minY + margin,
            width: width,
            height: height
        )
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
                .pointerCursor()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(DS.Colors.surface1.opacity(0.28)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.8))
        )
        .shadow(color: Color.black.opacity(0.18), radius: 12, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session archived. Undo available.")
    }
}
