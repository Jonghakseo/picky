//
//  PickyConversationQueueDockView.swift
//  Picky
//
//  Queue presentation for the conversation composer.
//

import SwiftUI

struct PickyConversationQueueDockView: View {
    let presentation: PickyQueueDockPresentation
    let layout: PickyQueueDockLayout
    let actionInFlight: PickyQueueDockAction?
    let actionError: String?
    let onAction: (PickyQueueDockAction) -> Void

    var body: some View {
        if presentation.isVisible {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                if layout == .inline {
                    inlineHeader
                    queueKinds(presentation.kinds, layout: layout)
                } else {
                    if layout == .stacked {
                        title
                    }
                    // Compact geometry always presents counts before mutation.
                    queueKinds(presentation.kinds, layout: layout)
                    actions
                }
                if let actionError {
                    Text(actionError)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.destructiveText)
                        .accessibilityLabel(L10n.t("hud.queue.actionFailed", actionError))
                }
            }
            .padding(DS.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .fill(DS.Colors.surface2)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel(L10n.t("hud.queue.title"))
            .accessibilityValue(presentation.accessibilityValue)
        }
    }

    private var inlineHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.xs) {
            title
            Spacer(minLength: 0)
            actions
        }
    }

    @ViewBuilder
    private func queueKinds(
        _ kinds: [PickyQueueDockKindPresentation],
        layout: PickyQueueDockLayout
    ) -> some View {
        if layout == .stacked {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                queueKindLabels(kinds)
            }
        } else {
            HStack(spacing: DS.Spacing.sm) {
                queueKindLabels(kinds)
            }
        }
    }

    private var title: some View {
        Label(L10n.t("hud.queue.title"), systemImage: "tray.full")
            .font(PickyHUDTypography.statusSemibold)
            .foregroundColor(DS.Colors.textSecondary)
    }

    @ViewBuilder
    private func queueKindLabels(_ kinds: [PickyQueueDockKindPresentation]) -> some View {
        ForEach(kinds) { item in
            Text(L10n.t("hud.queue.kindSummary", item.kind.label, Int64(item.count), item.modeLabel))
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
        }
    }

    private var actions: some View {
        HStack(spacing: DS.Spacing.sm) {
            actionButton(.restore, title: L10n.t("hud.queue.restore"), color: DS.Colors.accentText)
            actionButton(.clear, title: L10n.t("hud.queue.clear"), color: DS.Colors.textSecondary)
        }
    }

    private func actionButton(
        _ action: PickyQueueDockAction,
        title: String,
        color: Color
    ) -> some View {
        let isEnabled = action == .restore ? presentation.isRestoreEnabled : presentation.isClearEnabled
        return Button(actionInFlight == action ? action.inFlightLabel : title) {
            onAction(action)
        }
        .buttonStyle(.plain)
        .font(PickyHUDTypography.statusSemibold)
        .foregroundColor(isEnabled ? color : DS.Colors.textTertiary)
        .disabled(actionInFlight != nil || !isEnabled)
        .help(action == .restore ? presentation.restoreHelp : L10n.t("hud.queue.clear.help"))
        .accessibilityLabel(action == .restore ? presentation.restoreAccessibilityLabel : L10n.t("hud.queue.clear.accessibilityLabel"))
        .hoverAffordance()
    }
}
