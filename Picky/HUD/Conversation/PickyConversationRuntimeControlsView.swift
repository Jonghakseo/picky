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
                .buttonStyle(.plain)
                .help(L10n.t("hud.composer.runtime.model.help"))
                .accessibilityLabel(presentation.modelLabel ?? modelText)
                .accessibilityHint(L10n.t("hud.composer.runtime.model.accessibilityHint"))
                .hoverAffordance()
            }
            if let thinkingText = presentation.thinkingText {
                Button(action: onCycleThinkingLevel) {
                    controlLabel(icon: "brain", text: thinkingText)
                }
                .buttonStyle(.plain)
                .help(L10n.t("hud.composer.runtime.thinking.help"))
                .accessibilityLabel(presentation.thinkingLabel ?? thinkingText)
                .accessibilityHint(L10n.t("hud.composer.runtime.thinking.accessibilityHint"))
                .hoverAffordance()
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
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .contentShape(Rectangle())
    }
}

enum PickyComposerToolbarMetrics {
    static let controlSize = DS.Spacing.space6 + DS.Spacing.space1
    static let modelLabelMaximumWidth: CGFloat = 126 // design-token-exception: keeps long runtime model IDs inside the fixed 446pt Composer row
}
