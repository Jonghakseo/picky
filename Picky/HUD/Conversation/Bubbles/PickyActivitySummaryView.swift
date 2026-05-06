//
//  PickyActivitySummaryView.swift
//  Picky
//
//  Compact tool-activity summary strip for conversation cards.
//

import SwiftUI

struct PickyActivitySummaryView: View {
    let summary: PickyActivitySummary

    var body: some View {
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
            Text(label)
            Text("\(count)")
                .fontWeight(.bold)
        }
        .font(.system(size: 10.5, weight: .medium, design: .monospaced))
        .foregroundColor(color)
        .lineLimit(1)
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
