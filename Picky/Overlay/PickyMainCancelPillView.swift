//
//  PickyMainCancelPillView.swift
//  Picky
//

import SwiftUI

struct PickyMainCancelPillView: View {
    @ObservedObject var viewModel: PickyMainCancelPillViewModel
    let onHoverChanged: (Bool) -> Void
    let onCancel: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var state: PickyMainCancelPillState { viewModel.state }

    var body: some View {
        VStack(spacing: 5) {
            Button(action: onCancel) {
                pillLabel
                    .padding(.horizontal, 13)
                    .frame(minHeight: 30)
                    .background(Capsule(style: .continuous).fill(backgroundColor))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(borderColor, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .scaleEffect(state == .hover ? 1.05 : 1)
            .onHover(perform: onHoverChanged)
            .accessibilityLabel(Text(L10n.t("overlay.mainCancel.accessibility")))
            .help(L10n.t("overlay.mainCancel.accessibility"))

            if state == .rest {
                caption
            }
        }
        .fixedSize()
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: state)
    }

    @ViewBuilder
    private var pillLabel: some View {
        switch state {
        case .rest:
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text(L10n.t("overlay.mainCancel.stop"))
            }
            .font(.system(size: 12, weight: .medium))
        case .hover:
            Text(L10n.t("overlay.mainCancel.clickToStop"))
                .font(.system(size: 12, weight: .medium))
        case .escapeArmed:
            HStack(spacing: 5) {
                keycap
                Text(L10n.t("overlay.mainCancel.escapeArmed"))
            }
            .font(.system(size: 12, weight: .medium))
        case .cancelled:
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(Color(hex: "#CFE1FF").opacity(0.6))
                    .frame(width: 8, height: 8)
                Text(L10n.t("overlay.mainCancel.cancelled"))
            }
            .font(.system(size: 12, weight: .medium))
        }
    }

    private var caption: some View {
        HStack(spacing: 4) {
            Text(L10n.t("overlay.mainCancel.escapeHintPrefix"))
            keycap
            Text(L10n.t("overlay.mainCancel.escapeHintSuffix"))
        }
        .font(.system(size: 10.5, weight: .regular))
        .foregroundStyle(Color(hex: "#CFE1FF").opacity(0.55))
        .accessibilityHidden(true)
    }

    private var keycap: some View {
        Text(L10n.t("overlay.mainCancel.escapeKey"))
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(.white.opacity(0.07))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .stroke(.white.opacity(0.18), lineWidth: 0.8)
            )
    }

    private var backgroundColor: Color {
        switch state {
        case .rest:
            DS.Colors.overlayCursorBlue.opacity(0.28)
        case .hover, .escapeArmed:
            DS.Colors.overlayCursorBlue.opacity(0.55)
        case .cancelled:
            Color(hex: "#0A1423").opacity(0.72)
        }
    }

    private var borderColor: Color {
        switch state {
        case .rest:
            Color(hex: "#7FB2FF").opacity(0.5)
        case .hover:
            Color(hex: "#7FB2FF").opacity(0.95)
        case .escapeArmed:
            Color(hex: "#7FB2FF")
        case .cancelled:
            Color(hex: "#CFE1FF").opacity(0.22)
        }
    }
}
