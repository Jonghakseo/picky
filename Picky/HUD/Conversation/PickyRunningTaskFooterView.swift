import SwiftUI

/// Conversation footer for unfinished background work. It reports the whole
/// current work group, including members that already finished, so a batch does
/// not appear to shrink while it runs. Lifecycle bookkeeping, completion tickets
/// and cancellation stay in the section stores and the shelf, not in this surface.
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

    private var model: PickyBackgroundWorkFooterModel? {
        guard case .loaded(let metadata) = store.metaStore.metadataState,
              let summary = metadata.asyncWorkSummary else { return nil }
        return PickyBackgroundWorkFooterPresentation.model(
            summary: summary,
            detail: store.asyncTaskStore.detailState,
            // Read, and therefore observe, the run list only for a current subagent group.
            runs: {
                guard case .loaded(let value) = store.subagentStore.runsState else { return [] }
                return value
            },
            runtimeInstanceId: metadata.agentCycle?.runtimeInstanceId)
    }

    var body: some View {
        if let model {
            VStack(alignment: .leading, spacing: 0) {
                Button { expanded.toggle() } label: {
                    HStack(spacing: DS.Spacing.space2) {
                        Image(systemName: model.status.state.symbol)
                            .foregroundStyle(model.status.state.color)
                            .accessibilityHidden(true)
                        Text("hud.backgroundWork.title")
                        Text(verbatim: "· \(model.status.text)")
                            .lineLimit(1)
                        Spacer(minLength: DS.Spacing.space2)
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(DS.Colors.textTertiary)
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(minHeight: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RunningFooterButtonStyle())
                .accessibilityLabel(L10n.t("hud.backgroundWork.accessibility", model.status.text))
                .accessibilityValue(L10n.t(expanded ? "hud.asyncTasks.showLess" : "hud.asyncTasks.showWork"))
                .help(L10n.t(expanded ? "hud.asyncTasks.showLess" : "hud.asyncTasks.showWork"))
                .pickyInstantPopover(isPresented: Binding(
                    get: { compact && expanded }, set: { expanded = $0 }
                )) {
                    taskList(model).frame(width: 380).padding(DS.Spacing.space2)
                }
                if expanded && !compact {
                    taskList(model)
                }
            }
            .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
            .padding(.bottom, bottomSpacing)
        }
    }

    private func taskList(_ model: PickyBackgroundWorkFooterModel) -> some View {
        RunningTaskListLayout(maxHeight: maxListHeight) {
            rows(model).hidden().accessibilityHidden(true)
            ScrollView {
                rows(model).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        // The compact popover bridges the font scale, not an inherited `.font`.
        .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
    }

    private func rows(_ model: PickyBackgroundWorkFooterModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.groups) { group in
                if group.isGroup {
                    groupHeader(group)
                    ForEach(group.children) { child in workRow(child, indented: true) }
                } else {
                    workRow(PickyBackgroundWorkRow(id: group.id, title: group.title,
                        state: group.state, timing: group.timing), indented: false)
                }
                if let result = group.result {
                    resultRow(result, indented: group.isGroup)
                }
            }
            if let note = model.note {
                // Missing detail during reload is ordinary; only unexplained attention warns.
                Label(L10n.t(note.key), systemImage: note == .attention ? "exclamationmark.triangle" : "info.circle")
                    .foregroundStyle(note == .attention ? DS.Colors.warningText : DS.Colors.textSecondary)
                    .lineLimit(2)
                    .padding(.horizontal, DS.Spacing.space2)
                    .frame(minHeight: 28)
                    .accessibilityElement(children: .combine)
            }
        }
    }

    private func groupHeader(_ group: PickyBackgroundWorkGroup) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
            Text(group.title)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .help(group.title)
            Text(countsText(group))
                .foregroundStyle(DS.Colors.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            // The invocation's own failure is not hidden by agents that finished.
            if let issue = group.rootIssue {
                Image(systemName: issue.symbol)
                    .foregroundStyle(issue.color)
                    .accessibilityHidden(true)
                Text(L10n.t(issue.labelKey))
                    .foregroundStyle(issue.color)
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space2)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    private func countsText(_ group: PickyBackgroundWorkGroup) -> String {
        group.counts
            .map { L10n.t("hud.backgroundWork.stateCount", L10n.t($0.state.labelKey), $0.count) }
            .joined(separator: " · ")
    }

    private func workRow(_ row: PickyBackgroundWorkRow, indented: Bool) -> some View {
        HStack(spacing: DS.Spacing.space2) {
            Text(row.title)
                .foregroundStyle(DS.Colors.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(row.title)
            // State is named, not only colored.
            Image(systemName: row.state.symbol)
                .foregroundStyle(row.state.color)
                .accessibilityHidden(true)
            Text(L10n.t(row.state.labelKey))
                .foregroundStyle(row.state.color)
                .fixedSize()
            timeLabel(row.timing)
        }
        .padding(.leading, indented ? DS.Spacing.space6 : DS.Spacing.space2)
        .padding(.trailing, DS.Spacing.space2)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func timeLabel(_ timing: PickyBackgroundWorkTiming) -> some View {
        switch timing {
        case .none:
            EmptyView()
        case .elapsed(let since):
            // Only a genuinely active execution keeps counting.
            Text(since, style: .timer)
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize()
                .frame(minWidth: 42, alignment: .trailing)
        case .fixed(let interval):
            Text(PickyBackgroundWorkFooterPresentation.durationText(interval))
                .monospacedDigit()
                .foregroundStyle(DS.Colors.textTertiary)
                .fixedSize()
                .frame(minWidth: 42, alignment: .trailing)
        }
    }

    private func resultRow(_ result: PickyBackgroundWorkResult, indented: Bool) -> some View {
        let color = result == .failed ? DS.Colors.destructiveText
            : result == .unverified ? DS.Colors.warningText : DS.Colors.textSecondary
        return HStack(spacing: DS.Spacing.space2) {
            Image(systemName: result.needsAttention ? "exclamationmark.triangle" : "tray")
                .foregroundStyle(color)
                .accessibilityHidden(true)
            Text(L10n.t(result.labelKey))
                .foregroundStyle(color)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, indented ? DS.Spacing.space6 : DS.Spacing.space2)
        .padding(.trailing, DS.Spacing.space2)
        .frame(minHeight: 28)
        .accessibilityElement(children: .combine)
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
