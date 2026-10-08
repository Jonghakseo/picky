//
//  PickyHubStatisticsViews.swift
//  Picky
//

import Foundation
import SwiftUI

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
        formatter.dateFormat = "M/d"
        return formatter.string(from: date)
    }
}
