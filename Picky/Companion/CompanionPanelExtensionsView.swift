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

import Combine
import SwiftUI

private struct PickyCuratedPlugin: Identifiable {
    let id: String
    let titleKey: String
    let descriptionKey: String
    let commandName: String
    let source: String

    static let diffReview = PickyCuratedPlugin(
        id: "diff-review",
        titleKey: "extensions.curated.diffReview.title",
        descriptionKey: "extensions.curated.diffReview.description",
        commandName: "/diff-review",
        source: "npm:@ryan_nookpi/pi-extension-diff-review"
    )

    static let askUserQuestion = PickyCuratedPlugin(
        id: "ask-user-question",
        titleKey: "extensions.curated.askUserQuestion.title",
        descriptionKey: "extensions.curated.askUserQuestion.description",
        commandName: "ask_user_question",
        source: "npm:@ryan_nookpi/pi-extension-ask-user-question"
    )

    static let generativeUI = PickyCuratedPlugin(
        id: "generative-ui",
        titleKey: "extensions.curated.generativeUI.title",
        descriptionKey: "extensions.curated.generativeUI.description",
        commandName: "show_widget",
        source: "npm:@ryan_nookpi/pi-extension-generative-ui"
    )

    static let autoName = PickyCuratedPlugin(
        id: "auto-name",
        titleKey: "extensions.curated.autoName.title",
        descriptionKey: "extensions.curated.autoName.description",
        commandName: "auto-name",
        source: "npm:@ryan_nookpi/pi-extension-auto-name"
    )

    static let delayedAction = PickyCuratedPlugin(
        id: "delayed-action",
        titleKey: "extensions.curated.delayedAction.title",
        descriptionKey: "extensions.curated.delayedAction.description",
        commandName: "/delay",
        source: "npm:@ryan_nookpi/pi-extension-delayed-action"
    )

    static let todoWriteOverlay = PickyCuratedPlugin(
        id: "todo-write-overlay",
        titleKey: "extensions.curated.todoWriteOverlay.title",
        descriptionKey: "extensions.curated.todoWriteOverlay.description",
        commandName: "todo_write",
        source: "npm:@ryan_nookpi/pi-extension-todo-write-overlay"
    )

    static let clipboard = PickyCuratedPlugin(
        id: "clipboard",
        titleKey: "extensions.curated.clipboard.title",
        descriptionKey: "extensions.curated.clipboard.description",
        commandName: "clipboard",
        source: "npm:@ryan_nookpi/pi-extension-clipboard"
    )

    static let claudeMcpBridge = PickyCuratedPlugin(
        id: "claude-mcp-bridge",
        titleKey: "extensions.curated.claudeMcpBridge.title",
        descriptionKey: "extensions.curated.claudeMcpBridge.description",
        commandName: "/mcp-status",
        source: "npm:@ryan_nookpi/pi-extension-claude-mcp-bridge"
    )

    static let crossAgent = PickyCuratedPlugin(
        id: "cross-agent",
        titleKey: "extensions.curated.crossAgent.title",
        descriptionKey: "extensions.curated.crossAgent.description",
        commandName: "cross-agent",
        source: "npm:@ryan_nookpi/pi-extension-cross-agent"
    )

    static let claudeHooksBridge = PickyCuratedPlugin(
        id: "claude-hooks-bridge",
        titleKey: "extensions.curated.claudeHooksBridge.title",
        descriptionKey: "extensions.curated.claudeHooksBridge.description",
        commandName: "claude-hooks-bridge",
        source: "npm:@ryan_nookpi/pi-extension-claude-hooks-bridge"
    )

    static let curatedDefaults: [PickyCuratedPlugin] = [
        .diffReview,
        .askUserQuestion,
        .generativeUI,
        .autoName,
        .delayedAction,
        .todoWriteOverlay,
        .clipboard,
        .claudeMcpBridge,
        .crossAgent,
        .claudeHooksBridge
    ]
}

@MainActor
private final class PickyCuratedPluginsViewModel: ObservableObject {
    struct Row: Identifiable {
        let plugin: PickyCuratedPlugin
        var status: PickyCuratedPluginInstaller.Status
        var isBusy: Bool

        var id: String { plugin.id }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var lastError: String?

    private let plugins: [PickyCuratedPlugin]
    var onPluginStateChanged: (() -> Void)?

    init(plugins: [PickyCuratedPlugin] = PickyCuratedPlugin.curatedDefaults) {
        self.plugins = plugins
        refresh()
    }

    func refresh() {
        rows = plugins.map { plugin in
            Row(
                plugin: plugin,
                status: PickyCuratedPluginInstaller.status(source: plugin.source),
                isBusy: false
            )
        }
    }

    func install(_ plugin: PickyCuratedPlugin) {
        mutate(plugin, operation: .install)
    }

    func remove(_ plugin: PickyCuratedPlugin) {
        mutate(plugin, operation: .remove)
    }

    private enum Operation {
        case install
        case remove
    }

    private func mutate(_ plugin: PickyCuratedPlugin, operation: Operation) {
        let pluginID = plugin.id
        let source = plugin.source
        guard let index = rows.firstIndex(where: { $0.plugin.id == pluginID }) else { return }
        rows[index].isBusy = true
        lastError = nil

        DispatchQueue.global(qos: .userInitiated).async {
            let result: Result<Void, PickyCuratedPluginInstaller.CommandError>
            switch operation {
            case .install:
                result = PickyCuratedPluginInstaller.install(source: source)
            case .remove:
                result = PickyCuratedPluginInstaller.remove(source: source)
            }

            DispatchQueue.main.async { [weak self] in
                self?.applyMutationResult(pluginID: pluginID, source: source, result: result)
            }
        }
    }

    private func applyMutationResult(pluginID: String, source: String, result: Result<Void, PickyCuratedPluginInstaller.CommandError>) {
        switch result {
        case .success:
            lastError = nil
            onPluginStateChanged?()
        case .failure(let error):
            lastError = error.localizedDescription
        }
        if let index = rows.firstIndex(where: { $0.plugin.id == pluginID }) {
            rows[index].isBusy = false
            rows[index].status = PickyCuratedPluginInstaller.status(source: source)
        }
    }
}

struct CompanionPanelExtensionsView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var sessionListViewModel: PickySessionListViewModel
    @EnvironmentObject private var pluginReloadController: PickyPluginReloadController
    @StateObject private var curatedViewModel = PickyCuratedPluginsViewModel()
    @State private var curatedInfoPopoverPluginID: String?
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
                if let lastError = pluginReloadController.lastError {
                    Text(lastError)
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.destructiveText)
                        .fixedSize(horizontal: false, vertical: true)
                }
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
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.accent.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .stroke(DS.Colors.accent.opacity(0.32), lineWidth: 1)
        )
    }

    private func resultCard(result: PickyPluginsReloadedEvent) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.successText)
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
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
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
        // Main is busy when the voice machine is past idle. .listening
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

    /// Curated third-party Pi packages. These are installed through the Pi CLI
    /// rather than copied from the app bundle, so Pi remains the source of truth
    /// for package resolution and settings updates.
    private var curatedSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("extensions.curated.heading")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(curatedViewModel.rows) { row in
                    curatedPluginRow(row)
                }
            }

            if let lastError = curatedViewModel.lastError {
                Text(lastError)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            curatedViewModel.refresh()
            curatedViewModel.onPluginStateChanged = { [weak controller = pluginReloadController] in
                controller?.notePluginsChanged()
            }
        }
    }

    private func curatedPluginRow(_ row: PickyCuratedPluginsViewModel.Row) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "sparkles")
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .center)

            Text(LocalizedStringKey(row.plugin.titleKey))
                .pickyFont(size: 11.5, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Text(row.plugin.commandName)
                .pickyFont(size: 10, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(DS.Colors.textTertiary.opacity(0.12))
                )
                .fixedSize()

            curatedInfoButton(for: row)

            if row.status == .installed {
                curatedBadgePill(
                    text: L10n.t("status.extensions.state.installed"),
                    foreground: DS.Colors.successText,
                    background: DS.Colors.success.opacity(0.18)
                )
            }

            Spacer(minLength: 6)

            curatedActionButton(for: row)
                .fixedSize()
        }
    }

    @ViewBuilder
    private func curatedInfoButton(for row: PickyCuratedPluginsViewModel.Row) -> some View {
        let isOpen = curatedInfoPopoverPluginID == row.plugin.id
        let description = L10n.t(row.plugin.descriptionKey)
        Button(action: {
            curatedInfoPopoverPluginID = isOpen ? nil : row.plugin.id
        }) {
            Image(systemName: "info.circle")
                .pickyFont(size: 10, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(description)
        .popover(
            isPresented: Binding(
                get: { curatedInfoPopoverPluginID == row.plugin.id },
                set: { presented in
                    if !presented, curatedInfoPopoverPluginID == row.plugin.id { curatedInfoPopoverPluginID = nil }
                }
            ),
            arrowEdge: .bottom
        ) {
            Text(description)
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundColor(DS.Colors.textPrimary)
                .multilineTextAlignment(.leading)
                .padding(12)
                .frame(width: 260, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func curatedActionButton(for row: PickyCuratedPluginsViewModel.Row) -> some View {
        switch row.status {
        case .installed:
            Button(action: { curatedViewModel.remove(row.plugin) }) {
                curatedButtonLabel(text: "status.extensions.action.remove", isBusy: row.isBusy)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(row.isBusy)
        case .notInstalled:
            Button(action: { curatedViewModel.install(row.plugin) }) {
                curatedButtonLabel(text: "status.extensions.action.install", isBusy: row.isBusy)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(row.isBusy)
        }
    }

    private func curatedButtonLabel(text: LocalizedStringKey, isBusy: Bool) -> some View {
        HStack(spacing: 5) {
            if isBusy {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 10, height: 10)
            }
            Text(text)
                .fixedSize()
        }
        .fixedSize()
    }

    private func curatedBadgePill(text: String, foreground: Color, background: Color) -> some View {
        Text(text)
            .font(PickyHUDTypography.badgeSemibold)
            .foregroundColor(foreground)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 1.5)
            .background(
                Capsule(style: .continuous).fill(background)
            )
            .fixedSize()
    }

    struct BusySnapshot: Equatable {
        let runningPickles: Int
        let mainBusy: Bool
        var hasAny: Bool { runningPickles > 0 || mainBusy }
        static let empty = BusySnapshot(runningPickles: 0, mainBusy: false)
    }
}
