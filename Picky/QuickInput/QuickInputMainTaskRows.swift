//
//  QuickInputMainTaskRows.swift
//  Picky
//
//  Compact rows for the main agent's Tasks and Pickle delegation questions in
//  the Quick Input history card. The card is a short peek, so a Task is one
//  status line (stop, resume, and details live in Recent Conversation or are a
//  spoken request away); only a question has buttons, the same ones as the
//  HUD question panel, so it can be answered right here.
//

import SwiftUI

/// One line: what the Task is and where it stands.
struct QuickInputMainTaskRow: View {
    let row: PickyMainTaskRowModel

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: row.state.symbolName)
                .font(PickyHUDTypography.status)
                .foregroundColor(QuickInputMainTaskPalette.color(for: row.state.tone))
                .accessibilityHidden(true)
            Text(row.task.title)
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(DS.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.task.title)
            Spacer(minLength: 6)
            if let start = row.elapsedSince {
                QuickInputMainTaskElapsedLabel(start: start)
            }
            Text(LocalizedStringKey(row.state.labelKey))
                .font(PickyHUDTypography.statusMedium)
                .foregroundColor(QuickInputMainTaskPalette.color(for: row.state.tone))
                .fixedSize()
        }
        .padding(.horizontal, 10) // design-token-exception: same 10pt inset as the question card so Task rows and cards line up
        .padding(.vertical, 7) // design-token-exception: keeps the one-line status row compact in the short history peek
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2.opacity(0.8))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("\(L10n.t("hub.tasks.block.label")), \(row.task.title), \(L10n.t(row.state.labelKey))"))
    }
}

/// Ticks on its own, so a running clock never re-renders the transcript or the field.
private struct QuickInputMainTaskElapsedLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 5)) { context in
            let text = PickyMainTaskPresentation.elapsedText(since: start, now: context.date)
            Text(text)
                .font(PickyHUDTypography.statusMonospacedMedium)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityLabel(Text(L10n.t("hub.tasks.elapsed", text)))
        }
    }
}

/// A question still waiting on the user, or one whose Pickle is being made or
/// could not be made. Answering here also closes the HUD question panel.
struct QuickInputMainDelegationBlock: View {
    let row: PickyMainDelegationRowModel
    @ObservedObject var store: PickyMainTaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: row.showsRetry ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(row.showsRetry ? DS.Colors.destructiveText : DS.Colors.accentText)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(PickyHUDTypography.bodyCompactMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(row.decision.title)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let error = failure {
                        Text(error)
                            .font(PickyHUDTypography.supporting)
                            .foregroundColor(DS.Colors.destructiveText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            controls
        }
        // Full card width even without a button row (while the Pickle is being made).
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10) // design-token-exception: same 10pt inset as the Task rows above
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous)
                .fill(DS.Colors.accentSubtle)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.surface, style: .continuous)
                .stroke(DS.Colors.accent.opacity(row.showsChoices ? 0.35 : 0.15), lineWidth: 0.8)
        )
    }

    private var headline: String {
        if row.showsRetry { return L10n.t(row.messageKey) }
        if let question = row.decision.question, !question.isEmpty { return question }
        return L10n.t("hub.tasks.decision.pending")
    }

    /// The Pickle's own error, or a command the daemon refused.
    private var failure: String? {
        store.commandError(for: row.decision.id) ?? (row.showsRetry ? row.decision.pickle?.error : nil)
    }

    @ViewBuilder
    private var controls: some View {
        if row.isBusy {
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityHidden(true)
                Text(LocalizedStringKey(row.messageKey))
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.textSecondary)
            }
        } else if row.showsChoices || row.showsRetry {
            // Same order as the HUD question panel: cancel leads, the primary answer ends the row.
            HStack(spacing: 6) {
                Button(L10n.t("hub.tasks.decision.cancel")) { resolve(.cancel) }
                    .buttonStyle(PickyQuestionGhostButtonStyle())
                Spacer(minLength: 4)
                Button(L10n.t("hub.tasks.decision.runAsTask")) { resolve(.task) }
                    .buttonStyle(PickyQuestionSecondaryButtonStyle())
                Button(L10n.t(row.showsChoices ? "hub.tasks.decision.handToPickle" : "hub.tasks.decision.retry")) { resolve(.pickle) }
                    .buttonStyle(PickyQuestionPrimaryButtonStyle(isBusy: store.isPending(row.decision.id)))
            }
            .disabled(store.isPending(row.decision.id))
        }
    }

    private func resolve(_ choice: PickyMainDelegationChoice) {
        Task { await store.resolve(decisionID: row.decision.id, choice: choice) }
    }
}

/// An answered question as one line, with the Pickle it created a click away.
struct QuickInputMainDelegationRecord: View {
    let row: PickyMainDelegationRowModel
    let opener: PickyPickleOpener?
    /// Closes Quick Input after the Pickle opens in the HUD.
    let onOpenPickle: (String) -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbolName)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(row.messageKey))
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.textSecondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            if let sessionID = row.pickleSessionID, let opener, opener.canOpen(sessionID) {
                Button(L10n.t("hub.tasks.decision.openPickle")) { onOpenPickle(sessionID) }
                    .buttonStyle(.plain)
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundColor(DS.Colors.accentText)
            }
        }
        .padding(.horizontal, 2) // design-token-exception: optical nudge keeping the record line inside the rounded row edges
        .help(row.decision.title)
    }

    private var symbolName: String {
        switch row.outcome {
        case .handedToPickle: "arrow.turn.up.right"
        case .keptWithPicky: "play.circle"
        case .cancelled, .none: "xmark.circle"
        }
    }
}

enum QuickInputMainTaskPalette {
    static func color(for tone: PickyMainTaskTone) -> Color {
        switch tone {
        case .neutral: DS.Colors.textTertiary
        case .active: DS.Colors.accentText
        case .success: DS.Colors.successText
        case .warning: DS.Colors.warningText
        case .danger: DS.Colors.destructiveText
        }
    }
}
