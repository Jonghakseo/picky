//
//  PickyErrorBubbleView.swift
//  Picky
//
//  Runtime error bubble for conversation cards.
//

import SwiftUI

struct PickyErrorBubbleView: View {
    let message: PickySessionMessage
    var onRetry: () -> Void = {}
    var onOpenTerminal: () -> Void = {}
    var onOpenLogs: () -> Void = {}

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text("⚠ FAILED · runtime error")
                    .font(.system(size: 9.5, weight: .bold))
                    .foregroundColor(DS.Colors.destructiveText)
                    .lineLimit(1)
                Text(title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundColor(DS.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let errorMessage = message.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(DS.Colors.textPrimary)
                        .padding(7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.Colors.surface2.opacity(0.86)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorContext = message.errorContext, !errorContext.isEmpty {
                    Text(errorContext)
                        .font(.system(size: 10.5))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    recoveryChip("↻ 다시 시도", color: DS.Colors.destructiveText, action: onRetry)
                    recoveryChip("⌨ Terminal 열기", color: DS.Colors.accentText, action: onOpenTerminal)
                    recoveryChip("📄 전체 로그", color: DS.Colors.accentText, action: onOpenLogs)
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

    private var title: String {
        let text = message.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? "Runtime error" : text
    }

    private func recoveryChip(_ label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
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
