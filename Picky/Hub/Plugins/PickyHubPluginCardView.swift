//
//  PickyHubPluginCardView.swift
//  Picky
//

import SwiftUI

struct PickyHubPluginCardView: View {
    let item: PickyHubPluginItem
    let onDetail: () -> Void
    let onInstall: () -> Void
    let onRemove: () -> Void
    let onUpdate: () -> Void
    let onViewCronJobs: () -> Void
    let onSetupCronDaemon: () -> Void
    @FocusState.Binding var focusedControl: String?
    @State private var isHoveringInstalledAction = false

    private var detailControlID: String { "\(item.id).detail" }
    private var actionControlID: String { "\(item.id).action" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Image(systemName: item.metadata.systemImage)
                    .pickyFont(size: 18, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.action)
                    .frame(width: 34, height: 34)
                    .background(
                        RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous)
                            .fill(PickyHubTheme.Colors.actionTint)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous)
                            .stroke(PickyHubTheme.Colors.action.opacity(0.28), lineWidth: 1)
                    )
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                if item.isInstalled {
                    PickyHubBadgePill(text: L10n.t("hub.plugins.detail.installed"))
                }
            }

            Text(item.title)
                .pickyFont(size: 16, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .lineLimit(2)
                .padding(.top, 14)

            Text(item.summary)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)

            Text(meta)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .lineLimit(1)
                .padding(.top, 11)

            if let error = item.errorMessage {
                PickyHubInlineStatus(tone: .error, message: error)
                    .padding(.top, 10)
            }

            Spacer(minLength: 15)

            actionRow
                .padding(.top, 15)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 208, alignment: .topLeading)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(item.title))
    }

    private var meta: String {
        var parts = [item.metaLine]
        if let version = item.installedVersion {
            parts.append("v\(version)")
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder
    private var actionRow: some View {
        if item.plugin.kind == .cron, item.isInstalled {
            HStack(spacing: 7) {
                detailButton
                PickyHubButton(title: "hub.plugins.card.viewJobs", role: .secondary, action: onViewCronJobs)
                cronMenu
            }
        } else {
            HStack(spacing: 7) {
                detailButton
                if item.isInstalled {
                    if item.hasUpdate {
                        PickyHubButton(title: "hub.plugins.card.update", role: .secondary, isBusy: item.isBusy, action: onUpdate)
                    }
                    installedAction
                } else {
                    PickyHubButton(title: "hub.plugins.card.install", role: .primary, isBusy: item.isBusy, action: onInstall)
                        .focused($focusedControl, equals: actionControlID)
                }
            }
        }
    }

    private var detailButton: some View {
        PickyHubButton(title: "hub.plugins.card.detail", role: .secondary, action: onDetail)
            .focused($focusedControl, equals: detailControlID)
    }

    private var installedAction: some View {
        PickyHubButton(
            title: isHoveringInstalledAction ? "hub.plugins.card.remove" : "hub.plugins.detail.installed",
            role: .danger,
            isBusy: item.isBusy,
            action: onRemove
        )
        .focused($focusedControl, equals: actionControlID)
        .onHover { isHoveringInstalledAction = $0 }
        .accessibilityLabel(Text(L10n.t("hub.plugins.card.remove", item.title)))
    }

    private var cronMenu: some View {
        Menu {
            Button(L10n.t("hub.plugins.card.setupDaemon"), action: onSetupCronDaemon)
            if item.hasUpdate {
                Button(L10n.t("hub.plugins.card.update"), action: onUpdate)
            }
            Divider()
            Button(L10n.t("hub.plugins.card.remove"), role: .destructive, action: onRemove)
        } label: {
            if item.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 34, height: 33)
            } else {
                Image(systemName: "ellipsis.circle")
                    .pickyFont(size: 15, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .frame(width: 34, height: 33)
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(item.isBusy)
        .help(Text("hub.plugins.card.more"))
        .accessibilityLabel(Text("hub.plugins.card.more"))
    }
}

struct PickyHubCronJobsDialog: View {
    @EnvironmentObject private var modalHost: PickyHubModalHost

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PickyHubModalHeader(
                meta: L10n.t("hub.plugins.card.cronMeta"),
                title: L10n.t("extensions.cron.jobs.title"),
                onClose: { modalHost.dismiss() }
            )
            PickyCronJobsView(onBack: { modalHost.dismiss() })
        }
        .padding(20)
    }
}
