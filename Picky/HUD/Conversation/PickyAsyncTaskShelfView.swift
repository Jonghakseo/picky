import SwiftUI

/// Presentation only. W6b supplies the narrow detail-store snapshot and real command capabilities.
struct PickyAsyncTaskShelfView: View {
    let summary: PickyAsyncWorkSummary
    let detailState: PickyProjectionSectionState<PickyAsyncTaskDetail>
    let cancelAvailability: (PickyAsyncTask) -> PickyAsyncTaskCancelAvailability
    let onAction: (PickyAsyncTaskShelfAction) -> Void
    @State private var isExpanded: Bool

    init(summary: PickyAsyncWorkSummary, detailState: PickyProjectionSectionState<PickyAsyncTaskDetail>,
         initiallyExpanded: Bool = false,
         cancelAvailability: @escaping (PickyAsyncTask) -> PickyAsyncTaskCancelAvailability,
         onAction: @escaping (PickyAsyncTaskShelfAction) -> Void) {
        self.summary = summary
        self.detailState = detailState
        self.cancelAvailability = cancelAvailability
        self.onAction = onAction
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    var body: some View {
        if PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: detailState) {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                Text("hud.asyncTasks.title")
                    .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize, weight: .semibold)
                Text(L10n.t("hud.asyncTasks.counts", summary.activeRootCount, summary.pendingCompletionCount,
                            summary.uncertainExecutionCount, summary.attentionCount))
                    .pickyFont(size: PickyHUDTypography.metaNSFont(fontScale: 1).pointSize)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if summary.tracking != .ready {
                    Label(L10n.t(summary.tracking == .reconciling ? "hud.asyncTasks.reconciling" : "hud.asyncTasks.unsupported"),
                          systemImage: "exclamationmark.circle")
                        .foregroundStyle(DS.Colors.warningText)
                }
                switch detailState {
                case .unavailable:
                    Text("hud.asyncTasks.detailUnavailable")
                        .foregroundStyle(DS.Colors.textSecondary)
                case .loaded(let detail):
                    taskList(detail)
                }
            }
            .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
            .foregroundStyle(DS.Colors.textPrimary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.space2)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.control))
        }
    }

    @ViewBuilder
    private func taskList(_ detail: PickyAsyncTaskDetail) -> some View {
        let roots = PickyAsyncTaskShelfPresentation.roots(in: detail)
        if roots.isEmpty {
            Text("hud.asyncTasks.noDetails")
                .foregroundStyle(DS.Colors.textSecondary)
        } else {
            if isExpanded {
                ScrollView {
                    rows(roots, detail: detail)
                }
                .frame(maxHeight: 280)
            } else {
                rows(Array(roots.prefix(3)), detail: detail)
            }
            if roots.count > 3 {
                Button {
                    isExpanded.toggle()
                } label: {
                    Label(isExpanded ? L10n.t("hud.asyncTasks.showLess") : L10n.t("hud.asyncTasks.showMore", roots.count - 3),
                          systemImage: isExpanded ? "chevron.up" : "chevron.down")
                        .frame(minHeight: 24)
                }
                .buttonStyle(.borderless)
                .tint(DS.Colors.accentText)
            }
        }
    }

    private func rows(_ roots: [PickyAsyncTask], detail: PickyAsyncTaskDetail) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            ForEach(roots, id: \.shelfIdentity) { root in
                PickyAsyncTaskShelfRowView(root: root, detail: detail, summary: summary,
                                          availability: cancelAvailability(root), onAction: onAction)
            }
        }
    }
}

extension PickyAsyncTask {
    var shelfIdentity: PickyAsyncTaskShelfIdentity { PickyAsyncTaskShelfIdentity(self) }
}

struct PickyAsyncTaskShelfRowView: View {
    let root: PickyAsyncTask
    let detail: PickyAsyncTaskDetail
    let summary: PickyAsyncWorkSummary
    let availability: PickyAsyncTaskCancelAvailability
    let onAction: (PickyAsyncTaskShelfAction) -> Void
    @State var isExpanded = false

    private var members: [PickyAsyncTask] { PickyAsyncTaskShelfPresentation.members(of: root, in: detail) }
    private var tickets: [PickyCompletionTicket] { PickyAsyncTaskShelfPresentation.tickets(for: root, in: detail) }
    private var canCancel: Bool {
        PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary, availability: availability)
    }
    private var kindSymbol: String {
        switch root.kind {
        case "bash": "terminal"
        case "subagent", "subagent_group", "subagent-group": "person.2"
        default: "gearshape.2"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            HStack(alignment: .top, spacing: DS.Spacing.space2) {
                Image(systemName: kindSymbol).accessibilityHidden(true)
                Text(root.title)
                    .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize, weight: .semibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(2)
                    .help(root.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    guard canCancel else { return }
                    onAction(.cancel(owner: root.owner, taskID: root.taskId))
                } label: {
                    Text("hud.asyncTasks.stop")
                        .foregroundStyle(canCancel ? DS.Colors.accentText : DS.Colors.textTertiary)
                        .frame(minHeight: 24)
                }
                .buttonStyle(.borderless)
                .tint(DS.Colors.accentText)
                .disabled(!canCancel)
                .accessibilityLabel(L10n.t("hud.asyncTasks.stopNamed", root.title))
                .help(availability.explanation ?? L10n.t("hud.asyncTasks.stopHelp"))
            }
            executionLabel(root)
            if let key = PickyAsyncTaskShelfPresentation.resultKey(tickets) {
                Label(L10n.t(key), systemImage: key.hasSuffix("failed") ? "exclamationmark.triangle" : "tray")
                    .foregroundStyle(key.hasSuffix("failed") ? DS.Colors.destructiveText : DS.Colors.warningText)
            }
            if let explanation = availability.explanation {
                Label(explanation, systemImage: failureSymbol)
                    .foregroundStyle(failureColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            DisclosureGroup(isExpanded: $isExpanded) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                        Text(root.title).textSelection(.enabled)
                        if let progress = root.progress, !progress.isEmpty {
                            Text(progress).textSelection(.enabled)
                        }
                        ForEach(members.filter { $0.taskId != root.taskId }, id: \.shelfIdentity) { child in
                            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                                Text(child.title).lineLimit(2).help(child.title)
                                executionLabel(child)
                                if let progress = child.progress { Text(progress).lineLimit(3).help(progress) }
                            }
                        }
                        ForEach(Array(tickets.enumerated()), id: \.offset) { _, ticket in
                            if let reason = ticket.failureReason { Text(reason).textSelection(.enabled) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            } label: {
                Text(members.count > 1 ? L10n.t("hud.asyncTasks.groupDetails", members.count - 1) : L10n.t("hud.asyncTasks.details"))
                    .frame(minHeight: 24)
            }
            .tint(DS.Colors.accentText)
            .accessibilityLabel(L10n.t("hud.asyncTasks.detailsNamed", root.title))
        }
        .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
        .foregroundStyle(DS.Colors.textSecondary)
        .padding(DS.Spacing.space2)
        .background(DS.Colors.surface1, in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
    }

    private var failureSymbol: String {
        if case .failed = availability { return "exclamationmark.triangle" }
        return "info.circle"
    }
    private var failureColor: Color {
        if case .failed = availability { return DS.Colors.destructiveText }
        return DS.Colors.textSecondary
    }

    private func executionLabel(_ task: PickyAsyncTask) -> some View {
        let unknown = task.presence == .unknown
        let failed = task.execution == .failed || task.execution == .interrupted
        let symbol = unknown ? "questionmark.circle" : failed ? "exclamationmark.triangle" :
            task.execution == .cancelled ? "stop.circle" : task.presence == .active || task.execution == .queued ? "clock" : "checkmark.circle"
        let color = unknown ? DS.Colors.warningText : failed ? DS.Colors.destructiveText :
            task.presence == .active ? DS.Colors.info : DS.Colors.textSecondary
        return Label(L10n.t(PickyAsyncTaskShelfPresentation.executionKey(task)), systemImage: symbol)
            .foregroundStyle(color)
    }
}
