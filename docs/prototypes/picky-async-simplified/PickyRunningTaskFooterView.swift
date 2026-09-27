import SwiftUI

/// Drop-in proposal for the conversation footer. Observes the production section stores;
/// lifecycle bookkeeping and completion tickets remain in the stores, not in this surface.
struct PickyRunningTaskFooterView: View {
    let store: PickySessionStore
    let maxListHeight: CGFloat
    var compact = false
    var bottomSpacing: CGFloat = 0
    @State private var expanded = false
    @State private var selected: PickyAsyncTaskShelfIdentity?

    private var detail: PickyAsyncTaskDetail? {
        guard case .loaded(let value) = store.asyncTaskStore.detailState else { return nil }
        return value
    }

    private var summary: PickyAsyncWorkSummary? {
        guard case .loaded(let metadata) = store.metaStore.metadataState else { return nil }
        return metadata.asyncWorkSummary
    }

    private var roots: [PickyAsyncTask] {
        guard let detail, let summary, summary.tracking == .ready else { return [] }
        return PickyAsyncTaskShelfPresentation.roots(in: detail).filter { root in
            !runningMembers(of: root, detail: detail).isEmpty
        }
    }

    private func runningMembers(of root: PickyAsyncTask, detail: PickyAsyncTaskDetail) -> [PickyAsyncTask] {
        PickyAsyncTaskShelfPresentation.members(of: root, in: detail).filter {
            $0.execution == .running && $0.presence == .active
        }
    }

    var body: some View {
        if !roots.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: DS.Spacing.space2) {
                        Image(systemName: "circle.dotted")
                            .foregroundStyle(DS.Colors.info)
                            .accessibilityHidden(true)
                        Text(L10n.t("hud.asyncTasks.runningCount", roots.count))
                            .foregroundStyle(DS.Colors.textSecondary)
                        Spacer(minLength: DS.Spacing.space2)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(DS.Colors.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RunningFooterButtonStyle())
                .accessibilityLabel(L10n.t("hud.asyncTasks.runningCount", roots.count))
                .accessibilityValue(L10n.t(expanded ? "hud.asyncTasks.showLess" : "hud.asyncTasks.showWork"))
                .help(L10n.t(expanded ? "hud.asyncTasks.showLess" : "hud.asyncTasks.showWork"))
                .pickyInstantPopover(isPresented: Binding(
                    get: { compact && expanded }, set: { expanded = $0 }
                )) {
                    taskList.frame(width: 380).padding(DS.Spacing.space2)
                }
                if expanded && !compact {
                    taskList
                }
            }
            .padding(.bottom, bottomSpacing)
        }
    }

    private var taskList: some View {
        RunningTaskListLayout(maxHeight: maxListHeight) {
            rows.hidden().accessibilityHidden(true)
            ScrollView {
                rows.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roots, id: \.shelfIdentity) { root in
                let isSelected = selected == root.shelfIdentity
                Button { selected = isSelected ? nil : root.shelfIdentity } label: {
                    HStack(spacing: DS.Spacing.space2) {
                        Text(root.title)
                            .foregroundStyle(DS.Colors.textPrimary)
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let detail, let current = runningMembers(of: root, detail: detail).first {
                            Text(current.createdAt, style: .timer)
                                .monospacedDigit()
                                .foregroundStyle(DS.Colors.textTertiary)
                                .fixedSize()
                        }
                        Image(systemName: isSelected ? "chevron.down" : "chevron.right")
                            .foregroundStyle(DS.Colors.textTertiary)
                    }
                    .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RunningFooterButtonStyle(selected: isSelected))
                .help(root.title)
                .accessibilityLabel(L10n.t("hud.asyncTasks.detailsNamed", root.title))
                if isSelected {
                    taskDetails(root)
                }
            }
        }
    }

    private func taskDetails(_ root: PickyAsyncTask) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            // Provider titles can be commands, not friendly summaries. Reveal the original
            // text on selection rather than inventing a shortened description or progress.
            Text(root.title).foregroundStyle(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let detail {
                ForEach(runningMembers(of: root, detail: detail), id: \.shelfIdentity) { task in
                    if task.taskId != root.taskId {
                        Text(task.title).foregroundStyle(DS.Colors.textPrimary)
                        if let run = subagentRun(for: task, root: root) {
                            Text(run.displayTask ?? run.task)
                                .foregroundStyle(DS.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    if let progress = task.progress, !progress.isEmpty {
                        Text(progress).foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.bottom, DS.Spacing.space2)
    }

    private func subagentRun(for task: PickyAsyncTask, root: PickyAsyncTask) -> PickySubagentRun? {
        guard let invocationID = root.invocationId,
              case .number(let runID)? = task.details?["runId"],
              case .loaded(let runs) = store.subagentStore.runsState else { return nil }
        return runs.first { Double($0.runId) == runID && $0.invocationId == invocationID }
    }
}

/// Same intrinsic-document measurement as the production async shelf. Short lists
/// must not reserve the maximum scroll height; long details remain scrollable.
private struct RunningTaskListLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let height = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(height, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

private struct RunningFooterButtonStyle: ButtonStyle {
    var selected = false
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration, selected: selected)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        let selected: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? DS.Colors.surface3 :
                    selected || hovered ? DS.Colors.surface2 : .clear,
                    in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
                .onHover { hovered = $0 }
        }
    }
}
