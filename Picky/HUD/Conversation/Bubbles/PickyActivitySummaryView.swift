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
            activityChip("✏", label: "edit", count: summary.edit, color: DS.Colors.accentText)
            activityChip("⌨", label: "bash", count: summary.bash, color: DS.Colors.warning)
            activityChip("⌁", label: "thinking", count: summary.thinking, color: DS.Colors.textTertiary)
            activityChip("⊞", label: "기타", count: summary.other, color: DS.Colors.floatingGradientPurple)
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
