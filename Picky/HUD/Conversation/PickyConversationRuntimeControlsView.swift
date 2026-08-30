//
//  PickyConversationRuntimeControlsView.swift
//  Picky
//
//  Runtime model and thinking controls for the conversation composer.
//

import SwiftUI

struct PickyConversationRuntimeControlsView: View {
    let presentation: PickyComposerRuntimePresentation
    let heightTier: PickyConversationFocusStackHeightTier
    let actionError: String?
    let onCycleModel: () -> Void
    let onCycleThinkingLevel: () -> Void

    @ViewBuilder
    var body: some View {
        if presentation.hasControls || actionError != nil {
            controls
        }
    }

    private var controls: some View {
        HStack(spacing: DS.Spacing.space1) {
            if let modelText = presentation.modelText {
                Button(action: onCycleModel) {
                    controlLabel(
                        icon: "cpu",
                        text: modelText,
                        maximumTextWidth: PickyComposerToolbarMetrics.modelLabelMaximumWidth
                    )
                }
                .buttonStyle(PickyComposerToolbarGhostButtonStyle())
                .help(L10n.t("hud.composer.runtime.model.help"))
                .accessibilityLabel(presentation.modelLabel ?? modelText)
                .accessibilityHint(L10n.t("hud.composer.runtime.model.accessibilityHint"))
            }
            if let thinkingText = presentation.thinkingText {
                Button(action: onCycleThinkingLevel) {
                    controlLabel(icon: "brain", text: thinkingText)
                }
                .buttonStyle(PickyComposerToolbarGhostButtonStyle())
                .help(L10n.t("hud.composer.runtime.thinking.help"))
                .accessibilityLabel(presentation.thinkingLabel ?? thinkingText)
                .accessibilityHint(L10n.t("hud.composer.runtime.thinking.accessibilityHint"))
            }
            if let actionError {
                Label(L10n.t("hud.composer.runtime.failed", actionError), systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.iconOnly)
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(DS.Colors.destructiveText)
                    .help(actionError)
                    .accessibilityLabel(L10n.t("hud.composer.runtime.failed", actionError))
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.composer.runtime.accessibilityLabel"))
    }

    private func controlLabel(
        icon: String,
        text: String,
        maximumTextWidth: CGFloat? = nil
    ) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(PickyHUDTypography.statusSemibold)
            if heightTier == .regular {
                Text(text)
                    .font(PickyHUDTypography.meta)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: maximumTextWidth)
            }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .padding(.horizontal, DS.Spacing.space2)
        .frame(height: PickyComposerToolbarMetrics.controlSize)
        .contentShape(Rectangle())
    }
}

struct PickyComposerToolbarGhostButtonStyle: ButtonStyle {
    var isActive = false

    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(backgroundColor(isPressed: configuration.isPressed))
            )
            .animation(.easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(.easeOut(duration: DS.Animation.fast), value: isHovered)
            .onHover { isHovered = isEnabled && $0 }
    }

    private func backgroundColor(isPressed: Bool) -> Color {
        if !isEnabled {
            return .clear
        }
        if isPressed {
            return DS.Colors.surface4
        }
        if isHovered {
            return DS.Colors.surface3
        }
        return isActive ? DS.Colors.accentSubtle : .clear
    }
}

enum PickyComposerToolbarMetrics {
    static let controlSize = DS.Spacing.space6 + DS.Spacing.space1
    static let modelLabelMaximumWidth: CGFloat = 126 // design-token-exception: keeps long runtime model IDs inside the fixed 446pt Composer row
}
