//
//  PickyActivitySummaryView.swift
//  Picky
//
//  Compact tool-activity summary strip for conversation cards.
//

import SwiftUI

struct PickyActivitySummaryView: View {
    let summary: PickyActivitySummary
    var onOpenTerminal: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: onOpenTerminal) {
            HStack(spacing: 10) {
                activityChip("✏", label: "edit", count: summary.edit, color: DS.Colors.accentText)
                activityChip("⌨", label: "bash", count: summary.bash, color: DS.Colors.warning)
                activityChip("⌁", label: "thinking", count: summary.thinking, color: DS.Colors.textTertiary)
                activityChip("⊞", label: "기타", count: summary.other, color: DS.Colors.floatingGradientPurple)
                Spacer(minLength: 8)
                Text("↗ Terminal")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(DS.Colors.accentText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface2.opacity(0.45)))
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isHovered ? DS.Colors.accentText.opacity(0.40) : DS.Colors.borderSubtle.opacity(0.55), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
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
