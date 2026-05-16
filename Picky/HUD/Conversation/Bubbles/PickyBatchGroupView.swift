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
            Text(kind.batchLabel)
                .font(PickyHUDTypography.metaBold)
                .foregroundColor(kind.color)
                .lineLimit(1)
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
