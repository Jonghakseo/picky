import SwiftUI

/// Drop-in proposal for the conversation footer. Observes the production section stores;
/// lifecycle bookkeeping and completion tickets remain in the stores, not in this surface.
struct PickyRunningTaskFooterView: View {
    let store: PickySessionStore
    let commands: any PickySessionCommands
    let maxListHeight: CGFloat
    var compact = false
    var bottomSpacing: CGFloat = 0
    @State private var expanded = false
    @State private var selected: PickyAsyncTaskShelfIdentity?
    @State private var pending = Set<PickyAsyncTaskShelfIdentity>()
    @State private var actionError: String?

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
            // User-requested cancellation errors belong to the action dialog, not a status shelf.
            .alert(L10n.t("hud.asyncTasks.stopError.title"), isPresented: Binding(
                get: { actionError != nil }, set: { if !$0 { actionError = nil } }
            )) {
                Button("shellCommand.ok", role: .cancel) { actionError = nil }
            } message: {
                Text(actionError ?? "")
            }
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
            if let detail {
                ForEach(runningMembers(of: root, detail: detail), id: \.shelfIdentity) { task in
                    if task.taskId != root.taskId {
                        Text(task.title).foregroundStyle(DS.Colors.textPrimary)
                    }
                    if let progress = task.progress, !progress.isEmpty {
                        Text(progress).foregroundStyle(DS.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            HStack {
                Spacer()
                Button {
                    let identity = root.shelfIdentity
                    guard pending.insert(identity).inserted else { return }
                    Task { @MainActor in
                        defer { pending.remove(identity) }
                        do { try await commands.cancelAsyncTask(owner: root.owner, taskID: root.taskId) }
                        catch { actionError = error.localizedDescription }
                    }
                } label: {
                    Text("hud.asyncTasks.stop").frame(minHeight: 24)
                }
                .buttonStyle(.borderless)
                .tint(DS.Colors.accentText)
                .disabled(!canCancel(root))
                .help(L10n.t("hud.asyncTasks.stopHelp"))
                .accessibilityLabel(L10n.t("hud.asyncTasks.stopNamed", root.title))
            }
        }
        .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.bottom, DS.Spacing.space2)
    }

    private func canCancel(_ root: PickyAsyncTask) -> Bool {
        guard let detail, let summary else { return false }
        return PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary,
            availability: pending.contains(root.shelfIdentity) ? .pending : .available)
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
