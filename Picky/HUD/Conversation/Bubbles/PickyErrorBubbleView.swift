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
    // Only set when the previous user request can be safely re-sent — currently
    // exposed for the Pi SDK race where `Session.prompt()` saw isStreaming=false
    // but `agent.activeRun` had been claimed by another caller (e.g. the `until`
    // extension's scheduled iteration) during the awaits in between, so the
    // follow-up/steer was rejected before delivery.
    var onRetry: (() -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
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
                        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous).fill(DS.Colors.surface2.opacity(0.86)))
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let errorContext = message.errorContext, !errorContext.isEmpty {
                    Text(errorContext)
                        .font(PickyHUDTypography.labelMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    if let onRetry, Self.isRecoverableRuntimeRace(errorMessage: message.errorMessage) {
                        recoveryChip(Self.retryLabel, color: DS.Colors.accentText, action: onRetry)
                    }
                    recoveryChip(Self.openTerminalLabel, color: DS.Colors.accentText, action: onOpenTerminal)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(
                maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(
                    forDetailWidth: pickyHUDDetailWidth,
                    fraction: 0.88,
                    oppositeSideReserve: 36,
                    contentKind: .narrative
                ),
                alignment: .leading
            )
            .background(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .fill(DS.Colors.destructiveText.opacity(0.07))
            )
            .overlay(
                PickyConversationBubbleLayout.bubbleShape(side: .agent)
                    .stroke(DS.Colors.destructiveText.opacity(0.58), lineWidth: 1)
            )
            Spacer(minLength: 36)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static let openTerminalLabel = "⌨ Open Terminal"
    static let retryLabel = "↻ Retry"

    var recoveryChipLabels: [String] {
        var labels: [String] = []
        if onRetry != nil, Self.isRecoverableRuntimeRace(errorMessage: message.errorMessage) {
            labels.append(Self.retryLabel)
        }
        labels.append(Self.openTerminalLabel)
        return labels
    }

    // Pi SDK `Session.prompt()` re-checks `isStreaming` only before its first
    // await, then runs `_checkCompaction` / `emitBeforeAgentStart` before
    // finally calling `agent.prompt()`. An extension callback firing inside one
    // of those awaits can claim `agent.activeRun` first, which surfaces here as
    // "Agent is already processing a prompt." The user's text was never
    // delivered, so resending it now queues safely behind the in-flight run.
    static func isRecoverableRuntimeRace(errorMessage: String?) -> Bool {
        guard let errorMessage else { return false }
        return errorMessage.localizedCaseInsensitiveContains("Agent is already processing a prompt")
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
