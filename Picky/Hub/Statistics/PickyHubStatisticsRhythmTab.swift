//
//  PickyHubStatisticsRhythmTab.swift
//  Picky
//
//  작업 리듬 tab: streak and daily calendar over the whole history (also shown
//  on the dashboard), then the period/project filter and the filtered pattern
//  sections below it.
//

import SwiftUI

struct PickyHubStatisticsRhythmTab: View {
    let snapshot: PickyHubStatisticsSnapshot
    let onGoDashboard: () -> Void
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore

    var body: some View {
        let records = PickyHubStatisticsAggregator.records(in: snapshot, filter: statisticsStore.filter)
        VStack(alignment: .leading, spacing: 0) {
            PickyHubActivityHabitView(records: snapshot.records)
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.field) {
                PickyHubSubsectionTitle(title: "hub.stats.rhythm.pattern.title")
                Spacer(minLength: 0)
                Text("hub.stats.rhythm.pattern.scope")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .multilineTextAlignment(.trailing)
                    .pickyHubSelectableText()
            }
            .padding(.top, PickyHubTheme.Layout.sectionSpacing)
            PickyHubStatisticsFilterCard()
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
                PickyHubHourPatternCard(pattern: PickyHubRhythmPolicy.hourPattern(
                    records: PickyHubStatisticsAggregator.startedRecords(in: snapshot, filter: statisticsStore.filter)
                ))
                    .padding(.top, PickyHubTheme.Spacing.field)
                PickyHubWorkDistribution(insights: PickyHubStatisticsAggregator.workInsights(for: records))
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

/// Streak card and daily activity calendar over the whole history. Shared by
/// the statistics rhythm tab and the dashboard; it ignores the period filter.
struct PickyHubActivityHabitView: View {
    let records: [PickyHubPickleRecord]
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let dailyCounts = PickyHubRhythmPolicy.dailyCounts(records: records)
        let streak = PickyHubRhythmPolicy.streaks(
            activeDays: Set(dailyCounts.keys),
            today: Calendar.current.startOfDay(for: Date()),
            calendar: .current
        )
        if contentWidth / fontScale >= 600 {
            HStack(alignment: .top, spacing: PickyHubTheme.Spacing.field) {
                PickyHubStreakCard(current: streak.current, longest: streak.longest)
                    .frame(width: 220)
                PickyHubActivityCalendarCard(dailyCounts: dailyCounts)
            }
            .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                PickyHubStreakCard(current: streak.current, longest: streak.longest)
                PickyHubActivityCalendarCard(dailyCounts: dailyCounts)
            }
        }
    }
}

/// Period and project filter. It lives inside the rhythm tab and scopes only
/// the sections below it; the shared store keeps the dashboard in sync.
private struct PickyHubStatisticsFilterCard: View {
    @EnvironmentObject private var statisticsStore: PickyHubStatisticsStore

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .bottom, spacing: PickyHubTheme.Spacing.field) {
                controls
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                controls
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
    }

    @ViewBuilder
    private var controls: some View {
        picker(
            titleKey: "hub.stats.filter.period",
            selection: Binding(
                get: { statisticsStore.filter.period },
                set: { statisticsStore.filter.period = $0 }
            ),
            options: PickyHubStatisticsPeriod.allCases.map { .init(value: $0, title: $0.localizedTitle) }
        )
        picker(
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

    private func picker<Selection: Hashable>(
        titleKey: String,
        selection: Binding<Selection>,
        options: [PickyNativeMenuOption<Selection>]
    ) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(LocalizedStringKey(titleKey))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            PickyHubMenuPicker(title: L10n.t(titleKey), selection: selection, options: options)
                .frame(minWidth: 150, maxWidth: PickyHubTheme.Control.maximumFieldWidth, alignment: .leading)
        }
    }
}

private struct PickyHubStreakCard: View {
    let current: Int
    let longest: Int

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(Image(systemName: current > 0 ? "flame.fill" : "flame"))
                .pickyFont(size: 24, weight: .semibold)
                .foregroundColor(current > 0 ? PickyHubTheme.Colors.warning : PickyHubTheme.Colors.textTertiary)
                .accessibilityHidden(true)
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space1) {
                Text(verbatim: "\(current)")
                    .pickyFont(size: 32, weight: .semibold)
                    .tracking(-1)
                    .monospacedDigit()
                Text("hub.stats.rhythm.streak.unit")
                    .pickyFont(size: 16, weight: .semibold)
            }
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            Text(current > 0 ? "hub.stats.rhythm.streak.active" : "hub.stats.rhythm.streak.idle")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: PickyHubTheme.Spacing.field)
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.t("hub.stats.rhythm.streak.longest", longest))
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    Spacer(minLength: PickyHubTheme.Spacing.related)
                    Text(current >= longest && longest > 0
                         ? L10n.t("hub.stats.rhythm.streak.record")
                         : L10n.t("hub.stats.rhythm.streak.toRecord", max(0, longest - current)))
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                PickyHubProgressBar(fraction: longest == 0 ? 0 : Double(current) / Double(longest), color: PickyHubTheme.Colors.warning, height: 6)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .pickyHubCard()
        .accessibilityElement(children: .combine)
    }
}

private struct PickyHubActivityCalendarCard: View {
    static let cell: CGFloat = 13
    static let gap: CGFloat = 4
    static let weekdayColumn: CGFloat = 22
    static let maximumWeeks = 26

    let dailyCounts: [Date: Int]
    @Environment(\.locale) private var locale
    @State private var gridWidth: CGFloat = 0

    private var weekCount: Int {
        guard gridWidth > 0 else { return Self.maximumWeeks }
        let fitting = Int((gridWidth - Self.weekdayColumn + Self.gap) / (Self.cell + Self.gap))
        return min(Self.maximumWeeks, max(4, fitting))
    }

    var body: some View {
        let activity = PickyHubRhythmPolicy.activityCalendar(dailyCounts: dailyCounts, weekCount: weekCount)
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Text("hub.stats.rhythm.calendar.title")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Spacer(minLength: 0)
                Text(L10n.t("hub.stats.rhythm.calendar.summary", activity.pickleCount, activity.activeDayCount))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1)
                    .pickyHubSelectableText()
            }
            grid(activity)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PickyHubCalendarWidthKey.self, value: proxy.size.width)
                })
                .onPreferenceChange(PickyHubCalendarWidthKey.self) { gridWidth = $0 }
            HStack(spacing: DS.Spacing.space1) {
                Spacer(minLength: 0)
                legendLabel("hub.stats.rhythm.calendar.less")
                ForEach(0..<5, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Self.fill(level: level))
                        .frame(width: 11, height: 11)
                }
                legendLabel("hub.stats.rhythm.calendar.more")
            }
            .accessibilityHidden(true)
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .pickyHubCard()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("hub.stats.rhythm.calendar.title"))
        .accessibilityValue(Text(L10n.t("hub.stats.rhythm.calendar.summary", activity.pickleCount, activity.activeDayCount)))
    }

    private func grid(_ activity: PickyHubActivityCalendar) -> some View {
        let step = Self.cell + Self.gap
        return VStack(alignment: .leading, spacing: 3) {
            ZStack(alignment: .topLeading) {
                ForEach(monthLabels(activity), id: \.week) { label in
                    Text(verbatim: label.text)
                        .pickyFont(size: 10, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                        .fixedSize()
                        .offset(x: Self.weekdayColumn + CGFloat(label.week) * step)
                }
            }
            .frame(height: 13, alignment: .topLeading)
            HStack(alignment: .top, spacing: 0) {
                VStack(alignment: .leading, spacing: Self.gap) {
                    ForEach(0..<7, id: \.self) { row in
                        Text(verbatim: row % 2 == 1 ? weekdaySymbol(row) : "")
                            .pickyFont(size: 10, weight: .regular)
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                            .frame(width: Self.weekdayColumn, height: Self.cell, alignment: .leading)
                    }
                }
                HStack(alignment: .top, spacing: Self.gap) {
                    ForEach(Array(activity.weeks.enumerated()), id: \.offset) { _, week in
                        VStack(spacing: Self.gap) {
                            ForEach(0..<7, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(week[index].map { Self.fill(level: activity.level(for: $0)) } ?? .clear)
                                    .frame(width: Self.cell, height: Self.cell)
                                    .help(week[index].map(tooltip) ?? "")
                            }
                        }
                    }
                }
            }
        }
    }

    static func fill(level: Int) -> Color {
        level == 0 ? PickyHubTheme.Colors.barTrack : PickyHubTheme.Colors.action.opacity(0.2 + Double(level) * 0.2)
    }

    private func legendLabel(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textTertiary)
    }

    private func weekdaySymbol(_ row: Int) -> String {
        var calendar = Calendar.current
        calendar.locale = locale
        let symbols = calendar.veryShortWeekdaySymbols
        return symbols[(calendar.firstWeekday - 1 + row) % symbols.count]
    }

    private func monthLabels(_ activity: PickyHubActivityCalendar) -> [(week: Int, text: String)] {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate("MMM")
        let calendar = Calendar.current
        var labels: [(week: Int, text: String)] = []
        for (index, week) in activity.weeks.enumerated() {
            let days = week.compactMap { $0 }
            guard let first = days.first else { continue }
            let startsMonth = days.contains { calendar.component(.day, from: $0.date) == 1 }
            // The first column only labels its month when the next label is not crowded against it.
            if (index == 0 && calendar.component(.day, from: first.date) <= 21) || (index > 0 && startsMonth) {
                let date = days.first { calendar.component(.day, from: $0.date) == 1 }?.date ?? first.date
                if let last = labels.last, index - last.week < 3 { labels.removeLast() }
                labels.append((index, formatter.string(from: date)))
            }
        }
        return labels
    }

    private func tooltip(_ day: PickyHubActivityDay) -> String {
        L10n.t("hub.stats.rhythm.calendar.dayTooltip", day.date.formatted(.dateTime.month().day().locale(locale)), day.count)
    }
}

private struct PickyHubCalendarWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

private struct PickyHubHourPatternCard: View {
    let pattern: PickyHubHourPattern
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        Group {
            if contentWidth / fontScale >= 560 {
                HStack(alignment: .top, spacing: PickyHubTheme.Spacing.group) {
                    chart
                    facts.frame(width: 180, alignment: .leading)
                }
            } else {
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.group) {
                    chart
                    facts
                }
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard()
    }

    private var chart: some View {
        let peak = max(pattern.hourCounts.max() ?? 0, 1)
        let window = pattern.peakStartHour.map { $0..<($0 + PickyHubHourPattern.peakWindowLength) }
        return VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text("hub.stats.rhythm.hours.title")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textPrimary)
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(pattern.hourCounts.enumerated()), id: \.offset) { hour, count in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(window?.contains(hour) == true ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.action.opacity(0.32))
                        .frame(height: max(2, CGFloat(count) / CGFloat(peak) * 84))
                        .frame(maxWidth: .infinity)
                        .help(L10n.t("hub.stats.rhythm.hours.tooltip", hour, count))
                }
            }
            .frame(height: 84, alignment: .bottom)
            HStack(spacing: 0) {
                ForEach([0, 6, 12, 18, 24], id: \.self) { hour in
                    Text(L10n.t("hub.stats.rhythm.hours.axis", hour))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                        .lineLimit(1)
                    if hour != 24 { Spacer(minLength: 0) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("hub.stats.rhythm.hours.title"))
        .accessibilityValue(Text(pattern.hourCounts.enumerated()
            .filter { $0.element > 0 }
            .map { L10n.t("hub.stats.rhythm.hours.tooltip", $0.offset, $0.element) }
            .joined(separator: ", ")))
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            if let start = pattern.peakStartHour {
                fact(
                    label: "hub.stats.rhythm.peak.label",
                    value: L10n.t("hub.stats.rhythm.peak.value", start, start + PickyHubHourPattern.peakWindowLength),
                    detail: L10n.t("hub.stats.rhythm.share", pattern.share(pattern.peakCount))
                )
            }
            fact(
                label: "hub.stats.rhythm.lateNight.label",
                value: "\(pattern.share(pattern.lateNightCount))%",
                detail: L10n.t("hub.stats.rhythm.pickleCount", pattern.lateNightCount)
            )
            fact(
                label: "hub.stats.rhythm.weekend.label",
                value: "\(pattern.share(pattern.weekendCount))%",
                detail: L10n.t("hub.stats.rhythm.pickleCount", pattern.weekendCount)
            )
        }
    }

    private func fact(label: LocalizedStringKey, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: value)
                    .pickyFont(size: 16, weight: .semibold)
                    .monospacedDigit()
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                Text(verbatim: detail)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .pickyHubSelectableText()
    }
}

/// Thin capsule progress bar shared by the rhythm and badge tabs.
struct PickyHubProgressBar: View {
    let fraction: Double
    var color: Color = PickyHubTheme.Colors.action
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            Capsule(style: .continuous)
                .fill(PickyHubTheme.Colors.barTrack)
                .overlay(alignment: .leading) {
                    if fraction > 0 {
                        Capsule(style: .continuous)
                            .fill(color)
                            .frame(width: max(height, proxy.size.width * CGFloat(min(1, fraction))))
                    }
                }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

// MARK: - Moved from the former 작업 tab

private struct PickyHubWorkDistribution: View {
    let insights: PickyHubWorkInsights

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "hub.stats.work.distribution.title")
            VStack(spacing: PickyHubTheme.Spacing.field) {
                ForEach(insights.distribution) { share in
                    HStack(spacing: PickyHubTheme.Spacing.field) {
                        Text(share.category.title)
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
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
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
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
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .pickyHubSelectableText()
                .padding(.top, PickyHubTheme.Spacing.related)
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
            .lineLimit(primary ? nil : 1)
            .fixedSize(horizontal: false, vertical: primary)
            .monospacedDigit()
            .frame(width: width, alignment: number ? .trailing : .leading)
            .frame(minHeight: 48)
            .pickyHubSelectableText()
            .help(value)
    }
}

