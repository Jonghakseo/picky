//
//  PickyCommandReceiptBubbleView.swift
//  Picky
//
//  Minimal command receipt bubble for slash commands that are not user chat.
//

import SwiftUI

struct PickyCommandReceiptBubbleView: View {
    let message: PickySessionMessage

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            Spacer(minLength: PickyConversationBubbleLayout.oppositeSideReserve)
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(displayCommand)
                    .font(PickyHUDTypography.labelMonospacedSemibold)
                    .foregroundColor(foregroundColor)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if showsFailedLabel {
                    Text("failed")
                        .font(PickyHUDTypography.statusMedium)
                        .foregroundColor(DS.Colors.destructiveText)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: bubbleMaxWidth, alignment: .trailing)
            .background(commandBubbleShape.fill(DS.Colors.surface1.opacity(0.94)))
            .overlay(commandBubbleShape.stroke(borderColor, lineWidth: 0.7))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    var displayCommand: String {
        let command = message.commandReceipt?.command ?? message.text ?? ""
        return command.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var showsFailedLabel: Bool {
        message.commandReceipt?.status == .failed
    }

    private var bubbleMaxWidth: CGFloat {
        PickyConversationBubbleLayout.maxBubbleWidth(forDetailWidth: pickyHUDDetailWidth)
    }

    private var foregroundColor: Color {
        showsFailedLabel ? DS.Colors.destructiveText : DS.Colors.textPrimary
    }

    private var borderColor: Color {
        showsFailedLabel ? DS.Colors.destructiveText.opacity(0.38) : DS.Colors.borderSubtle.opacity(0.82)
    }

    private var accessibilityLabel: String {
        showsFailedLabel ? "Command failed: \(displayCommand)" : "Command submitted: \(displayCommand)"
    }
}

private var commandBubbleShape: UnevenRoundedRectangle {
    UnevenRoundedRectangle(
        topLeadingRadius: 12,
        bottomLeadingRadius: 12,
        bottomTrailingRadius: 4,
        topTrailingRadius: 12,
        style: .continuous
    )
}
