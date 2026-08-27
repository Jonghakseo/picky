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

    /// Queue evidence is neutral in both kinds. Text and symbols distinguish
    /// routing intent without turning pending work into an action or success.
    var evidenceTone: PickyQueueEvidenceTone { .neutral }

    var color: Color { DS.Colors.textSecondary }

    var iconName: String {
        switch self {
        case .steer: return "arrowshape.turn.up.right"
        case .followUp: return "arrow.uturn.forward"
        }
    }

    var label: String {
        switch self {
        case .steer: return "Steer pending"
        case .followUp: return "Follow-up pending"
        }
    }

    var batchLabel: String {
        switch self {
        case .steer: return "Steering batch · all next turn"
        case .followUp: return "Follow-up batch · all when idle"
        }
    }
}

struct PickyPendingBubbleView: View {
    let queueItem: PickyQueueItem
    let kind: PickyPendingQueueKind

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            VStack(alignment: .leading, spacing: 5) {
                Label(kind.label, systemImage: kind.iconName)
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(PickyQueuedInputText.displayText(from: queueItem.text))
                    .font(PickyHUDTypography.body)
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                PickyConversationBubbleLayout.bubbleShape(side: .user)
                    .fill(kind.color.opacity(0.08))
            )
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .user)
                    .stroke(kind.color.opacity(0.48), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            .frame(maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth), alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}
