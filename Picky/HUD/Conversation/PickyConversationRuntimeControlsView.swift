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

    var body: some View {
        Group {
            if presentation.hasControls {
                HStack(spacing: DS.Spacing.xs) {
                    if let modelText = presentation.modelText {
                        Button(action: onCycleModel) {
                            controlLabel(icon: "cpu", text: modelText)
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
                }
                .fixedSize(horizontal: true, vertical: false)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, DS.Spacing.xs)
                .accessibilityElement(children: .contain)
                .accessibilityLabel(L10n.t("hud.composer.runtime.accessibilityLabel"))
                if let actionError {
                    Text(actionError)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.destructiveText)
                        .padding(.horizontal, DS.Spacing.xs)
                        .accessibilityLabel(L10n.t("hud.composer.runtime.failed", actionError))
                }
            }
        }
    }

    private func controlLabel(icon: String, text: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: icon)
                .font(PickyHUDTypography.statusSemibold)
            if heightTier == .regular {
                Text(text)
                    .font(PickyHUDTypography.metaMedium)
                    .lineLimit(1)
            }
        }
        .foregroundColor(DS.Colors.textSecondary)
        .contentShape(Rectangle())
    }
}
