//
//  PickyErrorBubbleView.swift
//  Picky
//
//  Runtime error bubble for conversation cards.
//

import SwiftUI

struct PickyErrorBubbleView: View {
    let message: PickySessionMessage
    // Only set for the latest error while its session is still failed. The
    // caller chooses whether Retry must resend an undelivered request or send a
    // short continuation prompt for an accepted runtime failure.
    var onRetry: (() -> Void)? = nil

    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth

    var body: some View {
        HStack(spacing: PickyConversationBubbleLayout.horizontalStackSpacing) {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text("hud.error.header")
                } icon: {
                    Image(systemName: "exclamationmark.triangle")
                }
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
                if let onRetry {
                    recoveryChip(
                        "hud.error.retry",
                        systemImage: "arrow.clockwise",
                        accessibilityLabelKey: "hud.error.retry.accessibilityLabel",
                        color: DS.Colors.accentText,
                        action: onRetry
                    )
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(
                maxWidth: PickyConversationBubbleLayout.maxBubbleWidth(
                    forDetailWidth: pickyHUDDetailWidth,
                    fraction: 0.88,
                    oppositeSideReserve: 36
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

    static var retryLabel: String { L10n.t("hud.error.retry") }

    var recoveryChipLabels: [String] {
        onRetry == nil ? [] : [Self.retryLabel]
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

    private func recoveryChip(
        _ labelKey: LocalizedStringKey,
        systemImage: String,
        accessibilityLabelKey: LocalizedStringKey,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(labelKey, systemImage: systemImage)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundColor(color)
                .lineLimit(1)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(Capsule().fill(color.opacity(0.10)))
                .overlay(Capsule().stroke(color.opacity(0.32), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(accessibilityLabelKey))
    }
}
