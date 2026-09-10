//
//  PickyHubDashboardPage.swift
//  Picky
//

import AppKit
import SwiftUI

struct PickyHubDashboardPage: View {
    let dependencies: PickyHubDependencies
    @ObservedObject private var permissions: PickyPermissionMonitor
    @EnvironmentObject private var navigator: PickyHubNavigator
    @EnvironmentObject private var modalHost: PickyHubModalHost
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore
    @EnvironmentObject private var quickStartLauncher: PickyHubQuickStartLauncher
    @EnvironmentObject private var pluginCatalog: PickyHubPluginCatalogViewModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shellCommandStatus: ShellCommandInstaller.InstallStatus = .notInstalled
    @State private var guides = PickyHubGuideCatalog.load()
    @State private var guideIndex = 0
    @State private var shareFeedback: String?
    @FocusState private var focusedDashboardControl: String?

    init(dependencies: PickyHubDependencies) {
        self.dependencies = dependencies
        _permissions = ObservedObject(wrappedValue: dependencies.permissions)
    }

    private var needsPrerequisitesCard: Bool {
        if case .installedStale = shellCommandStatus { return true }
        return !permissions.allGranted
    }

    var body: some View {
        PickyHubPageScroll {
            VStack(alignment: .leading, spacing: 0) {
                greetingCard

                if needsPrerequisitesCard {
                    prerequisitesCard
                        .padding(.top, PickyHubTheme.Layout.sectionSpacing)
                }

                workSummary
                    .padding(.top, PickyHubTheme.Layout.sectionSpacing)
                guidesSection
                    .padding(.top, PickyHubTheme.Layout.sectionSpacing)
                quickStartSection
                    .padding(.top, PickyHubTheme.Layout.sectionSpacing)
                pluginsSection
                    .padding(.top, PickyHubTheme.Layout.sectionSpacing)
                shareSection
                    .padding(.top, PickyHubTheme.Layout.sectionSpacing)
            }
        }
        .onAppear {
            statisticsStore.refreshIfNeeded()
            pluginCatalog.refresh()
            refreshShellCommandStatus()
            guides = PickyHubGuideCatalog.load()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pickyShellCommandStatusDidChange)) { _ in
            refreshShellCommandStatus()
        }
    }

    private var greetingCard: some View {
        let greeting = PickyHubDashboardPresentation.greeting(date: Date(), locale: LocaleManager.shared.effectiveLocale)
        return HStack(spacing: PickyHubTheme.Spacing.field) {
            Image("PickyHubSymbol")
                .resizable()
                .scaledToFit()
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text(greeting.title)
                    .pickyFont(size: PickyHubTheme.Typography.greetingTitle, weight: .bold)
                    .tracking(-0.5)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(greeting.subtitle)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.canvas)
        .accessibilityElement(children: .combine)
    }

    private var prerequisitesCard: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.group) {
            if case .installedStale = shellCommandStatus {
                ViewThatFits(in: .horizontal) {
                    staleShellCommandRow
                    VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                        staleShellCommandDetails
                        PickyHubButton(title: "status.shellCommand.stale.reinstall", role: .secondary) {
                            ShellCommandMenuController.shared.showInstallerAlert()
                        }
                    }
                }
                .padding(PickyHubTheme.Spacing.rowVertical)
                .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
                .pickyHubCard(fill: PickyHubTheme.Colors.surface, border: PickyHubTheme.Colors.warning)
            }
            if !permissions.allGranted {
                CompanionPanelPrerequisitesCopyView()
                CompanionPanelPrerequisitesView(permissions: permissions)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .accessibilityElement(children: .contain)
    }

    private var staleShellCommandRow: some View {
        HStack(alignment: .top, spacing: PickyHubTheme.Spacing.related) {
            staleShellCommandDetails
            Spacer(minLength: PickyHubTheme.Spacing.related)
            PickyHubButton(title: "status.shellCommand.stale.reinstall", role: .secondary) {
                ShellCommandMenuController.shared.showInstallerAlert()
            }
        }
    }

    private var staleShellCommandDetails: some View {
        HStack(alignment: .top, spacing: PickyHubTheme.Spacing.related) {
            Image(systemName: "exclamationmark.triangle.fill")
                .pickyFont(size: 13, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text("status.shellCommand.stale.title")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text("status.shellCommand.stale.subtitle")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
        }
    }

    private var workSummary: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSectionHeading(
                systemImage: "chart.line.uptrend.xyaxis",
                title: "hub.dashboard.work.filteredTitle",
                linkTitle: "hub.dashboard.work.showAll"
            ) {
                navigator.showStatistics()
            }
            Text(PickyHubDashboardPresentation.workScope(filter: statisticsStore.filter))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .padding(.bottom, PickyHubTheme.Spacing.field)
            switch statisticsStore.state {
            case .idle, .loading:
                PickyHubLoadingRow(message: "hub.stats.loading")
            case .failed(let message):
                PickyHubInlineStatus(tone: .error, message: message, actionTitle: "hub.common.retry") {
                    statisticsStore.refresh()
                }
                .padding(PickyHubTheme.Spacing.cardInset)
                .pickyHubCard()
            case .loaded(let snapshot):
                let records = PickyHubStatisticsAggregator.records(in: snapshot, filter: statisticsStore.filter)
                if records.isEmpty {
                    dashboardEmptyWorkCard
                } else {
                    PickyHubWorkInsightCards(
                        insights: PickyHubStatisticsAggregator.workInsights(for: records),
                        actions: .init(
                            topCategory: { navigator.showStatistics(tab: .work, anchor: .workPattern) },
                            deepestPickle: { navigator.showStatistics(tab: .work, anchor: .pickleRecords) },
                            focusedProject: { navigator.showStatistics(tab: .work, anchor: .pickleRecords) }
                        )
                    )
                }
            }
        }
    }

    private var dashboardEmptyWorkCard: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(PickyHubDashboardPresentation.emptyWorkTitle(period: statisticsStore.filter.period))
                .pickyFont(size: PickyHubTheme.Typography.greetingTitle, weight: .bold)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Text("hub.dashboard.work.empty.message")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            PickyHubTextLink(title: "hub.dashboard.work.empty.action") {
                navigator.select(.quickStart)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
    }

    private var guidesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSectionHeading(
                systemImage: "book.closed",
                title: "hub.dashboard.guides.title",
                linkTitle: "hub.dashboard.guides.showAll"
            ) {
                navigator.select(.guides)
            }
            if guides.isEmpty {
                PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.dashboard.guides.empty"))
                    .padding(PickyHubTheme.Spacing.cardInset)
                    .pickyHubCard()
            } else {
                guideCarousel
            }
        }
    }

    private var guideCarousel: some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .center) {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: PickyHubTheme.Layout.cardGap) {
                        ForEach(Array(guides.enumerated()), id: \.element.id) { index, entry in
                            PickyHubDashboardGuideCard(
                                entry: entry,
                                focusedControl: $focusedDashboardControl
                            ) {
                                modalHost.present(
                                    width: 720,
                                    accessibilityLabel: entry.title.resolved(for: LocaleManager.shared.effectiveLocale),
                                    onDismiss: { focusedDashboardControl = "guide.\(entry.id)" }
                                ) {
                                    PickyHubGuideVideoDialog(entry: entry)
                                }
                            }
                            .id(index)
                            .onAppear { guideIndex = index }
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 2)
                }
                .scrollTargetBehavior(.viewAligned)
                .focusable()
                .onMoveCommand { direction in
                    switch direction {
                    case .left: moveGuide(by: -1, proxy: proxy)
                    case .right: moveGuide(by: 1, proxy: proxy)
                    default: break
                    }
                }

                if guideIndex > 0 {
                    carouselButton(systemImage: "chevron.left", label: "hub.dashboard.guides.previous") {
                        moveGuide(by: -1, proxy: proxy)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .offset(x: 8)
                }
                if guideIndex < guides.count - 1 {
                    carouselButton(systemImage: "chevron.right", label: "hub.dashboard.guides.next") {
                        moveGuide(by: 1, proxy: proxy)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .offset(x: -8)
                }
            }
        }
    }

    private func carouselButton(systemImage: String, label: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        PickyHubIconCircleButton(
            systemImage: systemImage,
            accessibilityLabel: label,
            fill: PickyHubTheme.Colors.canvas,
            foreground: PickyHubTheme.Colors.action,
            size: 36,
            action: action
        )
    }

    private func moveGuide(by offset: Int, proxy: ScrollViewProxy) {
        let next = min(max(guideIndex + offset, 0), guides.count - 1)
        guard next != guideIndex else { return }
        guideIndex = next
        withAnimation(reduceMotion ? nil : PickyHubTheme.Motion.page) {
            proxy.scrollTo(next, anchor: .leading)
        }
    }

    private var quickStartSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSectionHeading(
                systemImage: "bolt.fill",
                title: "hub.dashboard.quickStart.title",
                linkTitle: "hub.dashboard.quickStart.showAll"
            ) {
                navigator.select(.quickStart)
            }
            PickyHubDashboardQuickStartGrid(workflows: PickyHubQuickStartWorkflow.all) { workflow in
                Task { await quickStartLauncher.start(workflow) }
            }
            quickStartStatus
        }
    }

    @ViewBuilder
    private var quickStartStatus: some View {
        switch quickStartLauncher.phase {
        case .idle, .starting:
            EmptyView()
        case .failed(_, let message):
            PickyHubInlineStatus(tone: .error, message: message,
                                 actionTitle: quickStartLauncher.retryWillOpenExistingSession ? "hub.quickStart.recover" : "hub.common.retry") {
                Task { await quickStartLauncher.retry() }
            }
            .padding(.top, PickyHubTheme.Spacing.field)
        case .started:
            PickyHubInlineStatus(tone: .success, message: L10n.t("hub.dashboard.quickStart.started"))
                .padding(.top, PickyHubTheme.Spacing.field)
        }
    }

    private var pluginsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSectionHeading(
                systemImage: "puzzlepiece.extension",
                title: "hub.dashboard.plugins.title",
                linkTitle: "hub.dashboard.plugins.showAll"
            ) {
                navigator.select(.plugins)
            }
            if pluginCatalog.recommended.isEmpty {
                PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.dashboard.plugins.empty"))
                    .padding(PickyHubTheme.Spacing.cardInset)
                    .pickyHubCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(pluginCatalog.recommended) { item in
                        PickyHubDashboardPluginRow(
                            item: item,
                            focusedControl: $focusedDashboardControl,
                            onDetail: {
                                modalHost.present(
                                    width: 540,
                                    accessibilityLabel: item.title,
                                    onDismiss: { focusedDashboardControl = "\(item.id).detail" }
                                ) {
                                    PickyHubPluginDetailDialog(
                                        item: item,
                                        onInstall: { pluginCatalog.install(item) },
                                        onRemove: { pluginCatalog.remove(item) }
                                    )
                                }
                            }, onInstall: {
                            pluginCatalog.install(item)
                            }, onRemove: {
                                modalHost.present(
                                    width: 390,
                                    accessibilityLabel: L10n.t("hub.dashboard.plugins.remove.title"),
                                    onDismiss: { focusedDashboardControl = "\(item.id).action" }
                                ) {
                                    PickyHubConfirmDialog(
                                    title: L10n.t("hub.dashboard.plugins.remove.title"),
                                    message: L10n.t("hub.dashboard.plugins.remove.message", item.title),
                                    confirmTitle: "hub.dashboard.plugins.remove.confirm",
                                    isBusy: item.isBusy,
                                    onCancel: { modalHost.dismiss() },
                                    onConfirm: {
                                        pluginCatalog.remove(item)
                                        modalHost.dismiss()
                                    }
                                    )
                                }
                            }
                        )
                        if item.id != pluginCatalog.recommended.last?.id { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
                    }
                }
                .pickyHubCard()
            }
            if let error = pluginCatalog.lastError {
                PickyHubInlineStatus(tone: .error, message: error)
                    .padding(.top, PickyHubTheme.Spacing.related)
            } else if let feedback = pluginCatalog.feedback {
                PickyHubInlineStatus(tone: .success, message: feedback)
                    .padding(.top, PickyHubTheme.Spacing.related)
            }
        }
    }

    private var shareSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSectionHeading(
                systemImage: "square.and.arrow.up",
                title: "hub.dashboard.share.title"
            )
            Text("hub.dashboard.share.message")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .frame(maxWidth: 320, alignment: .leading)
                .padding(.top, PickyHubTheme.Spacing.field)
            HStack(spacing: PickyHubTheme.Spacing.related) {
                PickyHubIconCircleButton(systemImage: "doc.on.doc", accessibilityLabel: "hub.dashboard.share.copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(PickyHubShareLinks.homepage.absoluteString, forType: .string)
                    shareFeedback = L10n.t("hub.dashboard.share.copied")
                    Task {
                        try? await Task.sleep(nanoseconds: 1_500_000_000)
                        shareFeedback = nil
                    }
                }
                PickyHubIconCircleButton(
                    systemImage: "xmark",
                    accessibilityLabel: "hub.dashboard.share.x",
                    fill: PickyHubTheme.Colors.xBrand,
                    foreground: PickyHubTheme.Colors.xBrandForeground,
                    border: PickyHubTheme.Colors.xBrand,
                    hoverForeground: PickyHubTheme.Colors.xBrandForeground
                ) {
                    NSWorkspace.shared.open(PickyHubShareLinks.x)
                }
                PickyHubIconCircleButton(
                    accessibilityLabel: "hub.dashboard.share.linkedIn",
                    textSymbol: "in",
                    fill: PickyHubTheme.Colors.linkedInBrand,
                    foreground: PickyHubTheme.Colors.textOnAction,
                    border: PickyHubTheme.Colors.linkedInBrand,
                    hoverForeground: PickyHubTheme.Colors.textOnAction
                ) {
                    NSWorkspace.shared.open(PickyHubShareLinks.linkedIn)
                }
            }
            .padding(.top, PickyHubTheme.Spacing.field)
            if let shareFeedback {
                PickyHubInlineStatus(tone: .success, message: shareFeedback)
                    .padding(.top, PickyHubTheme.Spacing.related)
            }
        }
    }

    private func refreshShellCommandStatus() {
        shellCommandStatus = ShellCommandInstaller.currentStatus()
    }
}

private struct PickyHubDashboardGuideCard: View {
    let entry: PickyHubGuideEntry
    let focusedControl: FocusState<String?>.Binding
    let action: () -> Void
    @Environment(\.locale) private var locale
    @State private var isHovering = false

    private var focusID: String { "guide.\(entry.id)" }
    private var isFocused: Bool { focusedControl.wrappedValue == focusID }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                AsyncImage(url: entry.resolvedThumbnailURL) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    case .empty:
                        PickyHubPlaceholderVisual(systemImage: "play.rectangle")
                    case .failure:
                        PickyHubPlaceholderVisual(systemImage: "photo")
                    @unknown default:
                        PickyHubPlaceholderVisual(systemImage: "photo")
                    }
                }
                .frame(height: 138)
                .clipped()
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                    Text(entry.title.resolved(for: locale))
                        .pickyFont(size: PickyHubTheme.Typography.body, weight: .bold)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(PickyHubDashboardPresentation.relativeGuideDate(entry.publishedDate, locale: locale))
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
                .padding(PickyHubTheme.Spacing.cardInset)
            }
            .frame(width: 246, alignment: .leading)
            .background(PickyHubTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.cardCompact, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.cardCompact, style: .continuous).stroke(isHovering ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .focused(focusedControl, equals: focusID)
        .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.cardCompact)
        .onHover { isHovering = $0 }
        .accessibilityLabel(entry.title.resolved(for: locale))
    }
}

private struct PickyHubDashboardQuickStartGrid: View {
    let workflows: [PickyHubQuickStartWorkflow]
    let start: (PickyHubQuickStartWorkflow) -> Void
    @EnvironmentObject private var launcher: PickyHubQuickStartLauncher
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: PickyHubTheme.Layout.quickGap), count: PickyHubGridPolicy.columnCount(
            for: contentWidth, maximum: 2,
            minimumCardWidth: PickyHubTheme.Layout.cardMinWidth * fontScale,
            spacing: PickyHubTheme.Layout.quickGap
        ))
        LazyVGrid(columns: columns, spacing: PickyHubTheme.Layout.quickGap) {
            ForEach(workflows) { workflow in
                HStack(spacing: PickyHubTheme.Spacing.field) {
                    PickyHubPlaceholderVisual(systemImage: workflow.systemImage)
                        .frame(width: 112)
                        .frame(maxHeight: .infinity)
                    VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                        Text(workflow.titleKey)
                            .pickyFont(size: PickyHubTheme.Typography.body, weight: .bold)
                            .foregroundColor(PickyHubTheme.Colors.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(workflow.descriptionKey)
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                            .foregroundColor(PickyHubTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        PickyHubPillButton(
                            title: "hub.dashboard.quickStart.start",
                            systemImage: "play.fill",
                            isBusy: isStarting(workflow)
                        ) {
                            start(workflow)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 150)
                .padding(PickyHubTheme.Spacing.cardInset)
                .pickyHubCard(radius: PickyHubTheme.Radius.card)
            }
        }
    }

    private func isStarting(_ workflow: PickyHubQuickStartWorkflow) -> Bool {
        if case .starting(let workflowID) = launcher.phase { return workflowID == workflow.id }
        return false
    }
}

private struct PickyHubDashboardPluginRow: View {
    let item: PickyHubPluginItem
    let focusedControl: FocusState<String?>.Binding
    let onDetail: () -> Void
    let onInstall: () -> Void
    let onRemove: () -> Void
    @State private var isHoveringInstalled = false

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
          HStack(spacing: PickyHubTheme.Spacing.field) {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Text(item.title)
                    .pickyFont(size: PickyHubTheme.Typography.body, weight: .bold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Button(action: onDetail) {
                    Image(systemName: "info.circle")
                        .pickyFont(size: 14, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
                .buttonStyle(.plain)
                .focused(focusedControl, equals: "\(item.id).detail")
                .help(Text("hub.dashboard.plugins.detail"))
                .accessibilityLabel(Text("hub.dashboard.plugins.detail"))
            }
            .frame(minWidth: 112, alignment: .leading)
            Text(item.summary)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if item.isInstalled {
                Button(action: onRemove) {
                    Text(isHoveringInstalled ? "hub.dashboard.plugins.remove" : "hub.dashboard.plugins.installed")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .bold)
                        .foregroundColor(isHoveringInstalled ? PickyHubTheme.Colors.danger : PickyHubTheme.Colors.badgeText)
                        .frame(minWidth: 52, minHeight: 33)
                        .background(isHoveringInstalled ? PickyHubTheme.Colors.dangerTint : PickyHubTheme.Colors.canvas)
                        .overlay(RoundedRectangle(cornerRadius: PickyHubTheme.Radius.control, style: .continuous).stroke(isHoveringInstalled ? PickyHubTheme.Colors.danger : PickyHubTheme.Colors.border, lineWidth: 1))
                }
                .buttonStyle(PickyHubPressStyle())
                .disabled(item.isBusy)
                .focused(focusedControl, equals: "\(item.id).action")
                .onHover { isHoveringInstalled = $0 }
                .accessibilityLabel(Text("hub.dashboard.plugins.remove"))
            } else {
                PickyHubButton(title: "hub.dashboard.plugins.install", isBusy: item.isBusy, action: onInstall)
                    .focused(focusedControl, equals: "\(item.id).action")
            }
        }
          if let error = item.errorMessage {
              PickyHubInlineStatus(tone: .error, message: error)
          }
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
    }
}

enum PickyHubDashboardPresentation {
    struct Greeting: Equatable {
        let title: String
        let subtitle: String
    }

    static func greeting(date: Date, locale: Locale, name: String = NSFullUserName(), calendar: Calendar = .current) -> Greeting {
        let hour = calendar.component(.hour, from: date)
        let isKorean = locale.language.languageCode?.identifier == "ko"
        let firstName = name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
        let part: String
        let title: String
        switch hour {
        case 5..<12:
            part = isKorean ? "아침" : "morning"
        case 12..<18:
            part = isKorean ? "오후" : "afternoon"
        default:
            part = isKorean ? "저녁" : "evening"
        }
        if firstName.isEmpty {
            title = isKorean ? "좋은 \(part)입니다" : "Good \(part)"
        } else {
            title = isKorean ? "좋은 \(part)입니다, \(firstName)님" : "Good \(part), \(firstName)"
        }
        let options = isKorean
            ? ["잠깐 스트레칭하고 다음 작업을 시작해볼까요?", "지난 작업을 돌아보고 다음 아이디어를 찾아보세요.", "Picky와 새 작업을 시작해볼까요?"]
            : ["Take a short stretch, then start your next task.", "Look back at recent work and find your next idea.", "Ready to start something new with Picky?"]
        let day = calendar.ordinality(of: .day, in: .year, for: date) ?? 0
        return Greeting(title: title, subtitle: options[day % options.count])
    }

    static func workScope(filter: PickyHubStatisticsFilter) -> String {
        let periodKey: String
        switch filter.period {
        case .thisWeek: periodKey = "hub.stats.period.thisWeek"
        case .thisMonth: periodKey = "hub.stats.period.thisMonth"
        case .lastThreeMonths: periodKey = "hub.stats.period.lastThreeMonths"
        case .all: periodKey = "hub.stats.period.all"
        }
        return "\(L10n.t(periodKey)) · \(filter.project ?? L10n.t("hub.stats.filter.allProjects"))"
    }

    static func emptyWorkTitle(period: PickyHubStatisticsPeriod) -> LocalizedStringKey {
        switch period {
        case .thisWeek: "hub.dashboard.work.empty.thisWeek"
        case .thisMonth: "hub.dashboard.work.empty.thisMonth"
        case .lastThreeMonths: "hub.dashboard.work.empty.lastThreeMonths"
        case .all: "hub.dashboard.work.empty.all"
        }
    }

    static func relativeGuideDate(_ date: Date?, locale: Locale, now: Date = Date()) -> String {
        guard let date else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }
}

enum PickyHubShareLinks {
    static let homepage = URL(string: "https://github.com/Jonghakseo/picky")!
    static let x = shareURL(base: "https://twitter.com/intent/tweet", items: [URLQueryItem(name: "text", value: "Picky")])
    static let linkedIn = shareURL(base: "https://www.linkedin.com/sharing/share-offsite/", items: [])

    private static func shareURL(base: String, items: [URLQueryItem]) -> URL {
        var components = URLComponents(string: base)!
        components.queryItems = items + [URLQueryItem(name: "url", value: homepage.absoluteString)]
        return components.url!
    }
}
