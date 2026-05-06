//
//  PickyErrorBubbleView.swift
//  Picky
//
//  Runtime error bubble for conversation cards.
//

import SwiftUI

struct PickyErrorBubbleView: View {
    let message: PickySessionMessage
    // Keep the recovery surface narrow: failed runs can be inspected or resumed
    // through the Pi terminal overlay.
    var onOpenTerminal: () -> Void = {}

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("⚠ FAILED · runtime error")
                    .font(PickyHUDTypography.metaBold)
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(1)
                if let titleText {
                    Text(titleText)
                        .font(PickyHUDTypography.bodyCompactMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorMessage = message.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(PickyHUDTypography.labelMonospacedMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface2.opacity(0.86)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorContext = message.errorContext, !errorContext.isEmpty {
                    Text(errorContext)
                        .font(PickyHUDTypography.labelMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    recoveryChip(Self.openTerminalLabel, color: DS.Colors.accentText, action: onOpenTerminal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: PickyHUDDockLayout.detailWidth * 0.88, alignment: .leading)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .fill(DS.Colors.destructiveText.opacity(0.07))
            )
            .overlay(
                UnevenRoundedRectangle(
                    topLeadingRadius: 12,
                    bottomLeadingRadius: 4,
                    bottomTrailingRadius: 12,
                    topTrailingRadius: 12,
                    style: .continuous
                )
                .stroke(DS.Colors.destructiveText.opacity(0.58), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let openTerminalLabel = "⌨ Open Terminal"

    var recoveryChipLabels: [String] {
        [Self.openTerminalLabel]
    }

    var titleText: String? {
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else { return nil }
        guard text.localizedCaseInsensitiveCompare("Runtime error") != .orderedSame else { return nil }
        return text
    }

    private func recoveryChip(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(color)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.10)))
                .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
