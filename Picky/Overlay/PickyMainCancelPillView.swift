//
//  PickyMainCancelPillView.swift
//  Picky
//

import SwiftUI

private struct PickyMainCancelPillVisibleContentFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.null

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = value.union(nextValue())
    }
}

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
                    .padding(.horizontal, 11)
                    .frame(minHeight: 26)
                    .background(
                        // Dark base under the blue tint so the pill stays
                        // legible over bright desktops (mirrors the capture
                        // context pill's opaque dark capsule).
                        ZStack {
                            Capsule(style: .continuous)
                                .fill(Color(hex: "#0A1423").opacity(0.72))
                            Capsule(style: .continuous)
                                .fill(tintColor)
                        }
                    )
                    .overlay(
                        // Keep the hairline fully within the top-aligned
                        // hosting view rather than clipping its outer half.
                        Capsule(style: .continuous)
                            .strokeBorder(borderColor, lineWidth: 0.8)
                    )
            }
            .buttonStyle(.plain)
            .contentShape(Capsule(style: .continuous))
            .onHover(perform: onHoverChanged)
            .accessibilityLabel(Text(accessibilityLabel))
            .help(accessibilityLabel)
            .background(visibleContentFrameReporter)

            if state == .rest {
                caption
                    .background(visibleContentFrameReporter)
            }
        }
        .fixedSize()
        // Top-aligned within the fixed panel so the pill row does not jump
        // vertically when the caption appears/disappears across states.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(name: "PickyMainCancelPill")
        .onPreferenceChange(PickyMainCancelPillVisibleContentFramePreferenceKey.self) {
            viewModel.visibleContentFrame = $0.insetBy(dx: -4, dy: -4)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: state)
    }

    @ViewBuilder
    private var pillLabel: some View {
        switch state {
        case .rest:
            HStack(spacing: 6) {
                stopIcon(.white)
                Text(L10n.t("overlay.mainCancel.stop"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
        case .hover:
            HStack(spacing: 6) {
                stopIcon(.white)
                Text(L10n.t("overlay.mainCancel.clickToStop"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
        case .escapeArmed:
            HStack(spacing: 6) {
                stopIcon(.white)
                HStack(spacing: 5) {
                    keycap
                    Text(L10n.t("overlay.mainCancel.escapeArmed"))
                }
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white)
        case .cancelled:
            HStack(spacing: 6) {
                stopIcon(Color(hex: "#CFE1FF").opacity(0.6))
                Text(L10n.t("overlay.mainCancel.cancelled"))
            }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(Color(hex: "#CFE1FF").opacity(0.75))
        }
    }

    private var visibleContentFrameReporter: some View {
        GeometryReader { proxy in
            Color.clear.preference(
                key: PickyMainCancelPillVisibleContentFramePreferenceKey.self,
                value: proxy.frame(in: .named("PickyMainCancelPill"))
            )
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .rest, .hover:
            L10n.t("overlay.mainCancel.accessibility")
        case .escapeArmed:
            L10n.t("overlay.mainCancel.accessibility.escapeArmed")
        case .cancelled:
            L10n.t("overlay.mainCancel.accessibility.cancelled")
        }
    }

    private func stopIcon(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var caption: some View {
        HStack(spacing: 4) {
            Text(L10n.t("overlay.mainCancel.escapeHintPrefix"))
            keycap
            Text(L10n.t("overlay.mainCancel.escapeHintSuffix"))
        }
        .font(.system(size: 10, weight: .regular))
        .foregroundStyle(Color(hex: "#CFE1FF").opacity(0.65))
        .padding(.horizontal, 7)
        .padding(.vertical, 2)
        .background(
            // Own backdrop: the caption floats over arbitrary desktops and
            // needs contrast independent of what is behind it.
            Capsule(style: .continuous)
                .fill(Color(hex: "#0A1423").opacity(0.55))
        )
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

    private var tintColor: Color {
        switch state {
        case .rest:
            DS.Colors.overlayCursorBlue.opacity(0.28)
        case .hover, .escapeArmed:
            DS.Colors.overlayCursorBlue.opacity(0.55)
        case .cancelled:
            Color.clear
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
