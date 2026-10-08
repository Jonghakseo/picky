//
//  PickyFeedbackOutboxSection.swift
//  Picky
//
//  Durable state for feedback the user already submitted. The form closes on
//  Send, so this is where a queued, failed, or unconfirmed submission stays
//  visible and recoverable.
//

import SwiftUI

struct PickyFeedbackOutboxSection: View {
    @ObservedObject var outbox: PickyFeedbackOutboxCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("feedback.outbox.title")
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)

            VStack(spacing: 6) {
                ForEach(outbox.items) { item in
                    PickyFeedbackOutboxRow(
                        item: item,
                        onRetry: { outbox.retry(id: item.id, acceptingDuplicateRisk: item.state.hasDuplicateRisk) },
                        onDiscard: { outbox.discard(id: item.id) }
                    )
                }
            }
        }
    }
}

private struct PickyFeedbackOutboxRow: View {
    let item: PickyFeedbackOutboxItem
    let onRetry: () -> Void
    let onDiscard: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: presentation.iconName)
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(presentation.tint)
                Text(presentation.stateLabel)
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(presentation.tint)
                Spacer(minLength: 6)
                if item.state.needsAttention {
                    Button(presentation.retryLabel, action: onRetry)
                        .buttonStyle(.plain)
                        .pickyFont(size: 11, weight: .semibold)
                        .foregroundColor(DS.Colors.accentText)
                        .hoverAffordance()
                    Button(L10n.t("feedback.outbox.discard"), action: onDiscard)
                        .buttonStyle(.plain)
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .accessibilityLabel(L10n.t("feedback.outbox.discard.accessibilityLabel"))
                        .hoverAffordance()
                }
            }

            Text(item.message)
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = item.state.reason {
                Text(reason)
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(presentation.tint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.45))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.5)
        )
    }

    private var presentation: Presentation {
        switch item.state {
        case .pending:
            return Presentation(
                iconName: "clock",
                tint: DS.Colors.textSecondary,
                stateLabel: L10n.t("feedback.outbox.state.queued"),
                retryLabel: L10n.t("feedback.outbox.retry")
            )
        case .inFlight:
            return Presentation(
                iconName: "arrow.up.circle",
                tint: DS.Colors.textSecondary,
                stateLabel: L10n.t("feedback.outbox.state.pending"),
                retryLabel: L10n.t("feedback.outbox.retry")
            )
        case .sent, .discarded:
            // Terminal records are dropped during recovery and never reach the
            // list; this keeps the switch total.
            return Presentation(
                iconName: "checkmark.circle",
                tint: DS.Colors.textTertiary,
                stateLabel: L10n.t("feedback.outbox.state.pending"),
                retryLabel: L10n.t("feedback.outbox.retry")
            )
        case .failed:
            return Presentation(
                iconName: "exclamationmark.circle.fill",
                tint: DS.Colors.destructiveText,
                stateLabel: L10n.t("feedback.outbox.state.failed"),
                retryLabel: L10n.t("feedback.outbox.retry")
            )
        case .deliveryUncertain:
            return Presentation(
                iconName: "questionmark.circle.fill",
                tint: DS.Colors.warningText,
                stateLabel: L10n.t("feedback.outbox.state.uncertain"),
                retryLabel: L10n.t("feedback.outbox.retryAnyway")
            )
        case .storageBlocked(_, let duplicateRisk):
            // A storage error on a job that may already be in Slack keeps the
            // warning treatment and the "send again" wording.
            return Presentation(
                iconName: duplicateRisk ? "questionmark.circle.fill" : "exclamationmark.circle.fill",
                tint: duplicateRisk ? DS.Colors.warningText : DS.Colors.destructiveText,
                stateLabel: L10n.t(
                    duplicateRisk ? "feedback.outbox.state.uncertain" : "feedback.outbox.state.failed"
                ),
                retryLabel: L10n.t(
                    duplicateRisk ? "feedback.outbox.retryAnyway" : "feedback.outbox.retry"
                )
            )
        }
    }

    private struct Presentation {
        let iconName: String
        let tint: Color
        let stateLabel: String
        let retryLabel: String
    }
}
