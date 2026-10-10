//
//  PickyActivitySummaryView.swift
//  Picky
//
//  Compact tool-activity summary strip for conversation cards.
//

import SwiftUI

struct PickyActivitySummaryView: View {
    let summary: PickyActivitySummary
    /// Seconds from the turn's leading user/command message to this summary.
    /// Nil when the turn has no leading message; the label then reads only "Completed".
    var elapsedSeconds: Int? = nil
    var onTap: (() -> Void)? = nil

    @State private var isExpanded: Bool

    init(
        summary: PickyActivitySummary,
        elapsedSeconds: Int? = nil,
        onTap: (() -> Void)? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.summary = summary
        self.elapsedSeconds = elapsedSeconds
        self.onTap = onTap
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            disclosureButton
            if isExpanded {
                historyButton
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DS.Animation.fast), value: isExpanded)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: DS.Spacing.space1) {
                Text(completionText)
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, DS.Spacing.space1)
            .padding(.vertical, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(isExpanded ? "hud.activity.summary.collapse" : "hud.activity.summary.expand"))
        .accessibilityLabel(completionText)
        .accessibilityHint(L10n.t(isExpanded ? "hud.activity.summary.collapse" : "hud.activity.summary.expand"))
        .hoverAffordance()
    }

    private var completionText: String {
        guard let elapsedSeconds else { return L10n.t("hud.activity.summary.completed") }
        return PickyActivityDurationFormat.completionText(seconds: elapsedSeconds)
    }

    @ViewBuilder
    private var historyButton: some View {
        if let onTap {
            Button(action: onTap) {
                detailGrid
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L10n.t("hud.activity.summary.openHistory"))
            .accessibilityLabel(L10n.t("hud.activity.summary.details"))
            .accessibilityHint(L10n.t("hud.activity.summary.openHistory"))
            .hoverAffordance()
        } else {
            detailGrid
                .accessibilityElement(children: .combine)
                .accessibilityLabel(L10n.t("hud.activity.summary.details"))
        }
    }

    private var detailGrid: some View {
        Grid(
            alignment: .leading,
            horizontalSpacing: DS.Spacing.space4,
            verticalSpacing: DS.Spacing.space1
        ) {
            ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row) { item in
                        HStack(spacing: DS.Spacing.space1) {
                            Text(item.label)
                                .font(PickyHUDTypography.status)
                                .foregroundColor(DS.Colors.textSecondary)
                                .lineLimit(1)
                            Text("\(item.count)")
                                .font(PickyHUDTypography.statusMonospacedMedium)
                                .foregroundColor(DS.Colors.textPrimary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.vertical, DS.Spacing.space2)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous))
    }

    private var detailRows: [[PickyActivitySummaryDisplayItem]] {
        let items = summary.visibleToolCallItems
        return stride(from: 0, to: items.count, by: 3).map { start in
            Array(items[start..<min(start + 3, items.count)])
        }
    }
}

/// Completed-turn label in the activity summary: "Completed instantly" up to
/// 5 seconds, otherwise "Completed in <duration>" where the duration lists
/// hours, minutes and seconds with zero parts left out ("1m", "1h 5s").
/// The PWA mirrors this in `agentd/web/src/room/policy/message.ts`
/// (`activityCompletionText`).
enum PickyActivityDurationFormat {
    static let instantMaxSeconds = 5

    static func completionText(seconds: Int) -> String {
        let seconds = max(0, seconds)
        if seconds <= instantMaxSeconds {
            return L10n.t("hud.activity.summary.completedInstantly")
        }
        let parts: [(key: String, value: Int)] = [
            ("hud.activity.summary.duration.hours", seconds / 3_600),
            ("hud.activity.summary.duration.minutes", seconds % 3_600 / 60),
            ("hud.activity.summary.duration.seconds", seconds % 60),
        ]
        let duration = parts
            .filter { $0.value > 0 }
            .map { L10n.t($0.key, Int64($0.value)) }
            .joined(separator: " ")
        return L10n.t("hud.activity.summary.completedAfter", duration)
    }

    /// Seconds between the turn start and the summary's commit time.
    static func elapsedSeconds(from start: Date?, to end: Date) -> Int? {
        guard let start else { return nil }
        return max(0, Int(end.timeIntervalSince(start)))
    }
}

struct PickyContextUsageChip: View {
    let display: ContextUsageBatteryDisplay

    var body: some View {
        HStack(spacing: 4) {
            Text(verbatim: L10n.t("hud.context.usage.chip"))
            ContextUsageBar(progress: display.fraction, color: display.barColor)
                .frame(width: 24, height: 5)
            Text(display.label)
                .fontWeight(.bold)
        }
        .font(PickyHUDTypography.metaMonospacedMedium)
        .foregroundColor(display.textColor.opacity(0.9))
        .lineLimit(1)
        .help(display.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t("hud.context.usage.accessibilityLabel", display.label))
    }
}

private struct ContextUsageBar: View {
    let progress: Double
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(DS.Colors.surface2.opacity(0.85))
                Capsule()
                    .fill(color)
                    .frame(width: geometry.size.width * CGFloat(max(0, min(1, progress))))
            }
            .overlay(
                Capsule().stroke(DS.Colors.borderSubtle.opacity(0.5), lineWidth: 0.5)
            )
        }
    }
}

struct ContextUsageBatteryDisplay {
    let fraction: Double
    let label: String
    let barColor: Color
    let textColor: Color
    let tooltip: String

    init?(usage: PickyContextUsage) {
        guard let percent = usage.percent else { return nil }
        let clamped = max(0, min(100, percent))
        self.fraction = clamped / 100
        self.label = "\(Int(clamped.rounded()))%"
        // Bar is filled left-to-right as usage grows, so high context % = high fill = warmer color.
        switch clamped {
        case 90...:
            self.barColor = DS.Colors.destructive
            self.textColor = DS.Colors.destructiveText
        case 75..<90:
            self.barColor = DS.Colors.warning
            self.textColor = DS.Colors.warningText
        case 50..<75:
            self.barColor = DS.Colors.info
            self.textColor = DS.Colors.info
        default:
            self.barColor = DS.Colors.success
            self.textColor = DS.Colors.successText
        }
        if let tokens = usage.tokens {
            self.tooltip = L10n.t("hud.context.tokensAndPercent", tokens.formatted(), usage.contextWindow.formatted(), Int(clamped.rounded()))
        } else {
            self.tooltip = L10n.t("hud.context.percent", Int(clamped.rounded()), usage.contextWindow.formatted())
        }
    }
}

struct PickyActivitySummaryDisplayItem: Identifiable, Equatable {
    let id: String
    let labelKey: String
    let count: Int

    var label: String { L10n.t(labelKey) }
}

extension PickyActivitySummary {
    /// Number of concrete tool invocations shown in conversation summaries.
    /// Thinking streams separately, while todo updates belong to the dedicated
    /// progress surface rather than tool activity disclosure.
    var totalToolCalls: Int { read + bash + edit + write + subagent + other }

    var visibleToolCallItems: [PickyActivitySummaryDisplayItem] {
        [
            PickyActivitySummaryDisplayItem(id: "read", labelKey: "hud.activity.category.read", count: read),
            PickyActivitySummaryDisplayItem(id: "bash", labelKey: "hud.activity.category.bash", count: bash),
            PickyActivitySummaryDisplayItem(id: "edit", labelKey: "hud.activity.category.edit", count: edit),
            PickyActivitySummaryDisplayItem(id: "write", labelKey: "hud.activity.category.write", count: write),
            PickyActivitySummaryDisplayItem(id: "subagent", labelKey: "hud.activity.category.subagent", count: subagent),
            PickyActivitySummaryDisplayItem(id: "other", labelKey: "hud.activity.category.other", count: other),
        ].filter { $0.count > 0 }
    }
}
