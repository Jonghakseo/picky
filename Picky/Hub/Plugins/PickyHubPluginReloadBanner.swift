//
//  PickyHubPluginReloadBanner.swift
//  Picky
//

import SwiftUI

struct PickyHubPluginReloadBanner: View {
    @ObservedObject var controller: PickyPluginReloadController
    let onReload: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if controller.hasPendingChanges {
                pendingCard
                if let error = controller.lastError {
                    PickyHubInlineStatus(tone: .error, message: error, actionTitle: "hub.plugins.reload.retry", action: onReload)
                }
            } else if let result = controller.lastResult {
                PickyHubInlineStatus(tone: .success, message: summary(for: result))
                    .padding(12)
                    .pickyHubCard(fill: PickyHubTheme.Colors.successBackground, border: PickyHubTheme.Colors.success)
            }
        }
    }

    private var pendingCard: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .pickyFont(size: 16, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.action)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("hub.plugins.reload.title")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .bold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text("hub.plugins.reload.message")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            PickyHubButton(
                title: "hub.plugins.reload.action",
                role: .primary,
                systemImage: "arrow.clockwise",
                isBusy: controller.isReloading,
                action: onReload
            )
        }
        .padding(12)
        .pickyHubCard(fill: PickyHubTheme.Colors.actionTint, border: PickyHubTheme.Colors.action.opacity(0.32))
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
