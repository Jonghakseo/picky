//
//  PickyHubStatisticsPage.swift
//  Picky
//

import SwiftUI

struct PickyHubStatisticsPage: View {
    let dependencies: PickyHubDependencies
    @EnvironmentObject private var navigator: PickyHubNavigator
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore
    @State private var selectedTab: PickyHubStatisticsTab = .rhythm

    var body: some View {
        ScrollViewReader { proxy in
            PickyHubPageScroll(page: .statistics) {
                VStack(alignment: .leading, spacing: 0) {
                    PickyHubPageHeader(title: PickyHubPage.statistics.titleKey, subtitle: "hub.page.statistics.subtitle")
                    tabs
                    content
                }
            }
            .onAppear {
                statisticsStore.refreshIfNeeded()
                consumeNavigation(proxy: proxy)
            }
            .onChange(of: navigator.pendingStatisticsTab) { _, _ in
                consumeNavigation(proxy: proxy)
            }
            .onChange(of: navigator.pendingStatisticsAnchor) { _, _ in
                consumeNavigation(proxy: proxy)
            }
        }
    }

    private var tabs: some View {
        HStack(spacing: PickyHubTheme.Spacing.field) {
            ForEach(PickyHubStatisticsTab.allCases) { tab in
                statisticsTab(tab)
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.border) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("hub.stats.tabs.accessibility"))
        .onMoveCommand { direction in
            let all = PickyHubStatisticsTab.allCases
            guard let index = all.firstIndex(of: selectedTab) else { return }
            switch direction {
            case .left where index > all.startIndex: selectedTab = all[all.index(before: index)]
            case .right where index < all.index(before: all.endIndex): selectedTab = all[all.index(after: index)]
            default: break
            }
        }
    }

    private func statisticsTab(_ tab: PickyHubStatisticsTab) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            Text(tab.titleKey)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundColor(selected ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
                .lineLimit(1)
                .frame(minHeight: PickyHubTheme.Control.minimumHeight, alignment: .bottom)
                .padding(.horizontal, PickyHubTheme.Control.horizontalInset)
                .padding(.bottom, PickyHubTheme.Spacing.related)
                .overlay(alignment: .bottom) {
                    if selected { Rectangle().fill(PickyHubTheme.Colors.action).frame(height: 2) }
                }
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityLabel(Text(tab.titleKey))
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedTab == .usage, let usageLimitsStore = dependencies.usageLimitsStore {
                PickyHubUsageLimitsSection(store: usageLimitsStore)
                    .padding(.top, PickyHubTheme.Spacing.group)
                    .id(PickyHubStatisticsAnchor.planLimits.rawValue)
            }
            switch statisticsStore.state {
            case .idle, .loading:
                PickyHubLoadingRow(message: "hub.stats.loading")
                    .padding(.top, PickyHubTheme.Spacing.group)
            case .failed(let message):
                PickyHubInlineStatus(tone: .error, message: message, actionTitle: "hub.common.retry") {
                    statisticsStore.refresh()
                }
                .padding(.top, PickyHubTheme.Spacing.group)
            case .loaded(let snapshot):
                Group {
                    switch selectedTab {
                    case .rhythm:
                        PickyHubStatisticsRhythmTab(snapshot: snapshot, onGoDashboard: {
                            navigator.select(.dashboard)
                        })
                    case .badges:
                        PickyHubStatisticsBadgesTab(snapshot: snapshot)
                    case .hallOfFame:
                        PickyHubStatisticsHallOfFameTab(
                            snapshot: snapshot,
                            canOpen: canOpenPickle,
                            onOpen: openPickle
                        )
                    case .usage:
                        PickyHubStatisticsUsageTab(snapshot: snapshot)
                    }
                }
                .padding(.top, PickyHubTheme.Spacing.group)
                refreshFooter
            }
        }
    }

    private var refreshFooter: some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            if let date = statisticsStore.lastRefreshedAt {
                Text(PickyHubStatisticsPresentation.updatedDescription(date))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .pickyHubSelectableText()
            }
            PickyHubTextLink(title: "hub.stats.refresh") {
                statisticsStore.refresh()
                if selectedTab == .usage { dependencies.usageLimitsStore?.refresh() }
            }
        }
        .padding(.top, PickyHubTheme.Spacing.group)
    }

    private func canOpenPickle(_ id: String) -> Bool {
        dependencies.pickleOpener.canOpen(id)
    }

    private func openPickle(_ id: String) {
        dependencies.pickleOpener.open(id)
    }

    private func consumeNavigation(proxy: ScrollViewProxy) {
        if let tab = navigator.pendingStatisticsTab {
            selectedTab = tab
            navigator.pendingStatisticsTab = nil
        }
        guard let anchor = navigator.pendingStatisticsAnchor else { return }
        navigator.pendingStatisticsAnchor = nil
        selectedTab = anchor.tab
        DispatchQueue.main.async {
            withAnimation(PickyHubTheme.Motion.page) {
                proxy.scrollTo(anchor.rawValue, anchor: .top)
            }
        }
    }
}

extension PickyHubStatisticsTab {
    var titleKey: LocalizedStringKey {
        switch self {
        case .rhythm: "hub.stats.tab.rhythm"
        case .badges: "hub.stats.tab.badges"
        case .hallOfFame: "hub.stats.tab.hallOfFame"
        case .usage: "hub.stats.tab.usage"
        }
    }
}

private struct PickyHubStatisticsUsageTab: View {
    /// The page filter belongs to the rhythm tab, so usage keeps one fixed window.
    static let dayCount = 30

    let snapshot: PickyHubStatisticsSnapshot
    var now = Date()

    private var start: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .day, value: -(Self.dayCount - 1), to: calendar.startOfDay(for: now)) ?? now
    }

    var body: some View {
        let summary = PickyHubStatisticsAggregator.usageSummary(in: snapshot, start: start, now: now)
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.usage.recent.title")
            if summary.totalTokens == 0 {
                PickyHubEmptyState(
                    systemImage: "chart.line.uptrend.xyaxis",
                    title: "hub.stats.usage.empty.title",
                    message: "hub.stats.usage.empty.message"
                )
            } else {
                PickyHubUsageSummaryCards(summary: summary)
                usageChart(summary: summary)
                    .padding(.top, PickyHubTheme.Spacing.group)
                PickyHubModelUsageTable(models: summary.models)
                    .padding(.top, PickyHubTheme.Spacing.group)
            }
        }
    }

    private func usageChart(summary: PickyHubUsageSummary) -> some View {
        let days = PickyHubStatisticsAggregator.continuousDays(summary.days, start: start, now: now)
        return VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.usage.chart.title")
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    Circle().fill(PickyHubTheme.Colors.action).frame(width: 8, height: 8)
                    Text("hub.stats.usage.chart.legend")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .pickyHubSelectableText()
                }
                PickyHubUsageLineChart(days: days)
            }
            .padding(PickyHubTheme.Spacing.cardInset)
            .pickyHubCard(radius: PickyHubTheme.Radius.card, fill: PickyHubTheme.Colors.canvas)
            PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.stats.usage.costNotice"))
                .padding(.top, PickyHubTheme.Spacing.related)
        }
    }
}

private struct PickyHubUsageSummaryCards: View {
    let summary: PickyHubUsageSummary
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field), count: PickyHubGridPolicy.columnCount(
            for: contentWidth / fontScale,
            maximum: 4,
            spacing: PickyHubTheme.Spacing.field
        ))
        LazyVGrid(columns: columns, spacing: PickyHubTheme.Spacing.field) {
            card("hub.stats.usage.total", summary.totalTokens)
            card("hub.stats.usage.input", summary.inputTokens)
            card("hub.stats.usage.output", summary.outputTokens)
            card("hub.stats.usage.cache", summary.cacheTokens)
        }
    }

    private func card(_ label: LocalizedStringKey, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(label)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .pickyHubSelectableText()
            Text(PickyHubTokenFormatter.string(value))
                .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                .tracking(-1)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
                .pickyHubSelectableText()
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .leading)
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard()
    }
}

private struct PickyHubModelUsageTable: View {
    let models: [PickyHubModelUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.usage.models.title")
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.space4, verticalSpacing: 0) {
                    GridRow {
                        heading("hub.stats.usage.models.model", width: 180)
                        heading("hub.stats.usage.models.provider", width: 135)
                        heading("hub.stats.usage.models.input", width: 100, number: true)
                        heading("hub.stats.usage.models.output", width: 120, number: true)
                        heading("hub.stats.usage.models.cache", width: 100, number: true)
                    }
                    Divider().gridCellColumns(5).overlay(PickyHubTheme.Colors.borderSoft)
                    ForEach(models) { model in
                        GridRow {
                            cell(model.model, width: 180, primary: true)
                            cell(model.provider, width: 135)
                            cell(PickyHubTokenFormatter.string(model.inputTokens), width: 100, number: true)
                            cell(PickyHubTokenFormatter.string(model.outputTokens), width: 120, number: true)
                            cell(PickyHubTokenFormatter.string(model.cacheTokens), width: 100, number: true)
                        }
                        if model.id != models.last?.id { Divider().gridCellColumns(5).overlay(PickyHubTheme.Colors.borderSoft) }
                    }
                }
                .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
            }
            .pickyHubCard(radius: PickyHubTheme.Radius.card)
        }
    }

    private func heading(_ title: LocalizedStringKey, width: CGFloat, number: Bool = false) -> some View {
        Text(title)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textTertiary)
            .frame(width: width, height: 36, alignment: number ? .trailing : .leading)
            .pickyHubSelectableText()
    }

    private func cell(_ value: String, width: CGFloat, primary: Bool = false, number: Bool = false) -> some View {
        Text(value)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: primary ? .medium : .regular)
            .foregroundColor(primary ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textSecondary)
            .monospacedDigit()
            .lineLimit(primary ? nil : 1)
            .fixedSize(horizontal: false, vertical: primary)
            .frame(width: width, alignment: number ? .trailing : .leading)
            .frame(minHeight: 42)
            .pickyHubSelectableText()
            .help(value)
    }
}
