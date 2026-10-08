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

    var body: some View {
        PickyHubUpdateNoticeView(
            state: updaterController.dashboardUpdate,
            currentVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            actions: .init(
                // Same path as the Check for Updates buttons, including the
                // restart confirmation owned by the app delegate.
                update: updaterController.runUpdateButtonAction,
                openReleaseNotes: updaterController.openReleaseNotes,
                dismiss: updaterController.dismissDashboardUpdate
            )
        )
    }
}

/// Installs the downloaded update, asking first when the relaunch would cut
/// off Pickles mid-response. Every install entry point goes through this.
@MainActor
enum PickyHubUpdateInstallConfirmation {
    static func present(
        updaterController: PickyUpdaterController,
        modalHost: PickyHubModalHost,
        interruptedPickleCount: Int
    ) {
        let count = interruptedPickleCount
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
        /// Runs the card's primary action: check, update, or install.
        let update: () -> Void
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
        let isError = card == .failed
        let isUpToDate = card == .upToDate
        let tint = isError
            ? PickyHubTheme.Colors.danger
            : (isUpToDate ? PickyHubTheme.Colors.success : PickyHubTheme.Colors.action)
        return HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
            Image(systemName: icon(card: card))
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
                    if showsVersionBadge(card: card), let version = state.version {
                        PickyHubBadgePill(text: "\(currentVersion) → \(version)")
                            .accessibilityLabel(L10n.t("hub.dashboard.update.versionBadge", currentVersion, version))
                    }
                }
                if let detail = detail(card: card) {
                    Text(detail)
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: PickyHubTheme.Spacing.related)
            actionButtons(card: card)
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
    private func actionButtons(card: PickyDashboardUpdateState.Card) -> some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            if allowsDismiss(card: card) {
                PickyHubTextLink(title: "hub.dashboard.update.later", action: actions.dismiss)
            }
            if showsReleaseNotesButton(card: card) {
                PickyHubButton(title: "hub.dashboard.update.releaseNotes", role: .secondary, action: actions.openReleaseNotes)
            }
            switch card {
            case .available:
                PickyHubButton(
                    title: state.isInformationOnly ? "hub.dashboard.update.releaseNotes" : "hub.dashboard.update.action",
                    action: actions.update
                )
            case .ready:
                PickyHubButton(title: "hub.dashboard.update.install", action: actions.update)
            case .checking:
                PickyHubButton(title: "hub.dashboard.update.checking.button", isBusy: true, action: {})
            case .downloading:
                PickyHubButton(title: "hub.dashboard.update.downloading.button", isBusy: true, action: {})
            case .installing:
                PickyHubButton(title: "hub.dashboard.update.installing", isBusy: true, action: {})
            case .failed:
                PickyHubButton(title: "hub.common.retry", role: .secondary, action: actions.update)
            case .upToDate:
                EmptyView()
            }
        }
        .fixedSize()
    }

    private func icon(card: PickyDashboardUpdateState.Card) -> String {
        switch card {
        case .failed: return "exclamationmark.circle"
        case .upToDate: return "checkmark"
        case .checking: return "arrow.triangle.2.circlepath"
        default: return "arrow.down"
        }
    }

    private func showsVersionBadge(card: PickyDashboardUpdateState.Card) -> Bool {
        switch card {
        case .available, .downloading, .ready, .installing: return state.version != nil
        case .checking, .upToDate, .failed: return false
        }
    }

    private func allowsDismiss(card: PickyDashboardUpdateState.Card) -> Bool {
        switch card {
        case .available, .ready, .failed: return true
        case .checking, .downloading, .installing, .upToDate: return false
        }
    }

    private func showsReleaseNotesButton(card: PickyDashboardUpdateState.Card) -> Bool {
        guard state.releaseNotesURL != nil, !state.isInformationOnly else { return false }
        return card == .available || card == .ready
    }

    private func title(card: PickyDashboardUpdateState.Card, version: String?) -> String {
        let version = version ?? ""
        switch card {
        case .checking: return L10n.t("hub.dashboard.update.checking.title")
        case .upToDate: return L10n.t("hub.dashboard.update.upToDate.title")
        case .available: return L10n.t("hub.dashboard.update.available.title", version)
        case .downloading: return L10n.t("hub.dashboard.update.downloading.title", version)
        case .ready, .installing: return L10n.t("hub.dashboard.update.ready.title", version)
        case .failed: return L10n.t("hub.dashboard.update.failed.title")
        }
    }

    private func detail(card: PickyDashboardUpdateState.Card) -> String? {
        switch card {
        case .checking: return nil
        case .upToDate: return L10n.t("hub.dashboard.update.upToDate.detail")
        case .available: return L10n.t("hub.dashboard.update.available.detail")
        case .downloading(let progress):
            guard let progress else { return L10n.t("hub.dashboard.update.downloading.detail") }
            return L10n.t("hub.dashboard.update.downloading.progress", Int((progress * 100).rounded()))
        case .ready, .installing: return L10n.t("hub.dashboard.update.ready.detail")
        case .failed: return L10n.t("hub.dashboard.update.failed.detail")
        }
    }
}
