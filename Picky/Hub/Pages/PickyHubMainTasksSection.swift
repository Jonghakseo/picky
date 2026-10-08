//
//  PickyHubMainTasksSection.swift
//  Picky
//
//  Collapsible Tasks strip between the main transcript and the composer.
//  Tasks outlive the reply that started them, so they get their own place here
//  instead of riding on the turn's activity chip.
//
//  The strip keeps a fixed maximum height and only changes size when the daemon
//  reports a Task change, so a streaming reply never shifts the transcript.
//

import SwiftUI

struct PickyHubMainTasksSection: View {
    @ObservedObject var store: PickyMainTaskStore
    @State private var isExpanded = true

    private var taskRows: [PickyMainTaskRowModel] {
        PickyMainTaskPresentation.rows(for: store.snapshot.tasks)
    }

    private var delegationRows: [PickyMainDelegationRowModel] {
        PickyMainTaskPresentation.delegationRows(for: store.snapshot.decisions, tasks: store.snapshot.tasks)
    }

    var body: some View {
        let tasks = taskRows
        let decisions = delegationRows
        if !tasks.isEmpty || !decisions.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Divider().overlay(PickyHubTheme.Colors.borderSoft)
                content(tasks: tasks, decisions: decisions)
                    .frame(maxWidth: PickyHubTheme.Layout.contentMaxWidth, alignment: .leading)
                    .padding(.horizontal, PickyHubTheme.Layout.contentHorizontalPadding)
                    .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
                    .frame(maxWidth: .infinity)
            }
            .background(PickyHubTheme.Colors.canvas)
        }
    }

    @ViewBuilder
    private func content(tasks: [PickyMainTaskRowModel], decisions: [PickyMainDelegationRowModel]) -> some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            header(count: tasks.count + decisions.count)
            if let error = store.commandError {
                PickyHubInlineStatus(
                    tone: .error,
                    message: error,
                    actionTitle: "hub.tasks.error.dismiss",
                    action: store.clearCommandError
                )
            }
            if isExpanded {
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                        ForEach(decisions) { row in
                            PickyHubMainDelegationRow(row: row, store: store)
                        }
                        ForEach(tasks) { row in
                            PickyHubMainTaskRow(row: row, store: store)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 1)
                }
                .frame(maxHeight: PickyHubMainTasksLayout.maximumListHeight)
            }
        }
    }

    private func header(count: Int) -> some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .pickyFont(size: 10, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                Text("hub.tasks.title")
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                PickyHubBadgePill(text: "\(count)")
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(PickyHubPressStyle())
        .accessibilityLabel(Text(L10n.t("hub.tasks.title")))
        .accessibilityValue(Text(L10n.t("hub.tasks.count", count)))
        .accessibilityHint(Text("hub.tasks.toggle.hint"))
    }
}

enum PickyHubMainTasksLayout {
    /// The transcript stays the primary surface: the strip scrolls internally
    /// instead of growing with the number of Tasks.
    static let maximumListHeight: CGFloat = 230
}

// MARK: - Task row

private struct PickyHubMainTaskRow: View {
    let row: PickyMainTaskRowModel
    @ObservedObject var store: PickyMainTaskStore
    @State private var showsDetails = false

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
                Spacer(minLength: PickyHubTheme.Spacing.related)
                if let start = row.elapsedSince {
                    PickyHubMainTaskElapsedLabel(start: start)
                }
                Text(LocalizedStringKey(row.state.labelKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .foregroundColor(PickyHubMainTaskPalette.color(for: row.state.tone))
            }
            if let noteKey = row.noteKey {
                Text(LocalizedStringKey(noteKey))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            controls
            if showsDetails {
                PickyHubMainTaskDetails(task: row.task)
            }
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.cardCompact)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(row.task.title), \(L10n.t(row.state.labelKey))"))
    }

    private var controls: some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            PickyHubTextLink(
                title: showsDetails ? "hub.tasks.detail.hide" : "hub.tasks.detail.show",
                action: { showsDetails.toggle() }
            )
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
            Spacer(minLength: 0)
        }
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
    let task: PickyMainTask

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
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

// MARK: - Delegation decision row

private struct PickyHubMainDelegationRow: View {
    let row: PickyMainDelegationRowModel
    @ObservedObject var store: PickyMainTaskStore

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
                Image(systemName: "arrow.triangle.branch")
                    .pickyFont(size: 11, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.action)
                    .accessibilityHidden(true)
                Text(row.decision.title)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            Text(prompt)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            if row.showsChoices, !row.decision.instructions.isEmpty {
                Text(row.decision.instructions)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }
            if let error = row.decision.pickle?.error, row.showsRetry {
                PickyHubInlineStatus(tone: .error, message: error)
            }
            controls
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .frame(maxWidth: .infinity, alignment: .leading)
        .pickyHubCard(radius: PickyHubTheme.Radius.cardCompact, fill: PickyHubTheme.Colors.actionTint)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(row.decision.title), \(L10n.t(row.messageKey))"))
    }

    /// A pending decision shows the agent's own question when it asked one;
    /// otherwise the state line explains what the row is waiting for.
    private var prompt: String {
        if row.showsChoices, let question = row.decision.question, !question.isEmpty { return question }
        return L10n.t(row.messageKey)
    }

    @ViewBuilder
    private var controls: some View {
        if row.isBusy {
            PickyHubLoadingRow(message: LocalizedStringKey(row.messageKey))
        } else if row.showsChoices || row.showsRetry {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                if row.showsChoices {
                    choice(titleKey: "hub.tasks.decision.handToPickle", role: .primary, symbol: "shippingbox", choice: .pickle)
                    choice(titleKey: "hub.tasks.decision.runAsTask", role: .secondary, symbol: "play.fill", choice: .task)
                    choice(titleKey: "hub.tasks.decision.cancel", role: .secondary, symbol: nil, choice: .cancel)
                } else {
                    choice(titleKey: "hub.tasks.decision.retry", role: .secondary, symbol: "arrow.clockwise", choice: .pickle)
                    choice(titleKey: "hub.tasks.decision.runAsTask", role: .secondary, symbol: "play.fill", choice: .task)
                    choice(titleKey: "hub.tasks.decision.cancel", role: .secondary, symbol: nil, choice: .cancel)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func choice(
        titleKey: String,
        role: PickyHubButtonRole,
        symbol: String?,
        choice: PickyMainDelegationChoice
    ) -> some View {
        PickyHubButton(
            title: titleKey,
            role: role,
            systemImage: symbol,
            isBusy: store.isPending(row.decision.id),
            action: { Task { await store.resolve(decisionID: row.decision.id, choice: choice) } }
        )
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
