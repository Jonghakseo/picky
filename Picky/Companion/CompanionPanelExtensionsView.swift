//
//  CompanionPanelExtensionsView.swift
//  Picky
//
//  Plugin manager tab. Hosts the bundled Pi extensions section (install /
//  uninstall) plus a placeholder section for curated third-party plugins. A
//  reload banner sits at the very top of the page: it appears when the user
//  has installed/uninstalled a plugin since the last reload and disappears
//  when the daemon confirms via the `pluginsReloaded` broadcast.
//

import SwiftUI

struct CompanionPanelExtensionsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var sessionListViewModel: PickySessionListViewModel
    @EnvironmentObject private var pluginReloadController: PickyPluginReloadController
    @State private var confirmPresented = false
    @State private var pendingBusySnapshot: BusySnapshot = .empty

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            reloadBanner
                .padding(.bottom, pluginReloadController.hasPendingChanges || pluginReloadController.lastResult != nil ? 12 : 0)

            CompanionPanelExtensionsSection()

            Divider()
                .background(DS.Colors.borderSubtle.opacity(0.4))
                .padding(.vertical, 14)

            curatedSection
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .alert(
            L10n.t("status.extensions.reload.confirm.title"),
            isPresented: $confirmPresented,
            actions: {
                Button(L10n.t("status.extensions.reload.confirm.cancel"), role: .cancel) { }
                Button(L10n.t("status.extensions.reload.confirm.proceed"), role: .destructive) {
                    triggerReload()
                }
            },
            message: {
                Text(confirmMessage(for: pendingBusySnapshot))
            }
        )
    }

    // MARK: - Reload banner

    @ViewBuilder
    private var reloadBanner: some View {
        if pluginReloadController.hasPendingChanges {
            pendingReloadCard
        } else if let result = pluginReloadController.lastResult {
            resultCard(result: result)
        }
    }

    private var pendingReloadCard: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.accent)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text("status.extensions.reload.banner.title")
                    .pickyFont(size: 12, weight: .semibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Text("status.extensions.reload.banner.message")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: handleReloadTapped) {
                HStack(spacing: 5) {
                    if pluginReloadController.isReloading {
                        ProgressView()
                            .controlSize(.small)
                            .frame(width: 10, height: 10)
                    }
                    Text("status.extensions.reload.banner.button")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(pluginReloadController.isReloading)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.32), lineWidth: 1)
        )
    }

    private func resultCard(result: PickyPluginsReloadedEvent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.success)
                .frame(width: 16)
            Text(resultSummary(result: result))
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DS.Colors.success.opacity(0.10))
        )
    }

    private func resultSummary(result: PickyPluginsReloadedEvent) -> String {
        // Compose a single sentence describing what reloaded. The daemon
        // already split the work into reloaded / aborted / deferred, so we
        // just stitch those counts into one human-readable line.
        var fragments: [String] = []
        if result.pickyReloaded { fragments.append(L10n.t("status.extensions.reload.result.picky")) }
        if result.pickleReloadedCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleReloaded", Int64(result.pickleReloadedCount)))
        }
        if result.pickleAbortedCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleAborted", Int64(result.pickleAbortedCount)))
        }
        if result.pickleDeferredCount > 0 {
            fragments.append(L10n.t("status.extensions.reload.result.pickleDeferred", Int64(result.pickleDeferredCount)))
        }
        if fragments.isEmpty { return L10n.t("status.extensions.reload.result.nothing") }
        return fragments.joined(separator: ", ")
    }

    // MARK: - Reload flow

    private func handleReloadTapped() {
        let snapshot = computeBusySnapshot()
        pendingBusySnapshot = snapshot
        if snapshot.hasAny {
            confirmPresented = true
        } else {
            triggerReload()
        }
    }

    private func triggerReload() {
        Task { await pluginReloadController.reload() }
    }

    private func computeBusySnapshot() -> BusySnapshot {
        // Status == .running covers both regular streaming and Pi compaction,
        // because compaction surfaces as a sub-state of `running` on the
        // Picky side. The agentd reloadPlugins method differentiates the two
        // and aborts streaming vs deferring compacting sessions.
        let runningPickles = sessionListViewModel.sessions.filter { $0.status == .running }.count
        // Realtime main is busy when the voice machine is past idle. .listening
        // and .processing both involve in-flight work that a session.update
        // would interrupt; .responding is the audible speech the user wants to
        // cut off when they hit Reload.
        let mainBusy = companionManager.voiceState != .idle
        return BusySnapshot(runningPickles: runningPickles, mainBusy: mainBusy)
    }

    private func confirmMessage(for snapshot: BusySnapshot) -> String {
        if snapshot.runningPickles > 0 && snapshot.mainBusy {
            return L10n.t("status.extensions.reload.confirm.message.both", Int64(snapshot.runningPickles))
        } else if snapshot.runningPickles > 0 {
            return L10n.t("status.extensions.reload.confirm.message.pickles", Int64(snapshot.runningPickles))
        } else if snapshot.mainBusy {
            return L10n.t("status.extensions.reload.confirm.message.main")
        } else {
            // Shouldn't reach here (we only show confirm when snapshot.hasAny),
            // but fall back gracefully.
            return L10n.t("status.extensions.reload.confirm.message.generic")
        }
    }

    /// Placeholder for the curated third-party plugin list. Same section
    /// header style as the rest of the panel so it doesn't read as a separate
    /// component; the body text is the only signal that nothing is actionable
    /// here yet.
    private var curatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("extensions.curated.heading")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "sparkles")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text("extensions.curated.comingSoon")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    struct BusySnapshot: Equatable {
        let runningPickles: Int
        let mainBusy: Bool
        var hasAny: Bool { runningPickles > 0 || mainBusy }
        static let empty = BusySnapshot(runningPickles: 0, mainBusy: false)
    }
}
