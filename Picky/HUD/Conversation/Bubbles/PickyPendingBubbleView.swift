//
//  PickyPendingBubbleView.swift
//  Picky
//
//  Queued steer/follow-up bubble for conversation cards.
//

import SwiftUI

enum PickyPendingQueueKind {
    case steer
    case followUp

    var color: Color {
        switch self {
        case .steer: return DS.Colors.overlayCursorBlue
        case .followUp: return DS.Colors.success
        }
    }

    var label: String {
        switch self {
        case .steer: return "⚡ Steer · pending"
        case .followUp: return "⤵ Follow-up · pending"
        }
    }

    var batchLabel: String {
        switch self {
        case .steer: return "⚡ Steering batch · 다음 turn 에 모두 (all)"
        case .followUp: return "⤵ Follow-up batch · idle 시점에 모두 (all)"
        }
    }
}

struct PickyPendingBubbleView: View {
    let queueItem: PickyQueueItem
    let kind: PickyPendingQueueKind
    @State private var isHovered = false

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .trailing, spacing: 5) {
                Text(kind.label)
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(kind.color)
                    .lineLimit(1)
                Text(queueItem.text)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if isHovered {
                    Text(enqueuedText)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .trailing)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(kind.color.opacity(0.08))
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .stroke(kind.color.opacity(isHovered ? 0.75 : 0.48), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .onHover { isHovered = $0 }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var enqueuedText: String {
        let seconds = max(0, Int(Date().timeIntervalSince(queueItem.enqueuedAt)))
        if seconds < 60 { return "queued now" }
        let minutes = seconds / 60
        if minutes < 60 { return "queued \(minutes)m ago" }
        return "queued \(minutes / 60)h ago"
    }
}
