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
    @Environment(\.pickyAppFontScale) private var fontScale
    @FocusState private var searchFocused: Bool
    @FocusState private var focusedPluginControl: String?
    @State private var commandFMonitor: Any?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _catalog = ObservedObject(wrappedValue: dependencies.pluginCatalog)
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field),
            count: PickyHubGridPolicy.columnCount(for: contentWidth, minimumCardWidth: PickyHubTheme.Layout.cardMinWidth * fontScale, spacing: PickyHubTheme.Spacing.field)
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
                .padding(.bottom, dependencies.pluginReloadController.hasPendingChanges || dependencies.pluginReloadController.lastResult != nil ? PickyHubTheme.Spacing.field : 0)

                searchAndFilters

                Text(statusMessage)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .padding(.top, PickyHubTheme.Spacing.related)
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
                    .padding(.top, PickyHubTheme.Spacing.field)
                } else {
                    LazyVGrid(columns: gridColumns, alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
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
                    .padding(.top, PickyHubTheme.Spacing.field)
                }

                feedback
                    .padding(.top, PickyHubTheme.Spacing.field)
            }
        }
        .onAppear {
            catalog.refresh()
            installCommandFMonitor()
        }
        .onDisappear { removeCommandFMonitor() }
    }

    private var searchAndFilters: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            HStack(spacing: PickyHubTheme.Spacing.related) {
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
            .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
            .frame(minHeight: PickyHubTheme.Control.minimumHeight)
            .pickyHubCard(radius: PickyHubTheme.Radius.control, fill: PickyHubTheme.Colors.canvas)
            .pickyHubFocusRing(isFocused: searchFocused, cornerRadius: PickyHubTheme.Radius.control)

            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text("hub.plugins.category.label")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)

                PickyHubWrappingHStack(spacing: PickyHubTheme.Spacing.related) {
                    PickyHubPluginCategoryChip(title: "hub.plugins.category.all", isSelected: catalog.category == nil) {
                        catalog.category = nil
                    }
                    ForEach(PickyHubPluginCategory.allCases) { category in
                        PickyHubPluginCategoryChip(title: category.titleKey, isSelected: catalog.category == category) {
                            catalog.category = category
                        }
                    }
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(Text("hub.plugins.category.label"))
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.surface)
    }

    @ViewBuilder
    private var feedback: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
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

/// A Hub-local filter layout that keeps category controls readable at narrow
/// widths and enlarged fonts instead of forcing the row to clip.
private struct PickyHubWrappingHStack: Layout {
    let spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        guard !subviews.isEmpty else { return .zero }

        let maximumWidth = proposal.width ?? .greatestFiniteMagnitude
        var lineWidth: CGFloat = 0
        var maximumLineWidth: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let itemWidth = lineWidth == 0 ? size.width : size.width + spacing
            if lineWidth > 0, lineWidth + itemWidth > maximumWidth {
                maximumLineWidth = max(maximumLineWidth, lineWidth)
                totalHeight += lineHeight + spacing
                lineWidth = size.width
                lineHeight = size.height
            } else {
                lineWidth += itemWidth
                lineHeight = max(lineHeight, size.height)
            }
        }

        maximumLineWidth = max(maximumLineWidth, lineWidth)
        return CGSize(width: proposal.width ?? maximumLineWidth, height: totalHeight + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var origin = bounds.origin
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if origin.x > bounds.minX, origin.x + size.width > bounds.maxX {
                origin.x = bounds.minX
                origin.y += lineHeight + spacing
                lineHeight = 0
            }

            subview.place(at: origin, proposal: ProposedViewSize(size))
            origin.x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}

private struct PickyHubPluginCategoryChip: View {
    let title: LocalizedStringKey
    let isSelected: Bool
    let action: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(isSelected ? PickyHubTheme.Colors.textOnAction : (isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary))
                .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
                .frame(minHeight: PickyHubTheme.Control.minimumHeight)
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
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(isSelected ? "hub.plugins.category.selected" : "hub.plugins.category.notSelected"))
    }
}
