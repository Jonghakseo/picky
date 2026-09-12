//
//  PickyHubPluginDetailDialog.swift
//  Picky
//

import SwiftUI

struct PickyHubPluginDetailDialog: View {
    private let initialItem: PickyHubPluginItem
    private let onInstall: () -> Void
    private let onRemove: () -> Void
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @EnvironmentObject private var pluginCatalog: PickyHubPluginCatalogViewModel
    @State private var confirmsRemoval = false

    init(item: PickyHubPluginItem, onInstall: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.initialItem = item
        self.onInstall = onInstall
        self.onRemove = onRemove
    }

    private var item: PickyHubPluginItem {
        pluginCatalog.item(id: initialItem.id) ?? initialItem
    }

    private var meta: String {
        var parts = [item.metadata.category.title, item.metadata.provider]
        if let version = item.installedVersion {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubModalHeader(meta: meta, title: item.title, onClose: { modalHost.dismiss() })

            Text(item.summary)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
                .padding(.top, PickyHubTheme.Spacing.field)

            Text("hub.plugins.detail.useCases")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, PickyHubTheme.Spacing.group)

            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                ForEach(item.useCases, id: \.self) { useCase in
                    Label(useCase, systemImage: "circle.fill")
                        .labelStyle(PickyHubPluginUseCaseLabelStyle())
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                }
            }
            .pickyHubSelectableText()
            .padding(.top, PickyHubTheme.Spacing.related)

            HStack(spacing: PickyHubTheme.Spacing.related) {
                PickyHubBadgePill(text: item.isInstalled ? L10n.t("hub.plugins.detail.installed") : L10n.t("hub.plugins.detail.notInstalled"))
                if item.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("hub.plugins.detail.actionInProgress"))
                }
            }
            .padding(.top, PickyHubTheme.Spacing.group)

            if let error = item.errorMessage {
                PickyHubInlineStatus(tone: .error, message: error)
                    .padding(.top, PickyHubTheme.Spacing.field)
            }

            if confirmsRemoval {
                inlineRemovalConfirmation
                    .padding(.top, PickyHubTheme.Spacing.field)
            }

            actionRow
                .padding(.top, PickyHubTheme.Spacing.group)
                .overlay(alignment: .top) {
                    Rectangle()
                        .fill(PickyHubTheme.Colors.borderSoft)
                        .frame(height: 1)
                }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
    }

    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actionLayout(isVertical: false)
            actionLayout(isVertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func actionLayout(isVertical: Bool) -> some View {
        if isVertical {
            VStack(alignment: .trailing, spacing: PickyHubTheme.Spacing.related) {
                PickyHubButton(title: "hub.plugins.detail.done", role: .secondary, action: { modalHost.dismiss() })
                mutationButton
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        } else {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Spacer(minLength: 0)
                PickyHubButton(title: "hub.plugins.detail.done", role: .secondary, action: { modalHost.dismiss() })
                mutationButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    @ViewBuilder
    private var mutationButton: some View {
        if item.isInstalled {
            PickyHubButton(
                title: confirmsRemoval ? "hub.plugins.detail.confirmRemove" : "hub.plugins.detail.remove",
                role: .danger,
                isBusy: item.isBusy,
                action: { confirmsRemoval ? remove() : (confirmsRemoval = true) }
            )
        } else {
            PickyHubButton(
                title: "hub.plugins.detail.install",
                role: .primary,
                isBusy: item.isBusy,
                action: onInstall
            )
        }
    }

    private var inlineRemovalConfirmation: some View {
        ViewThatFits(in: .horizontal) {
            removalConfirmationLayout(isVertical: false)
            removalConfirmationLayout(isVertical: true)
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .pickyHubCard(fill: PickyHubTheme.Colors.dangerTint, border: PickyHubTheme.Colors.danger)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func removalConfirmationLayout(isVertical: Bool) -> some View {
        if isVertical {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                removalPrompt
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    PickyHubButton(title: "common.cancel", role: .secondary, action: { confirmsRemoval = false })
                    PickyHubButton(title: "hub.plugins.detail.remove", role: .danger, isBusy: item.isBusy, action: remove)
                }
            }
        } else {
            HStack(alignment: .center, spacing: PickyHubTheme.Spacing.related) {
                removalPrompt
                Spacer(minLength: PickyHubTheme.Spacing.related)
                PickyHubButton(title: "common.cancel", role: .secondary, action: { confirmsRemoval = false })
                PickyHubButton(title: "hub.plugins.detail.remove", role: .danger, isBusy: item.isBusy, action: remove)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var removalPrompt: some View {
        Text("hub.plugins.detail.remove.prompt")
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            .pickyHubSelectableText()
    }

    private func remove() {
        confirmsRemoval = false
        onRemove()
    }
}

private struct PickyHubPluginUseCaseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
            configuration.icon
                .pickyFont(size: 5, weight: .semibold)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
