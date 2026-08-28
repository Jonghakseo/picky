//
//  PickyActivitySummaryView.swift
//  Picky
//
//  Compact tool-activity summary strip for conversation cards.
//

import SwiftUI

struct PickyActivitySummaryView: View {
    let summary: PickyActivitySummary
    var onTap: (() -> Void)? = nil

    @State private var isExpanded: Bool

    init(
        summary: PickyActivitySummary,
        onTap: (() -> Void)? = nil,
        initiallyExpanded: Bool = false
    ) {
        self.summary = summary
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
            HStack(spacing: DS.Spacing.space2) {
                Circle()
                    .fill(DS.Colors.success)
                    .frame(width: DS.Spacing.space1, height: DS.Spacing.space1)
                    .accessibilityHidden(true)
                Image(systemName: "list.bullet")
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textSecondary)
                    .accessibilityHidden(true)
                Text(summary.completedToolUseDisplayText)
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                HStack(spacing: DS.Spacing.space1) {
                    Text(L10n.t("hud.activity.summary.completed"))
                        .font(PickyHUDTypography.meta)
                    Image(systemName: "chevron.right")
                        .font(PickyHUDTypography.metaSemibold)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .accessibilityHidden(true)
                }
                .foregroundColor(DS.Colors.textTertiary)
            }
            .padding(.horizontal, DS.Spacing.space1)
            .padding(.vertical, DS.Spacing.space1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L10n.t(isExpanded ? "hud.activity.summary.collapse" : "hud.activity.summary.expand"))
        .accessibilityLabel(summary.completedToolUseDisplayText)
        .accessibilityValue(L10n.t("hud.activity.summary.completed"))
        .accessibilityHint(L10n.t(isExpanded ? "hud.activity.summary.collapse" : "hud.activity.summary.expand"))
        .hoverAffordance()
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

struct PickyContextUsageChip: View {
    let display: ContextUsageBatteryDisplay

    var body: some View {
        HStack(spacing: 4) {
            Text("ctx")
            ContextUsageBar(progress: display.fraction, color: display.barColor)
                .frame(width: 24, height: 5)
            Text(display.label)
                .fontWeight(.bold)
        }
        .font(PickyHUDTypography.metaMonospacedMedium)
        .foregroundColor(display.textColor.opacity(0.9))
        .lineLimit(1)
        .help(display.tooltip)
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
            self.tooltip = "Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%)"
        } else {
            self.tooltip = "Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens"
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

    var completedToolUseDisplayText: String {
        L10n.t(
            totalToolCalls == 1
                ? "hud.activity.summary.toolsUsed.one"
                : "hud.activity.summary.toolsUsed.many",
            Int64(totalToolCalls)
        )
    }

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
