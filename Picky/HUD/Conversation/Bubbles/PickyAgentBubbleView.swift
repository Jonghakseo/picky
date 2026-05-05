//
//  PickyAgentBubbleView.swift
//  Picky
//
//  Plain agent message bubble for conversation cards.
//

import SwiftUI

struct PickyAgentBubbleView: View {
    let message: PickySessionMessage

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayText)
                    .font(.system(size: 12))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.85, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(DS.Colors.surface2.opacity(0.85))
            )
            Spacer(minLength: 48)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayText: String {
        if let text = message.text, !text.isEmpty { return text }
        if let errorMessage = message.errorMessage, !errorMessage.isEmpty { return errorMessage }
        if let report = message.report { return report.summary }
        if let question = message.question { return question.prompt ?? question.title ?? "Input requested" }
        return ""
    }
}
