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
                .padding(.top, 18)

            Text("hub.plugins.detail.useCases")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .padding(.top, 20)

            VStack(alignment: .leading, spacing: 7) {
                ForEach(item.useCases, id: \.self) { useCase in
                    Label(useCase, systemImage: "circle.fill")
                        .labelStyle(PickyHubPluginUseCaseLabelStyle())
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                }
            }
            .padding(.top, 8)

            HStack(spacing: 8) {
                PickyHubBadgePill(text: item.isInstalled ? L10n.t("hub.plugins.detail.installed") : L10n.t("hub.plugins.detail.notInstalled"))
                if item.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(Text("hub.plugins.detail.actionInProgress"))
                }
            }
            .padding(.top, 20)

            if let error = item.errorMessage {
                PickyHubInlineStatus(tone: .error, message: error)
                    .padding(.top, 16)
            }

            if confirmsRemoval {
                inlineRemovalConfirmation
                    .padding(.top, 16)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                PickyHubButton(title: "hub.plugins.detail.done", role: .secondary, action: { modalHost.dismiss() })
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
            .padding(.top, 22)
            .padding(.top, 15)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(PickyHubTheme.Colors.borderSoft)
                    .frame(height: 1)
            }
        }
        .padding(20)
    }

    private var inlineRemovalConfirmation: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("hub.plugins.detail.remove.prompt")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Spacer(minLength: 8)
            PickyHubButton(title: "common.cancel", role: .secondary, action: { confirmsRemoval = false })
            PickyHubButton(title: "hub.plugins.detail.remove", role: .danger, isBusy: item.isBusy, action: remove)
        }
        .padding(12)
        .pickyHubCard(fill: PickyHubTheme.Colors.dangerTint, border: PickyHubTheme.Colors.danger)
        .accessibilityElement(children: .contain)
    }

    private func remove() {
        confirmsRemoval = false
        onRemove()
    }
}

private struct PickyHubPluginUseCaseLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon
                .pickyFont(size: 5, weight: .bold)
                .accessibilityHidden(true)
            configuration.title
        }
    }
}
