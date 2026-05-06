//
//  PickyActivitySummaryView.swift
//  Picky
//
//  Compact tool-activity summary strip for conversation cards.
//

import SwiftUI

struct PickyActivitySummaryView: View {
    let summary: PickyActivitySummary
    var contextUsage: PickyContextUsage? = nil

    var body: some View {
        HStack(spacing: 10) {
            ForEach(summary.visibleToolCallItems) { item in
                activityChip(item.icon, label: item.label, count: item.count, color: item.color)
            }
            if let contextUsage, let display = ContextUsageBatteryDisplay(usage: contextUsage) {
                contextUsageChip(display)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityChip(_ icon: String, label: String, count: Int, color: Color) -> some View {
        HStack(spacing: 3) {
            Text(icon)
            Text(label)
            Text("\(count)")
                .fontWeight(.bold)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
    }

    private func contextUsageChip(_ display: ContextUsageBatteryDisplay) -> some View {
        HStack(spacing: 3) {
            Image(systemName: display.symbolName)
                .font(.system(size: 11, weight: .medium))
            Text(display.label)
                .fontWeight(.bold)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundColor(display.color)
        .lineLimit(1)
        .help(display.tooltip)
    }
}

struct ContextUsageBatteryDisplay {
    let symbolName: String
    let label: String
    let color: Color
    let tooltip: String

    init?(usage: PickyContextUsage) {
        guard let percent = usage.percent else { return nil }
        let clamped = max(0, min(100, percent))
        self.label = "\(Int(clamped.rounded()))%"
        switch clamped {
        // SF Symbols battery glyphs run from 100 (full) down to 0 (empty), so a HIGH context %
        // maps to a LOW battery glyph (less headroom remaining).
        case 90...:
            self.symbolName = "battery.0percent"
            self.color = DS.Colors.destructive
        case 75..<90:
            self.symbolName = "battery.25percent"
            self.color = DS.Colors.warning
        case 50..<75:
            self.symbolName = "battery.50percent"
            self.color = DS.Colors.info
        case 25..<50:
            self.symbolName = "battery.75percent"
            self.color = DS.Colors.info
        default:
            self.symbolName = "battery.100percent"
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
