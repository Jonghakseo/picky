//
//  PickyHubPluginsPage.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubPluginsPage: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var catalog: PickyHubPluginCatalogViewModel
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedPluginControl: String?
    @State private var commandFMonitor: Any?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _catalog = ObservedObject(wrappedValue: dependencies.pluginCatalog)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: PickyHubTheme.Layout.cardGap),
            count: PickyHubGridPolicy.columnCount(for: contentWidth)
        )
    }

    var body: some View {
        PickyHubPageScroll {
            VStack(alignment: .leading, spacing: 0) {
                PickyHubPageHeader(title: PickyHubPage.plugins.titleKey, subtitle: "hub.page.plugins.subtitle")

                PickyHubPluginReloadBanner(
                    controller: dependencies.pluginReloadController,
                    onReload: handleReloadTapped
                )
                .padding(.bottom, dependencies.pluginReloadController.hasPendingChanges || dependencies.pluginReloadController.lastResult != nil ? 20 : 0)

                searchAndFilters

                Text(statusMessage)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .padding(.top, 13)
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityLabel(Text(statusMessage))

                if catalog.filtered.isEmpty {
                    PickyHubEmptyState(
                        systemImage: "magnifyingglass",
                        title: "hub.plugins.empty.title",
                        message: "hub.plugins.empty.message",
                        actionTitle: "hub.plugins.empty.clear",
                        actionSystemImage: "xmark.circle",
                        action: clearFilters
                    )
                    .padding(.top, 12)
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 12) {
                        ForEach(catalog.filtered) { item in
                            PickyHubPluginCardView(
                                item: item,
                                onDetail: { presentDetail(for: item) },
                                onInstall: { install(item) },
                                onRemove: { presentRemovalConfirmation(for: item) },
                                onUpdate: { update(item) },
                                onViewCronJobs: { presentCronJobs(for: item) },
                                onSetupCronDaemon: { setup(item) },
                                focusedControl: $focusedPluginControl
                            )
                        }
                    }
                    .padding(.top, 12)
                }

                feedback
                    .padding(.top, 14)
            }
        }
        .onAppear {
            catalog.refresh()
            installCommandFMonitor()
        }
        .onDisappear { removeCommandFMonitor() }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .pickyFont(size: 16, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .accessibilityHidden(true)
                TextField("hub.plugins.search.placeholder", text: $catalog.query)
                    .textFieldStyle(.plain)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .focused($searchFocused)
                    .accessibilityLabel(Text("hub.plugins.search.placeholder"))
            }
            .padding(.horizontal, 11)
            .frame(minHeight: 39)
            .pickyHubCard(radius: PickyHubTheme.Radius.control, fill: PickyHubTheme.Colors.canvas)
            .pickyHubFocusRing(isFocused: searchFocused, cornerRadius: PickyHubTheme.Radius.control)

            HStack(alignment: .center, spacing: 7) {
                Text("hub.plugins.category.label")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                PickyHubPluginCategoryChip(title: "hub.plugins.category.all", isSelected: catalog.category == nil) {
                    catalog.category = nil
                }
                ForEach(PickyHubPluginCategory.allCases) { category in
                    PickyHubPluginCategoryChip(title: category.titleKey, isSelected: catalog.category == category) {
                        catalog.category = category
                    }
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("hub.plugins.category.label"))
        }
        .padding(15)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let feedback = catalog.feedback {
                PickyHubInlineStatus(
                    tone: catalog.feedbackIsError ? .error : .success,
                    message: feedback,
                    actionTitle: catalog.feedbackIsError ? "hub.plugins.feedback.retry" : nil
                ) {
                    catalog.retryFeedback()
                }
            }
        }
    }

    private var statusMessage: String {
        let count = catalog.filtered.count
        if let category = catalog.category {
            return L10n.t("hub.plugins.status.category", Int64(count), category.title)
        }
        return L10n.t("hub.plugins.status.all", Int64(count))
    }

    private func clearFilters() {
        catalog.clearFilters()
        searchFocused = true
    }

    private func install(_ item: PickyHubPluginItem) {
        catalog.install(item)
    }

    private func update(_ item: PickyHubPluginItem) {
        catalog.update(item)
    }

    private func setup(_ item: PickyHubPluginItem) {
        catalog.setup(item)
    }

    private func presentDetail(for item: PickyHubPluginItem) {
        modalHost.present(width: 540, accessibilityLabel: item.title, onDismiss: {
            restoreFocus("\(item.id).detail")
        }) {
            PickyHubPluginDetailDialog(
                item: item,
                onInstall: { install(item) },
                onRemove: { remove(item) }
            )
        }
    }

    private func presentRemovalConfirmation(for item: PickyHubPluginItem) {
        modalHost.present(width: 390, accessibilityLabel: L10n.t("hub.plugins.remove.confirm.title"), onDismiss: {
            restoreFocus("\(item.id).action")
        }) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.plugins.remove.confirm.title"),
                message: L10n.t("hub.plugins.remove.confirm.message", item.title),
                confirmTitle: "hub.plugins.card.remove",
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    modalHost.dismiss()
                    remove(item)
                }
            )
        }
    }

    private func presentCronJobs(for item: PickyHubPluginItem) {
        modalHost.present(width: 620, accessibilityLabel: L10n.t("extensions.cron.jobs.title"), onDismiss: {
            restoreFocus("\(item.id).detail")
        }) {
            PickyHubCronJobsDialog()
        }
    }

    private func remove(_ item: PickyHubPluginItem) {
        catalog.remove(item)
    }

    private func handleReloadTapped() {
        let snapshot = busySnapshot()
        guard snapshot.hasAny else {
            triggerReload()
            return
        }
        modalHost.present(width: 390, accessibilityLabel: L10n.t("hub.plugins.reload.confirm.title"), onDismiss: {
            restoreFocus(nil)
        }) {
            PickyHubConfirmDialog(
                title: L10n.t("hub.plugins.reload.confirm.title"),
                message: reloadConfirmationMessage(for: snapshot),
                confirmTitle: "hub.plugins.reload.confirm.proceed",
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    modalHost.dismiss()
                    triggerReload()
                }
            )
        }
    }

    private func triggerReload() {
        Task { await dependencies.pluginReloadController.reload() }
    }

    private func busySnapshot() -> BusySnapshot {
        BusySnapshot(
            runningPickles: dependencies.sessionListViewModel.sessionRegistry.runningSessionCount,
            mainBusy: dependencies.companionManager.voiceState != .idle
        )
    }

    private func reloadConfirmationMessage(for snapshot: BusySnapshot) -> String {
        if snapshot.runningPickles > 0, snapshot.mainBusy {
            return L10n.t("hub.plugins.reload.confirm.message.both", Int64(snapshot.runningPickles))
        }
        if snapshot.runningPickles > 0 {
            return L10n.t("hub.plugins.reload.confirm.message.pickles", Int64(snapshot.runningPickles))
        }
        if snapshot.mainBusy {
            return L10n.t("hub.plugins.reload.confirm.message.main")
        }
        return L10n.t("hub.plugins.reload.confirm.message.generic")
    }

    private func restoreFocus(_ control: String?) {
        Task { @MainActor in
            focusedPluginControl = control
        }
    }

    private func installCommandFMonitor() {
        guard PickyRuntimeEnvironment.allowsUserEnvironmentEffects else { return }
        guard commandFMonitor == nil else { return }
        commandFMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard dependencies.navigator.selectedPage == .plugins,
                  !modalHost.isPresenting,
                  event.modifierFlags.contains(.command),
                  event.charactersIgnoringModifiers?.lowercased() == "f" else {
                return event
            }
            Task { @MainActor in searchFocused = true }
            return nil
        }
    }

    private func removeCommandFMonitor() {
        if let commandFMonitor {
            NSEvent.removeMonitor(commandFMonitor)
            self.commandFMonitor = nil
        }
    }

    private struct BusySnapshot {
        let runningPickles: Int
        let mainBusy: Bool
        var hasAny: Bool { runningPickles > 0 || mainBusy }
    }
}

private struct PickyHubPluginCategoryChip: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(isSelected ? PickyHubTheme.Colors.textOnAction : (isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary))
                .padding(.horizontal, 9)
                .frame(minHeight: 29)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.canvas)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(isSelected || isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border, lineWidth: 1)
                )
        }
        .buttonStyle(PickyHubPressStyle())
        .focused($isFocused)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.pill)
        .onHover { isHovering = $0 }
        .animation(PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isSelected ? "hub.plugins.category.selected" : "hub.plugins.category.notSelected"))
    }
}
