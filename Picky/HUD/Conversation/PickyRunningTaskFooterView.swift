import SwiftUI

/// Running-only conversation footer. Lifecycle bookkeeping and completion tickets
/// remain in the section stores, not in this surface.
struct PickyRunningTaskFooterView: View {
    let store: PickySessionStore
    let maxListHeight: CGFloat
    var compact = false
    var bottomSpacing: CGFloat = 0
    @State private var expanded: Bool

    init(store: PickySessionStore, maxListHeight: CGFloat, compact: Bool = false,
         bottomSpacing: CGFloat = 0, initiallyExpanded: Bool = false) {
        self.store = store
        self.maxListHeight = maxListHeight
        self.compact = compact
        self.bottomSpacing = bottomSpacing
        _expanded = State(initialValue: initiallyExpanded)
    }

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
                HStack(spacing: DS.Spacing.space2) {
                    Text(displayTitle(for: root))
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let detail, let current = runningMembers(of: root, detail: detail).first {
                        Text(current.createdAt, style: .timer)
                            .monospacedDigit()
                            .foregroundStyle(DS.Colors.textTertiary)
                            .fixedSize()
                    }
                }
                .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
                .padding(.horizontal, DS.Spacing.space2)
                .frame(minHeight: 28)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func displayTitle(for root: PickyAsyncTask) -> String {
        guard ["subagent", "subagent_group", "subagent-group"].contains(root.kind), let detail else {
            // bash_async preserves its optional title; without one the provider supplies
            // a command token. Do not claim that either value is a guaranteed objective.
            return root.title
        }
        let children = runningMembers(of: root, detail: detail).filter { $0.taskId != root.taskId }
        let agents = children.compactMap { child -> String? in
            guard let name = subagentRun(for: child, root: root)?.agent.trimmingCharacters(in: .whitespacesAndNewlines),
                  !name.isEmpty else { return nil }
            return name
        }
        // Do not silently omit an active child whose run metadata has not arrived.
        guard !agents.isEmpty, agents.count == children.count else {
            return children.isEmpty ? L10n.t("hud.asyncTasks.subagentWork") :
                L10n.t("hud.asyncTasks.subagentCount", children.count)
        }
        var order: [String] = []
        var counts: [String: Int] = [:]
        for agent in agents {
            if counts[agent] == nil { order.append(agent) }
            counts[agent, default: 0] += 1
        }
        let types = order.map { agent in
            let count = counts[agent, default: 0]
            return count > 1 ? "\(agent) × \(count)" : agent
        }.joined(separator: " · ")
        return L10n.t("hud.asyncTasks.subagentTypesRunning", types)
    }

    private func subagentRun(for task: PickyAsyncTask, root: PickyAsyncTask) -> PickySubagentRun? {
        guard let invocationID = root.invocationId,
              case .number(let runID)? = task.details?["runId"],
              case .loaded(let runs) = store.subagentStore.runsState else { return nil }
        return runs.first { Double($0.runId) == runID && $0.invocationId == invocationID }
    }
}

/// Same intrinsic-document measurement as the production async shelf. Short lists
/// must not reserve the maximum scroll height; larger lists remain scrollable.
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
    func makeBody(configuration: Configuration) -> some View {
        Content(configuration: configuration)
    }

    private struct Content: View {
        let configuration: ButtonStyleConfiguration
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(configuration.isPressed ? DS.Colors.surface3 :
                    hovered ? DS.Colors.surface2 : .clear,
                    in: RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
                .onHover { hovered = $0 }
        }
    }
}
