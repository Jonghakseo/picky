//
//  PickyHubStatisticsPage.swift
//  Picky
//

import SwiftUI

struct PickyHubStatisticsPage: View {
    let dependencies: PickyHubDependencies
    @EnvironmentObject private var navigator: PickyHubNavigator
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore
    @State private var selectedTab: PickyHubStatisticsTab = .work

    var body: some View {
        ScrollViewReader { proxy in
            PickyHubPageScroll(page: .statistics) {
                VStack(alignment: .leading, spacing: 0) {
                    PickyHubPageHeader(title: PickyHubPage.statistics.titleKey, subtitle: "hub.page.statistics.subtitle")
                    filters
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

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: PickyHubTheme.Spacing.field) {
                filterControls
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                filterControls
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
    }

    @ViewBuilder
    private var filterControls: some View {
        statisticsPicker(
            titleKey: "hub.stats.filter.period",
            selection: Binding(
                get: { statisticsStore.filter.period },
                set: { statisticsStore.filter.period = $0 }
            ),
            options: PickyHubStatisticsPeriod.allCases.map {
                .init(value: $0, title: $0.localizedTitle)
            }
        )
        statisticsPicker(
            titleKey: "hub.stats.filter.project",
            selection: Binding(
                get: { statisticsStore.filter.project },
                set: { statisticsStore.filter.project = $0 }
            ),
            options: [.init(value: String?.none, title: L10n.t("hub.stats.filter.allProjects"))]
                + PickyHubStatisticsAggregator.projects(in: statisticsStore.snapshot).map {
                    .init(value: Optional($0), title: $0)
                }
        )
    }

    private func statisticsPicker<Selection: Hashable>(
        titleKey: String,
        selection: Binding<Selection>,
        options: [PickyNativeMenuOption<Selection>]
    ) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(LocalizedStringKey(titleKey))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            PickyHubMenuPicker(title: L10n.t(titleKey), selection: selection, options: options)
                .frame(minWidth: 150, maxWidth: PickyHubTheme.Control.maximumFieldWidth, alignment: .leading)
        }
    }

    private var tabs: some View {
        HStack(spacing: PickyHubTheme.Spacing.field) {
            statisticsTab(.work, title: "hub.stats.tab.work")
            statisticsTab(.usage, title: "hub.stats.tab.usage")
            Spacer(minLength: 0)
        }
        .padding(.top, PickyHubTheme.Spacing.group)
        .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.border) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("hub.stats.tabs.accessibility"))
        .onMoveCommand { direction in
            switch direction {
            case .left: selectedTab = .work
            case .right: selectedTab = .usage
            default: break
            }
        }
    }

    private func statisticsTab(_ tab: PickyHubStatisticsTab, title: LocalizedStringKey) -> some View {
        let selected = selectedTab == tab
        return Button { selectedTab = tab } label: {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                .foregroundColor(selected ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textTertiary)
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
        .accessibilityLabel(Text(title))
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                if selectedTab == .work {
                    PickyHubStatisticsWorkTab(snapshot: snapshot, filter: statisticsStore.filter, onGoDashboard: {
                        navigator.select(.dashboard)
                    })
                } else {
                    PickyHubStatisticsUsageTab(snapshot: snapshot, filter: statisticsStore.filter)
                }
                refreshFooter
            }
        }
    }

    private var refreshFooter: some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            if let date = statisticsStore.lastRefreshedAt {
                Text(PickyHubStatisticsPresentation.updatedDescription(date))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .pickyHubSelectableText()
            }
            PickyHubTextLink(title: "hub.stats.refresh") {
                statisticsStore.refresh()
            }
        }
        .padding(.top, PickyHubTheme.Spacing.group)
    }

    private func consumeNavigation(proxy: ScrollViewProxy) {
        if let tab = navigator.pendingStatisticsTab {
            selectedTab = tab
            navigator.pendingStatisticsTab = nil
        }
        guard let anchor = navigator.pendingStatisticsAnchor else { return }
        navigator.pendingStatisticsAnchor = nil
        selectedTab = .work
        DispatchQueue.main.async {
            withAnimation(PickyHubTheme.Motion.page) {
                proxy.scrollTo(anchor.rawValue, anchor: .top)
            }
        }
    }
}

private struct PickyHubStatisticsWorkTab: View {
    let snapshot: PickyHubStatisticsSnapshot
    let filter: PickyHubStatisticsFilter
    let onGoDashboard: () -> Void

    var body: some View {
        let records = PickyHubStatisticsAggregator.records(in: snapshot, filter: filter)
        if records.isEmpty {
            PickyHubEmptyState(
                systemImage: "tray",
                title: "hub.stats.work.empty.title",
                message: "hub.stats.work.empty.message",
                actionTitle: "hub.stats.work.empty.action",
                actionSystemImage: "rectangle.grid.1x2"
            ) {
                onGoDashboard()
            }
            .padding(.top, PickyHubTheme.Spacing.group)
        } else {
            let insights = PickyHubStatisticsAggregator.workInsights(for: records)
            VStack(alignment: .leading, spacing: 0) {
                PickyHubWorkInsightCards(insights: insights)
                    .padding(.top, PickyHubTheme.Spacing.group)
                PickyHubWorkDistribution(insights: insights)
                    .padding(.top, PickyHubTheme.Spacing.group)
                    .id(PickyHubStatisticsAnchor.workPattern.rawValue)
                if snapshot.pendingClassificationCount > 0 {
                    PickyHubInlineStatus(
                        tone: .neutral,
                        message: L10n.t("hub.stats.work.classifying", snapshot.pendingClassificationCount)
                    )
                    .padding(.top, PickyHubTheme.Spacing.related)
                }
                PickyHubPickleRecordsTable(records: records)
                    .padding(.top, PickyHubTheme.Spacing.group)
                    .id(PickyHubStatisticsAnchor.pickleRecords.rawValue)
            }
        }
    }
}

private struct PickyHubWorkDistribution: View {
    let insights: PickyHubWorkInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.work.distribution.title")
            VStack(spacing: PickyHubTheme.Spacing.field) {
                ForEach(insights.distribution) { share in
                    HStack(spacing: PickyHubTheme.Spacing.field) {
                        Text(share.category.title)
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                            .foregroundColor(PickyHubTheme.Colors.textPrimary)
                            .frame(width: 112, alignment: .leading)
                            .pickyHubSelectableText()
                        GeometryReader { proxy in
                            RoundedRectangle(cornerRadius: PickyHubTheme.Radius.pill, style: .continuous)
                                .fill(PickyHubTheme.Colors.barTrack)
                                .overlay(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: PickyHubTheme.Radius.pill, style: .continuous)
                                        .fill(share.category == .unclassified ? PickyHubTheme.Colors.muted : PickyHubTheme.Colors.action)
                                        .frame(width: proxy.size.width * CGFloat(share.share / max(insights.distribution.map(\.share).max() ?? 1, 0.000_001)))
                                }
                        }
                        .frame(height: 10)
                        Text(L10n.t("hub.stats.work.distribution.value", share.count, Int((share.share * 100).rounded())))
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                            .monospacedDigit()
                            .foregroundColor(PickyHubTheme.Colors.textSecondary)
                            .frame(width: 92, alignment: .trailing)
                            .pickyHubSelectableText()
                    }
                }
            }
            .padding(PickyHubTheme.Spacing.cardInset)
            .pickyHubCard(radius: PickyHubTheme.Radius.card)
            .accessibilityElement(children: .combine)
        }
    }
}

private struct PickyHubPickleRecordsTable: View {
    let records: [PickyHubPickleRecord]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.work.records.title")
            ScrollView(.horizontal, showsIndicators: true) {
                Grid(alignment: .leading, horizontalSpacing: DS.Spacing.space4, verticalSpacing: 0) {
                    GridRow {
                        heading("hub.stats.work.records.task", width: 210)
                        heading("hub.stats.work.records.project", width: 105)
                        heading("hub.stats.work.records.followUp", width: 85, number: true)
                        heading("hub.stats.work.records.delegation", width: 85, number: true)
                        heading("hub.stats.work.records.review", width: 70, number: true)
                        heading("hub.stats.work.records.activity", width: 120)
                    }
                    Divider().gridCellColumns(6).overlay(PickyHubTheme.Colors.borderSoft)
                    ForEach(records) { record in
                        GridRow {
                            cell(record.title, width: 210, primary: true)
                            cell(record.project, width: 105)
                            cell("\(record.followUpCount)", width: 85, number: true)
                            cell("\(record.delegationCount)", width: 85, number: true)
                            cell("\(record.reviewCount)", width: 70, number: true)
                            cell(PickyHubStatisticsPresentation.relativeActivity(record.lastActivityAt), width: 120)
                        }
                        if record.id != records.last?.id { Divider().gridCellColumns(6).overlay(PickyHubTheme.Colors.borderSoft) }
                    }
                }
                .padding(.horizontal, PickyHubTheme.Spacing.cardInset)
            }
            .pickyHubCard(radius: PickyHubTheme.Radius.card)
            Text("hub.stats.work.records.caption")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .pickyHubSelectableText()
                .padding(.top, PickyHubTheme.Spacing.related)
        }
    }

    private func heading(_ title: LocalizedStringKey, width: CGFloat, number: Bool = false) -> some View {
        Text(title)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.textTertiary)
            .frame(width: width, height: 36, alignment: number ? .trailing : .leading)
            .pickyHubSelectableText()
    }

    private func cell(_ value: String, width: CGFloat, primary: Bool = false, number: Bool = false) -> some View {
        Text(value)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: primary ? .semibold : .medium)
            .foregroundColor(primary ? PickyHubTheme.Colors.textPrimary : PickyHubTheme.Colors.textSecondary)
            .lineLimit(primary ? nil : 1)
            .fixedSize(horizontal: false, vertical: primary)
            .monospacedDigit()
            .frame(width: width, alignment: number ? .trailing : .leading)
            .frame(minHeight: 48)
            .pickyHubSelectableText()
            .help(value)
    }
}

private struct PickyHubStatisticsUsageTab: View {
    let snapshot: PickyHubStatisticsSnapshot
    let filter: PickyHubStatisticsFilter

    var body: some View {
        let summary = PickyHubStatisticsAggregator.usageSummary(in: snapshot, filter: filter)
        if summary.totalTokens == 0 {
            PickyHubEmptyState(
                systemImage: "chart.line.uptrend.xyaxis",
                title: "hub.stats.usage.empty.title",
                message: "hub.stats.usage.empty.message"
            )
            .padding(.top, PickyHubTheme.Spacing.group)
        } else {
            VStack(alignment: .leading, spacing: 0) {
                PickyHubUsageSummaryCards(summary: summary)
                    .padding(.top, PickyHubTheme.Spacing.group)
                usageChart(summary: summary)
                    .padding(.top, PickyHubTheme.Spacing.group)
                PickyHubModelUsageTable(models: summary.models)
                    .padding(.top, PickyHubTheme.Spacing.group)
            }
        }
    }

    private func usageChart(summary: PickyHubUsageSummary) -> some View {
        let days = PickyHubStatisticsAggregator.continuousDays(summary.days, period: filter.period)
        return VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.usage.chart.title")
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    Circle().fill(PickyHubTheme.Colors.action).frame(width: 8, height: 8)
                    Text("hub.stats.usage.chart.legend")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .pickyHubSelectableText()
                }
                PickyHubUsageLineChart(days: days, period: filter.period)
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
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
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
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.textTertiary)
            .frame(width: width, height: 36, alignment: number ? .trailing : .leading)
            .pickyHubSelectableText()
    }

    private func cell(_ value: String, width: CGFloat, primary: Bool = false, number: Bool = false) -> some View {
        Text(value)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: primary ? .semibold : .medium)
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
