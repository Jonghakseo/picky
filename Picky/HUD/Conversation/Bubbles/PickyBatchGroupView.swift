//
//  PickyBatchGroupView.swift
//  Picky
//
//  Batched queue wrapper for conversation cards.
//

import SwiftUI

struct PickyBatchGroupView: View {
    let items: [PickyQueueItem]
    let kind: PickyPendingQueueKind

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            Label(kind.batchLabel, systemImage: kind.iconName)
                .font(PickyHUDTypography.metaBold)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PickyPendingBubbleView(queueItem: item, kind: kind)
            }
        }
        .padding(DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous).fill(DS.Colors.surface2))
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .stroke(DS.Colors.borderSubtle, style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
