//
//  PickyUserBubbleView.swift
//  Picky
//
//  User-authored message bubble for conversation cards.
//

import SwiftUI

struct PickyUserBubbleView: View {
    let message: PickySessionMessage

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            VStack(alignment: .leading, spacing: 4) {
                Text(message.text ?? "")
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let originLabel {
                    Text(originLabel)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 12,
                    bottomTrailingRadius: 4,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(DS.Colors.accentSubtle.opacity(0.95))
            )
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .trailing)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var displayedOriginLabel: String? { originLabel }

    private var originLabel: String? {
        switch message.originatedBy {
        case .mainAgent:
            return "by main agent"
        case .piExtension:
            return "by Pi terminal"
        case .user, nil:
            return nil
        }
    }
}
