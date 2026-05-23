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

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("View tool history for this session")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(spacing: 10) {
            ForEach(summary.visibleToolCallItems) { item in
                activityChip(item.icon, label: item.label, count: item.count, color: item.color)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityChip(_ icon: String, label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(icon)
                .pickyFont(size: 10.5, weight: .medium, design: .monospaced)
            Text(label)
                .font(PickyHUDTypography.labelMonospacedMedium)
            Text("\(count)")
                .font(PickyHUDTypography.labelMonospacedMedium)
                .fontWeight(.bold)
        }
        .foregroundColor(color)
        .lineLimit(1)
    }

}

struct PickyContextUsageChip: View {
    let display: ContextUsageBatteryDisplay

    var body: some View {
        HStack(spacing: 4) {
            Text("ctx")
            ContextUsageBar(progress: display.fraction, color: display.color)
                .frame(width: 24, height: 5)
            Text(display.label)
                .fontWeight(.bold)
        }
        .font(PickyHUDTypography.metaMonospacedMedium)
        .foregroundColor(display.color.opacity(0.9))
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
    let color: Color
    let tooltip: String

    init?(usage: PickyContextUsage) {
        guard let percent = usage.percent else { return nil }
        let clamped = max(0, min(100, percent))
        self.fraction = clamped / 100
        self.label = "\(Int(clamped.rounded()))%"
        // Bar is filled left-to-right as usage grows, so high context % = high fill = warmer color.
        switch clamped {
        case 90...:
            self.color = DS.Colors.destructive
        case 75..<90:
            self.color = DS.Colors.warning
        case 50..<75:
            self.color = DS.Colors.info
        default:
            self.color = DS.Colors.success
        }
        if let tokens = usage.tokens {
            self.tooltip = "Context usage: \(tokens.formatted())/\(usage.contextWindow.formatted()) tokens (\(Int(clamped.rounded()))%)"
        } else {
            self.tooltip = "Context usage: \(Int(clamped.rounded()))% of \(usage.contextWindow.formatted()) tokens"
        }
    }
}

struct PickyActivitySummaryDisplayItem: Identifiable {
    let id: String
    let icon: String
    let label: String
    let count: Int
    let color: Color
}

extension PickyActivitySummary {
    /// Total number of tool invocations represented by this snapshot. Excludes
    /// `thinking` because thinking blocks are not tool calls — they are
    /// streamed by the model separately. Used by the turn header to display
    /// the *count* of tool calls (not the count of distinct categories).
    var totalToolCalls: Int { read + bash + edit + write + other }

    var visibleToolCallItems: [PickyActivitySummaryDisplayItem] {
        [
            PickyActivitySummaryDisplayItem(id: "read", icon: "📖", label: "read", count: read, color: DS.Colors.info),
            PickyActivitySummaryDisplayItem(id: "bash", icon: "⌨", label: "bash", count: bash, color: DS.Colors.warning),
            PickyActivitySummaryDisplayItem(id: "edit", icon: "✏", label: "edit", count: edit, color: DS.Colors.accentText),
            PickyActivitySummaryDisplayItem(id: "write", icon: "▣", label: "write", count: write, color: DS.Colors.floatingGradientPurple),
            PickyActivitySummaryDisplayItem(id: "other", icon: "⋯", label: "etc", count: other, color: DS.Colors.textSecondary),
        ].filter { $0.count > 0 }
    }
}
