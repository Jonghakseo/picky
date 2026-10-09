//
//  PickyHubMainTaskBlocks.swift
//  Picky
//
//  Blocks for the main agent's Tasks and Pickle delegation questions in the
//  Recent Conversation timeline. Each block sits in the turn it started in
//  (`PickyMainTaskPresentation.timelineItems`) and keeps its place while its
//  state changes, so the transcript never jumps. Tasks outlive the reply that
//  started them, which is why they get their own block instead of riding on the
//  turn's activity chip. An answered question stays as one line.
//

import SwiftUI

// MARK: - Task block

/// No header line of its own: the block follows the Picky reply that started it.
struct PickyHubMainTaskBlock: View {
    let row: PickyMainTaskRowModel
    @ObservedObject var store: PickyMainTaskStore
    @State private var showsDetails = false

    private var hasButtons: Bool { row.showsStop || row.showsResume }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Image(systemName: row.state.symbolName)
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(PickyHubMainTaskPalette.color(for: row.state.tone))
                    .accessibilityHidden(true)
                Text(row.task.title)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let tierLabelKey = row.tierLabelKey {
                    PickyHubBadgePill(text: L10n.t(tierLabelKey))
                        .help(PickyMainTaskPresentation.modelText(for: row.task.selection) ?? "")
                }
                Spacer(minLength: PickyHubTheme.Spacing.related)
                if let start = row.elapsedSince {
                    PickyHubMainTaskElapsedLabel(start: start)
                }
                Text(LocalizedStringKey(row.state.labelKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubMainTaskPalette.color(for: row.state.tone))
                // Without a button row the link rides on the title line, so a
                // finished Task stays one line in the conversation.
                if !hasButtons { detailsLink }
            }
            if let noteKey = row.noteKey {
                Text(LocalizedStringKey(noteKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = store.commandError(for: row.task.id) {
                PickyHubInlineStatus(
                    tone: .error,
                    message: error,
                    actionTitle: "hub.tasks.error.dismiss",
                    action: { store.clearCommandError(for: row.task.id) }
                )
            }
            if hasButtons {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    if row.showsStop {
                        PickyHubButton(
                            title: "hub.tasks.action.stop",
                            role: .secondary,
                            systemImage: "stop.fill",
                            isBusy: store.isPending(row.task.id),
                            action: { Task { await store.control(taskID: row.task.id, action: .stop) } }
                        )
                    }
                    if row.showsResume {
                        PickyHubButton(
                            title: "hub.tasks.action.resume",
                            role: .secondary,
                            systemImage: "play.fill",
                            isBusy: store.isPending(row.task.id),
                            action: { Task { await store.control(taskID: row.task.id, action: .resume) } }
                        )
                    }
                    detailsLink
                    Spacer(minLength: 0)
                }
            }
            if showsDetails {
                PickyHubMainTaskDetails(row: row)
            }
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityLabel))
        .frame(maxWidth: PickyHubConversationEntryLayout.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityLabel: String {
        [L10n.t("hub.tasks.block.label"), row.task.title, row.tierLabelKey.map { L10n.t($0) }, L10n.t(row.state.labelKey)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private var detailsLink: some View {
        PickyHubTextLink(
            title: showsDetails ? "hub.tasks.detail.hide" : "hub.tasks.detail.show",
            action: { showsDetails.toggle() }
        )
    }
}

/// Ticks slowly on its own so a running clock never re-renders the transcript
/// or the composer. Reduce Motion does not apply: this is information, not motion.
private struct PickyHubMainTaskElapsedLabel: View {
    let start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: PickyHubMainTaskElapsedLabel.tick)) { context in
            let text = PickyMainTaskPresentation.elapsedText(since: start, now: context.date)
            Text(text)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .accessibilityLabel(Text(L10n.t("hub.tasks.elapsed", text)))
        }
    }

    private static let tick: TimeInterval = 5
}

private struct PickyHubMainTaskDetails: View {
    let row: PickyMainTaskRowModel

    private var task: PickyMainTask { row.task }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            if let detailNoteKey = row.detailNoteKey {
                Text(LocalizedStringKey(detailNoteKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            field(titleKey: "hub.tasks.detail.instructions", lines: task.instructions)
            if let report = task.report {
                if !report.summary.isEmpty {
                    field(titleKey: "hub.tasks.detail.summary", lines: [report.summary])
                }
                field(titleKey: "hub.tasks.detail.artifacts", lines: report.artifacts, emptyKey: "hub.tasks.detail.artifacts.none")
                // An empty list means nothing was run; it must not read as passed.
                field(titleKey: "hub.tasks.detail.verification", lines: report.verification, emptyKey: "hub.tasks.detail.verification.none")
                if !report.blockers.isEmpty {
                    field(titleKey: "hub.tasks.detail.blockers", lines: report.blockers)
                }
            }
            if let error = task.error, !error.isEmpty {
                field(titleKey: "hub.tasks.detail.error", lines: [error])
            }
            if let model = PickyMainTaskPresentation.modelText(for: task.selection) {
                field(titleKey: "hub.tasks.detail.model", lines: [model])
            }
            field(titleKey: "hub.tasks.detail.cwd", lines: [task.cwd], monospaced: true)
            if task.readonly {
                Text("hub.tasks.detail.readonly")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, PickyHubTheme.Spacing.related)
    }

    @ViewBuilder
    private func field(
        titleKey: String,
        lines: [String],
        emptyKey: String? = nil,
        monospaced: Bool = false
    ) -> some View {
        if !lines.isEmpty || emptyKey != nil {
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(titleKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                if lines.isEmpty, let emptyKey {
                    Text(LocalizedStringKey(emptyKey))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                } else {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                            .foregroundColor(PickyHubTheme.Colors.textSecondary)
                            .monospaced(monospaced)
                            .fixedSize(horizontal: false, vertical: true)
                            .pickyHubSelectableText()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Delegation question block

/// A question that still needs the user, or one whose Pickle is being made or
/// could not be made. The question leads; the scope is the second line. The
/// buttons follow the HUD question panel: cancel leads as a quiet link and the
/// primary answer ends the row.
struct PickyHubMainDelegationBlock: View {
    let row: PickyMainDelegationRowModel
    @ObservedObject var store: PickyMainTaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Image(systemName: row.showsRetry ? "exclamationmark.triangle.fill" : "arrow.triangle.branch")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(row.showsRetry ? PickyHubTheme.Colors.danger : PickyHubTheme.Colors.action)
                    .accessibilityHidden(true)
                Text(headline)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }
            Text(row.decision.title)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            if row.showsRetry, let error = row.decision.pickle?.error {
                PickyHubInlineStatus(tone: .error, message: error)
            }
            if let error = store.commandError(for: row.decision.id) {
                PickyHubInlineStatus(
                    tone: .error,
                    message: error,
                    actionTitle: "hub.tasks.error.dismiss",
                    action: { store.clearCommandError(for: row.decision.id) }
                )
            }
            controls
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Same rule as the HUD question panel: a question waiting on the user carries an accent outline.
        .pickyHubCard(
            radius: PickyHubTheme.Radius.cardCompact,
            fill: PickyHubTheme.Colors.actionTint,
            border: row.showsChoices ? PickyHubTheme.Colors.action.opacity(0.45) : PickyHubTheme.Colors.border
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(headline), \(row.decision.title)"))
        .frame(maxWidth: PickyHubConversationEntryLayout.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The agent's own question while it waits or the Pickle is being made; a
    /// failed creation says what went wrong instead.
    private var headline: String {
        if row.showsRetry { return L10n.t(row.messageKey) }
        if let question = row.decision.question, !question.isEmpty { return question }
        return L10n.t("hub.tasks.decision.pending")
    }

    @ViewBuilder
    private var controls: some View {
        if row.isBusy {
            PickyHubLoadingRow(message: LocalizedStringKey(row.messageKey))
        } else if row.showsChoices || row.showsRetry {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                PickyHubTextLink(title: "hub.tasks.decision.cancel") { resolve(.cancel) }
                    .disabled(store.isPending(row.decision.id))
                Spacer(minLength: PickyHubTheme.Spacing.related)
                PickyHubButton(
                    title: "hub.tasks.decision.runAsTask",
                    role: .secondary,
                    isBusy: store.isPending(row.decision.id),
                    action: { resolve(.task) }
                )
                PickyHubButton(
                    title: row.showsChoices ? "hub.tasks.decision.handToPickle" : "hub.tasks.decision.retry",
                    role: .primary,
                    systemImage: row.showsChoices ? "shippingbox" : "arrow.clockwise",
                    isBusy: store.isPending(row.decision.id),
                    action: { resolve(.pickle) }
                )
            }
        }
    }

    private func resolve(_ choice: PickyMainDelegationChoice) {
        Task { await store.resolve(decisionID: row.decision.id, choice: choice) }
    }
}

/// An answered question, kept as one line so the conversation keeps what was decided.
struct PickyHubMainDelegationRecord: View {
    let row: PickyMainDelegationRowModel
    let opener: PickyPickleOpener?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbolName)
                .pickyFont(size: 11, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(row.decision.title)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(row.decision.title)
            Text(verbatim: "·")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .accessibilityHidden(true)
            Text(LocalizedStringKey(row.messageKey))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize()
            if let sessionID = row.pickleSessionID, let opener, opener.canOpen(sessionID) {
                PickyHubTextLink(title: "hub.tasks.decision.openPickle") { opener.open(sessionID) }
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .frame(minHeight: PickyHubTheme.Control.minimumHeight)
        .accessibilityElement(children: .contain)
        .frame(maxWidth: PickyHubConversationEntryLayout.maxWidth, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbolName: String {
        switch row.outcome {
        case .handedToPickle: "arrow.turn.up.right"
        case .keptWithPicky: "play.circle"
        case .cancelled, .none: "xmark.circle"
        }
    }
}

// MARK: - Waiting question bar

/// The phone's pinned-question bar on the Mac: shown above the composer only
/// while the question waiting on the user is out of view. Answer scrolls to it;
/// the answer itself is still given in the block.
struct PickyHubWaitingQuestionBar: View {
    let question: String
    let onAnswer: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: PickyHubTheme.Spacing.related) {
            Image(systemName: "questionmark.circle.fill")
                .pickyFont(size: 14, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.action)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("hud.question.needed")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.action)
                Text(question)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: PickyHubTheme.Spacing.related)
            PickyHubButton(title: "hub.conversation.waitingQuestion.answer", role: .primary, action: onAnswer)
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.related)
        .pickyHubCard(
            radius: PickyHubTheme.Radius.cardCompact,
            fill: PickyHubTheme.Colors.actionTint,
            border: PickyHubTheme.Colors.action.opacity(0.45)
        )
        .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
        .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
        .padding(.bottom, PickyHubTheme.Spacing.related)
        .frame(maxWidth: .infinity)
    }
}

enum PickyHubMainTaskPalette {
    static func color(for tone: PickyMainTaskTone) -> Color {
        switch tone {
        case .neutral: PickyHubTheme.Colors.textTertiary
        case .active: PickyHubTheme.Colors.action
        case .success: PickyHubTheme.Colors.success
        case .warning: PickyHubTheme.Colors.warning
        case .danger: PickyHubTheme.Colors.danger
        }
    }
}
