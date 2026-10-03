//
//  PickyHubPluginUpdatesSection.swift
//  Picky
//
//  Pending plugin updates above the Plugins tabs, so extensions and skills
//  that can update are visible without browsing each tab, plus "Update All".
//

import SwiftUI

struct PickyHubPluginUpdatesSection: View {
    let updates: PickyHubPluginUpdates
    let onUpdateAll: () -> Void
    let onUpdate: (PickyHubPluginItem) -> Void

    private static let iconSize: CGFloat = 34

    var body: some View {
        switch updates.phase {
        case .checking:
            PickyHubLoadingRow(message: "hub.plugins.updates.checking")
        case .allUpdated(let count):
            PickyHubInlineStatus(tone: .success, message: L10n.t("hub.plugins.updates.allUpdated", Int64(count)))
                .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
                .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
                .pickyHubCard()
        case .ready, .updatingAll:
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(updates.entries) { entry in
                    Rectangle()
                        .fill(PickyHubTheme.Colors.borderSoft)
                        .frame(height: 1)
                    row(entry)
                }
            }
            .pickyHubCard()
            .accessibilityElement(children: .contain)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
            iconTile(systemImage: "arrow.down")
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.t("hub.plugins.updates.title", Int64(updates.pendingEntries.count)))
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(kindSummary)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: PickyHubTheme.Spacing.related)
            switch updates.phase {
            case .updatingAll(let done, let total):
                PickyHubButton(title: L10n.t("hub.plugins.updates.updatingAll", Int64(done), Int64(total)), isBusy: true, action: {})
                    .fixedSize()
            default:
                PickyHubButton(title: "hub.plugins.updates.updateAll", systemImage: "arrow.down", action: onUpdateAll)
                    .fixedSize()
            }
        }
        .padding(.vertical, PickyHubTheme.Spacing.field)
        .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
    }

    private var kindSummary: String {
        let pending = updates.pendingEntries
        let extensions = pending.filter { $0.item.plugin.resourceKind == .extension }.count
        let skills = pending.count - extensions
        var parts: [String] = []
        if extensions > 0 { parts.append(L10n.t("hub.plugins.updates.extensionCount", Int64(extensions))) }
        if skills > 0 { parts.append(L10n.t("hub.plugins.updates.skillCount", Int64(skills))) }
        return parts.joined(separator: " · ")
    }

    private func row(_ entry: PickyHubPluginUpdates.Entry) -> some View {
        let item = entry.item
        return VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
                iconTile(systemImage: item.metadata.systemImage)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: PickyHubTheme.Spacing.related) {
                        Text(item.title)
                            .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                            .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        PickyHubBadgePill(text: L10n.t(item.plugin.resourceKind == .skill
                            ? "hub.plugins.section.skills" : "hub.plugins.section.extensions"))
                    }
                    if let version = versionText(entry) {
                        Text(version)
                            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                            .monospacedDigit()
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    }
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: PickyHubTheme.Spacing.related)
                trailing(entry)
            }
            if case .failed(let message) = entry.state {
                PickyHubInlineStatus(tone: .error, message: message)
                    .padding(.leading, Self.iconSize + PickyHubTheme.Spacing.field)
            }
        }
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
    }

    private func versionText(_ entry: PickyHubPluginUpdates.Entry) -> String? {
        let item = entry.item
        if item.bundledStatus != nil {
            return entry.state == .updated ? nil : L10n.t("hub.plugins.updates.bundledVersion")
        }
        guard let installed = item.installedVersion else { return nil }
        if entry.state != .updated, let latest = item.latestVersion {
            return "v\(installed) → v\(latest)"
        }
        return "v\(installed)"
    }

    @ViewBuilder
    private func trailing(_ entry: PickyHubPluginUpdates.Entry) -> some View {
        switch entry.state {
        case .idle:
            PickyHubButton(title: "hub.plugins.card.update", role: .secondary) { onUpdate(entry.item) }
                .fixedSize()
                .accessibilityLabel(Text(L10n.t("hub.plugins.updates.updateItem", entry.item.title)))
        case .queued:
            Text("hub.plugins.updates.queued")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
        case .updating:
            PickyHubButton(title: "hub.plugins.updates.updating", role: .secondary, isBusy: true, action: {})
                .fixedSize()
        case .updated:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .pickyFont(size: 12, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.success)
                    .accessibilityHidden(true)
                Text("hub.plugins.updates.done")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
        case .failed:
            PickyHubButton(title: "hub.common.retry", role: .secondary) { onUpdate(entry.item) }
                .fixedSize()
                .accessibilityLabel(Text(L10n.t("hub.plugins.updates.retryItem", entry.item.title)))
        }
    }

    private func iconTile(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .pickyFont(size: 16, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.action)
            .frame(width: Self.iconSize, height: Self.iconSize)
            .background(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous)
                    .fill(PickyHubTheme.Colors.actionTint)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PickyHubTheme.Radius.nav, style: .continuous)
                    .stroke(PickyHubTheme.Colors.action.opacity(0.28), lineWidth: 1)
            )
            .accessibilityHidden(true)
    }
}
