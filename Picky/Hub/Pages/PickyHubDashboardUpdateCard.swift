//
//  PickyHubDashboardUpdateCard.swift
//  Picky
//
//  Update notice at the top of the Hub dashboard. The wrapper observes only
//  the updater so Sparkle state changes do not re-render the rest of the
//  dashboard; `PickyHubUpdateNoticeView` renders a given state.
//

import SwiftUI

struct PickyHubDashboardUpdateCard: View {
    @ObservedObject var updaterController: PickyUpdaterController
    /// Read at click time only; the card must not observe session updates.
    let interruptedPickleCount: () -> Int
    @EnvironmentObject private var modalHost: PickyHubModalHost

    var body: some View {
        PickyHubUpdateNoticeView(
            state: updaterController.dashboardUpdate,
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            actions: .init(
                install: install,
                openUpdateWindow: updaterController.openUpdateWindow,
                openReleaseNotes: updaterController.openReleaseNotes,
                dismiss: updaterController.dismissDashboardUpdate
            )
        )
    }

    private func install() {
        let count = interruptedPickleCount()
        guard count > 0 else {
            updaterController.installReadyUpdateNow()
            return
        }
        modalHost.present(width: 400, accessibilityLabel: L10n.t("hub.dashboard.update.confirm.title", count)) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.dashboard.update.confirm.title", count),
                message: L10n.t("hub.dashboard.update.confirm.message"),
                confirmTitle: "hub.dashboard.update.install",
                confirmRole: .primary,
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    modalHost.dismiss()
                    updaterController.installReadyUpdateNow()
                }
            )
        }
    }
}

struct PickyHubUpdateNoticeView: View {
    struct Actions {
        let install: () -> Void
        let openUpdateWindow: () -> Void
        let openReleaseNotes: () -> Void
        let dismiss: () -> Void
    }

    let state: PickyDashboardUpdateState
    let currentVersion: String
    let actions: Actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let card = state.card {
                content(card: card)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.page, value: state.card)
    }

    private func content(card: PickyDashboardUpdateState.Card) -> some View {
        let isError = card == .downloadFailed
        let tint = isError ? PickyHubTheme.Colors.danger : PickyHubTheme.Colors.action
        return HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
            Image(systemName: isError ? "exclamationmark.circle" : "arrow.down")
                .pickyFont(size: 15, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textOnAction)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.cardCompact, style: .continuous).fill(tint))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    Text(title(card: card, version: state.version))
                        .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !isError, let version = state.version {
                        PickyHubBadgePill(text: "\(currentVersion) → \(version)")
                            .accessibilityLabel(L10n.t("hub.dashboard.update.versionBadge", currentVersion, version))
                    }
                }
                Text(detailKey(card: card))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: PickyHubTheme.Spacing.related)
            actionButtons(card: card, hasNotes: state.releaseNotesURL != nil)
        }
        .padding(.vertical, PickyHubTheme.Spacing.field)
        .padding(.leading, PickyHubTheme.Spacing.cardInset)
        .padding(.trailing, PickyHubTheme.Spacing.field)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(
            fill: isError ? PickyHubTheme.Colors.dangerTint : PickyHubTheme.Colors.actionTint,
            border: tint.opacity(0.35)
        )
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private func actionButtons(card: PickyDashboardUpdateState.Card, hasNotes: Bool) -> some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            if card != .installing {
                PickyHubTextLink(title: "hub.dashboard.update.later", action: actions.dismiss)
            }
            if hasNotes, card == .ready || card == .needsUpdateWindow {
                PickyHubButton(title: "hub.dashboard.update.releaseNotes", role: .secondary, action: actions.openReleaseNotes)
            }
            switch card {
            case .ready:
                PickyHubButton(title: "hub.dashboard.update.install", action: actions.install)
            case .installing:
                PickyHubButton(title: "hub.dashboard.update.installing", isBusy: true, action: {})
            case .needsUpdateWindow:
                PickyHubButton(title: "hub.dashboard.update.openWindow", action: actions.openUpdateWindow)
            case .downloadFailed:
                PickyHubButton(title: "hub.common.retry", role: .secondary, action: actions.openUpdateWindow)
            }
        }
        .fixedSize()
    }

    private func title(card: PickyDashboardUpdateState.Card, version: String?) -> String {
        let version = version ?? ""
        switch card {
        case .ready, .installing: return L10n.t("hub.dashboard.update.ready.title", version)
        case .needsUpdateWindow: return L10n.t("hub.dashboard.update.available.title", version)
        case .downloadFailed: return L10n.t("hub.dashboard.update.failed.title")
        }
    }

    private func detailKey(card: PickyDashboardUpdateState.Card) -> LocalizedStringKey {
        switch card {
        case .ready, .installing: "hub.dashboard.update.ready.detail"
        case .needsUpdateWindow: "hub.dashboard.update.available.detail"
        case .downloadFailed: "hub.dashboard.update.failed.detail"
        }
    }
}
