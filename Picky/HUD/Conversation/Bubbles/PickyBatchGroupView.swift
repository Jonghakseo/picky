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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(kind.batchLabel)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(kind.color)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text("Clear all")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                PickyPendingBubbleView(queueItem: item, kind: kind)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(kind.color.opacity(0.05)))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(kind.color.opacity(0.42), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
        )
    }
}
