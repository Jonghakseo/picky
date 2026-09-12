//
//  PickyHubPluginReloadBanner.swift
//  Picky
//

import SwiftUI

struct PickyHubPluginReloadBanner: View {
    @ObservedObject var controller: PickyPluginReloadController
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            if controller.hasPendingChanges {
                pendingCard
                if let error = controller.lastError {
                    PickyHubInlineStatus(tone: .error, message: error, actionTitle: "hub.plugins.reload.retry", action: onReload)
                }
            } else if let result = controller.lastResult {
                PickyHubInlineStatus(tone: .success, message: summary(for: result))
                    .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
                    .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
                    .pickyHubCard(fill: PickyHubTheme.Colors.successBackground, border: PickyHubTheme.Colors.success)
            }
        }
    }

    private var pendingCard: some View {
        ViewThatFits(in: .horizontal) {
            pendingLayout(isVertical: false)
            pendingLayout(isVertical: true)
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .pickyHubCard(fill: PickyHubTheme.Colors.actionTint, border: PickyHubTheme.Colors.action.opacity(0.32))
    }

    @ViewBuilder
    private func pendingLayout(isVertical: Bool) -> some View {
        if isVertical {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                reloadDetails
                reloadButton
            }
        } else {
            HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
                reloadIcon
                reloadCopy
                Spacer(minLength: PickyHubTheme.Spacing.related)
                reloadButton
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var reloadIcon: some View {
        Image(systemName: "arrow.triangle.2.circlepath")
            .pickyFont(size: 16, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.action)
            .accessibilityHidden(true)
    }

    private var reloadDetails: some View {
        HStack(alignment: .top, spacing: PickyHubTheme.Spacing.related) {
            reloadIcon
            reloadCopy
        }
    }

    private var reloadCopy: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text("hub.plugins.reload.title")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Text("hub.plugins.reload.message")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
        }
    }

    private var reloadButton: some View {
        PickyHubButton(
            title: "hub.plugins.reload.action",
            role: .primary,
            systemImage: "arrow.clockwise",
            isBusy: controller.isReloading,
            action: onReload
        )
    }

    private func summary(for result: PickyPluginsReloadedEvent) -> String {
        var fragments: [String] = []
        if result.pickyReloaded {
            fragments.append(L10n.t("status.extensions.reload.result.picky"))
        }
        if result.pickleReloadedCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleReloaded", Int64(result.pickleReloadedCount)))
        }
        if result.pickleAbortedCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleAborted", Int64(result.pickleAbortedCount)))
        }
        if result.pickleDeferredCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleDeferred", Int64(result.pickleDeferredCount)))
        }
        return fragments.isEmpty ? L10n.t("status.extensions.reload.result.nothing") : fragments.joined(separator: ", ")
    }
}
