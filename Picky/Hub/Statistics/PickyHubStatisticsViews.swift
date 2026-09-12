//
//  PickyHubStatisticsViews.swift
//  Picky
//

import Foundation
import SwiftUI

struct PickyHubWorkInsightCards: View {
    let insights: PickyHubWorkInsights
    var actions: PickyHubWorkInsightActions?
    @Environment(\.pickyHubContentWidth) private var contentWidth
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: PickyHubTheme.Spacing.field), count: PickyHubGridPolicy.columnCount(for: contentWidth / fontScale, spacing: PickyHubTheme.Spacing.field))
        LazyVGrid(columns: columns, spacing: PickyHubTheme.Spacing.field) {
            PickyHubWorkInsightCard(
                label: "hub.dashboard.insight.topCategory",
                title: insights.topCategory?.category.title ?? L10n.t("hub.dashboard.insight.classifying"),
                badges: topCategoryBadges,
                isPrimary: true,
                action: actions?.topCategory
            )
            PickyHubWorkInsightCard(
                label: "hub.dashboard.insight.deepestPickle",
                title: insights.deepestPickle?.record.title ?? L10n.t("hub.dashboard.insight.noData"),
                badges: deepestBadges,
                action: actions?.deepestPickle
            )
            PickyHubWorkInsightCard(
                label: "hub.dashboard.insight.focusedProject",
                title: insights.focusedProject?.project ?? L10n.t("hub.dashboard.insight.noData"),
                badges: focusedProjectBadges,
                action: actions?.focusedProject
            )
        }
    }

    private var topCategoryBadges: [String] {
        guard let top = insights.topCategory else {
            return [L10n.t("hub.dashboard.insight.classifyingCount", insights.totalCount)]
        }
        return [
            L10n.t("hub.dashboard.insight.pickleCount", top.count),
            L10n.t("hub.dashboard.insight.share", Int((top.share * 100).rounded()))
        ]
    }

    private var deepestBadges: [String] {
        guard let record = insights.deepestPickle?.record else { return [] }
        return [
            L10n.t("hub.dashboard.insight.followUpCount", record.followUpCount),
            L10n.t("hub.dashboard.insight.delegationCount", record.delegationCount)
        ]
    }

    private var focusedProjectBadges: [String] {
        guard let focused = insights.focusedProject else { return [] }
        return [L10n.t("hub.dashboard.insight.pickleCount", focused.count)]
    }
}

struct PickyHubWorkInsightActions {
    let topCategory: (() -> Void)?
    let deepestPickle: (() -> Void)?
    let focusedProject: (() -> Void)?
}

private struct PickyHubWorkInsightCard: View {
    let label: LocalizedStringKey
    let title: String
    let badges: [String]
    var isPrimary = false
    var action: (() -> Void)?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false
    @FocusState private var isFocused: Bool

    var body: some View {
        Group {
            if let action {
                Button(action: action) { cardBody }
                    .buttonStyle(.plain)
                    .focused($isFocused)
                    .pickyHubFocusRing(isFocused: isFocused, cornerRadius: PickyHubTheme.Radius.cardCompact)
                    .onHover { isHovering = $0 }
                    .accessibilityAddTraits(.isButton)
            } else {
                cardBody
                    .pickyHubSelectableText()
            }
        }
        .animation(reduceMotion ? nil : PickyHubTheme.Motion.hover, value: isHovering)
    }

    private var badgeViews: some View {
        ForEach(badges, id: \.self) { badge in
            PickyHubBadgePill(text: badge, onAccent: isPrimary)
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                .tracking(-0.8)
                .foregroundColor(isPrimary ? PickyHubTheme.Colors.textOnAction : PickyHubTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(label)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .foregroundColor(isPrimary ? PickyHubTheme.Colors.textOnAction : PickyHubTheme.Colors.textSecondary)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DS.Spacing.space1) { badgeViews }
                VStack(alignment: .leading, spacing: DS.Spacing.space1) { badgeViews }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 148, alignment: .leading)
        .padding(PickyHubTheme.Spacing.cardInset)
        .background(
            RoundedRectangle(cornerRadius: PickyHubTheme.Radius.cardCompact, style: .continuous)
                .fill(isPrimary ? PickyHubTheme.Colors.action : (isHovering ? PickyHubTheme.Colors.navHighlight : PickyHubTheme.Colors.surface))
        )
        .overlay(
            RoundedRectangle(cornerRadius: PickyHubTheme.Radius.cardCompact, style: .continuous)
                .stroke(isPrimary ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.border, lineWidth: 1)
        )
    }
}

enum PickyHubStatisticsPresentation {
    /// Keep the first/last dates and enough space to read each intermediate label.
    static func usageAxisIndices(dayCount: Int, availableWidth: CGFloat, minimumSpacing: CGFloat) -> [Int] {
        guard dayCount > 0 else { return [] }
        guard dayCount > 1 else { return [0] }
        let stride = max(1, Int(ceil(CGFloat(dayCount - 1) * max(1, minimumSpacing) / max(1, availableWidth))))
        var indices = Array(Swift.stride(from: 0, to: dayCount - 1, by: stride))
        if let last = indices.last, last > 0, dayCount - 1 - last < stride { indices.removeLast() }
        indices.append(dayCount - 1)
        return indices
    }

    static func relativeActivity(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let calendar = Calendar.current
        let time = timeFormatter(locale: locale).string(from: date)
        if calendar.isDate(date, inSameDayAs: now) { return L10n.t("hub.stats.activity.today", time) }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return L10n.t("hub.stats.activity.yesterday", time)
        }
        let dateString = shortDateFormatter(locale: locale).string(from: date)
        return L10n.t("hub.stats.activity.date", dateString)
    }

    static func updatedDescription(_ date: Date, now: Date = Date(), locale: Locale = .current) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return L10n.t("hub.stats.updated", formatter.localizedString(for: date, relativeTo: now))
    }

    private static func timeFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = locale.language.languageCode?.identifier == "ko" ? "HH:mm" : "h:mm a"
        return formatter
    }

    private static func shortDateFormatter(locale: Locale) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = locale.language.languageCode?.identifier == "ko" ? "M월 d일" : "MMM d"
        return formatter
    }
}

struct PickyHubUsageLineChart: View {
    let days: [PickyHubUsageDay]
    let period: PickyHubStatisticsPeriod
    @Environment(\.locale) private var locale
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        GeometryReader { proxy in
            let maximum = max(days.map(\.totalTokens).max() ?? 0, 1)
            let chartHeight = max(proxy.size.height - 30, 1)
            let labelWidth = DS.Spacing.space8 * 2 * fontScale
            let inset = labelWidth / 2
            let plotWidth = max(0, proxy.size.width - labelWidth)
            let step = days.count > 1 ? plotWidth / CGFloat(days.count - 1) : 0
            let labelIndices = PickyHubStatisticsPresentation.usageAxisIndices(
                dayCount: days.count, availableWidth: plotWidth, minimumSpacing: labelWidth
            )
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { _ in
                        Divider().overlay(PickyHubTheme.Colors.borderSoft)
                        Spacer(minLength: 0)
                    }
                }
                Path { path in
                    for (index, day) in days.enumerated() {
                        let point = CGPoint(
                            x: inset + CGFloat(index) * step,
                            y: chartHeight * (1 - CGFloat(day.totalTokens) / CGFloat(maximum))
                        )
                        if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                    }
                }
                .stroke(PickyHubTheme.Colors.action, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    let y = chartHeight * (1 - CGFloat(day.totalTokens) / CGFloat(maximum))
                    Circle()
                        .fill(PickyHubTheme.Colors.action)
                        .overlay(Circle().stroke(PickyHubTheme.Colors.canvas, lineWidth: 2))
                        .frame(width: 8, height: 8)
                        .position(x: inset + CGFloat(index) * step, y: y)
                }
                ForEach(labelIndices, id: \.self) { index in
                    Text(axisLabel(days[index].day))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                        .lineLimit(1)
                        .frame(width: labelWidth)
                        .pickyHubSelectableText()
                        .position(x: inset + CGFloat(index) * step, y: chartHeight + DS.Spacing.space5)
                }
            }
        }
        .frame(height: 160)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("hub.stats.usage.chart.accessibility"))
        .accessibilityValue(days.map { "\($0.day): \(PickyHubTokenFormatter.string($0.totalTokens))" }.joined(separator: ", "))
    }

    private func axisLabel(_ day: String) -> String {
        guard let date = PickyHubStatisticsAggregator.date(fromDay: day) else { return day }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = period == .thisWeek ? "EEEEE" : "M/d"
        return formatter.string(from: date)
    }
}
