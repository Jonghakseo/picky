import SwiftUI

/// Presentation only. W6b supplies the narrow detail-store snapshot and real command capabilities.
struct PickyAsyncTaskShelfView: View {
    let summary: PickyAsyncWorkSummary
    let detailState: PickyProjectionSectionState<PickyAsyncTaskDetail>
    var metadata: PickySessionMetadata?
    var controlState: PickyProjectionSectionState<PickyAsyncControlState> = .unavailable
    var stopError: String?
    let cancelAvailability: (PickyAsyncTask) -> PickyAsyncTaskCancelAvailability
    let onAction: (PickyAsyncTaskShelfAction) -> Void
    var maxListHeight: CGFloat = 200
    var initiallyExpandedRows = false
    var fetchedDetail: (PickyAsyncTask) -> PickyAsyncTaskDetail? = { _ in nil }
    var detailPending: (PickyAsyncTask) -> Bool = { _ in false }
    var detailError: (PickyAsyncTask) -> String? = { _ in nil }
    @State private var isExpanded: Bool
    @State private var rowExpansion: [PickyAsyncTaskShelfIdentity: Bool] = [:]
    @State private var providerExpansion: [PickyAsyncTaskShelfIdentity: Bool] = [:]

    init(summary: PickyAsyncWorkSummary, detailState: PickyProjectionSectionState<PickyAsyncTaskDetail>,
         metadata: PickySessionMetadata? = nil,
         controlState: PickyProjectionSectionState<PickyAsyncControlState> = .unavailable,
         stopError: String? = nil, initiallyExpanded: Bool = false, maxListHeight: CGFloat = 200,
         initiallyExpandedRows: Bool = false,
         fetchedDetail: @escaping (PickyAsyncTask) -> PickyAsyncTaskDetail? = { _ in nil },
         detailPending: @escaping (PickyAsyncTask) -> Bool = { _ in false },
         detailError: @escaping (PickyAsyncTask) -> String? = { _ in nil },
         cancelAvailability: @escaping (PickyAsyncTask) -> PickyAsyncTaskCancelAvailability,
         onAction: @escaping (PickyAsyncTaskShelfAction) -> Void) {
        self.summary = summary
        self.detailState = detailState
        self.metadata = metadata
        self.controlState = controlState
        self.stopError = stopError
        self.cancelAvailability = cancelAvailability
        self.onAction = onAction
        self.maxListHeight = maxListHeight
        self.initiallyExpandedRows = initiallyExpandedRows
        self.fetchedDetail = fetchedDetail
        self.detailPending = detailPending
        self.detailError = detailError
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    private var unresolvedControl: Bool {
        PickyAsyncTaskShelfPresentation.hasUnresolvedControl(summary: summary, detail: detailState, control: controlState)
    }

    private var emptyAttention: Bool {
        PickyAsyncTaskShelfPresentation.isEmptyAttention(summary: summary, detail: detailState)
    }

    var body: some View {
        if PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: detailState) {
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                HStack(spacing: DS.Spacing.space1) {
                    Text("hud.asyncTasks.title")
                        .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize, weight: .semibold)
                    if summary.activeRootCount > 1 {
                        Text("\(summary.activeRootCount)")
                            .foregroundStyle(DS.Colors.textSecondary)
                    }
                    Spacer(minLength: 0)
                    if summary.attentionCount > 0 && !emptyAttention {
                        Text(L10n.t("hud.asyncTasks.attentionCount", summary.attentionCount))
                            .foregroundStyle(DS.Colors.destructiveText)
                    }
                }
                if summary.tracking == .unsupported {
                    Label(L10n.t("hud.asyncTasks.unsupported"), systemImage: "exclamationmark.circle")
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
            .padding(DS.Spacing.space3)
            .background(DS.Colors.surface2, in: RoundedRectangle(cornerRadius: DS.CornerRadius.control))
        }
    }

    @ViewBuilder
    private func taskList(_ detail: PickyAsyncTaskDetail) -> some View {
        let roots = PickyAsyncTaskShelfPresentation.roots(in: detail)
        if emptyAttention {
            Label(L10n.t(unresolvedControl || stopError != nil
                ? "hud.asyncTasks.controlUnresolved" : "hud.asyncTasks.attentionUnknown"),
                systemImage: "exclamationmark.triangle")
                .foregroundStyle(DS.Colors.destructiveText)
            if let reason = stopError ?? PickyAsyncTaskShelfPresentation.unresolvedControlReason(
                summary: summary, detail: detailState, control: controlState), !reason.isEmpty {
                Text(reason)
                    .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
                    .foregroundStyle(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }
        }
        if roots.isEmpty {
            if !emptyAttention && summary.tracking == .ready {
                Text("hud.asyncTasks.noDetails")
                    .foregroundStyle(DS.Colors.textSecondary)
            }
        } else {
            let visible = isExpanded ? roots : Array(roots.prefix(3))
            BoundedTaskListLayout(maxHeight: maxListHeight) {
                // Measure the document with the proposed width, not the scroll viewport's ideal size.
                rows(visible, detail: detail).hidden().accessibilityHidden(true)
                ScrollView {
                    rows(visible, detail: detail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
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
        VStack(alignment: .leading, spacing: 0) {
            ForEach(roots, id: \.shelfIdentity) { root in
                if root.shelfIdentity != roots.first?.shelfIdentity { Divider().overlay(DS.Colors.borderSubtle) }
                PickyAsyncTaskShelfRowView(root: root, detail: detail, supplementalDetail: fetchedDetail(root),
                    summary: summary, runtimeInstanceId: metadata?.agentCycle?.runtimeInstanceId,
                    availability: cancelAvailability(root), onAction: onAction,
                    isExpanded: initiallyExpandedRows,
                    expandedBinding: Binding(get: { rowExpansion[root.shelfIdentity] ?? initiallyExpandedRows },
                                             set: { rowExpansion[root.shelfIdentity] = $0 }),
                    providerBinding: Binding(get: { providerExpansion[root.shelfIdentity] ?? false },
                                             set: { providerExpansion[root.shelfIdentity] = $0 }),
                    isDetailPending: detailPending(root), detailError: detailError(root))
            }
        }
    }
}

/// A scroll view reports its viewport ideal size, which is not its document height.
/// Measure an unplaced copy of the production rows synchronously so even a fresh render host
/// receives the right intrinsic height. Only the persistent scroll surface is placed.
private struct BoundedTaskListLayout: Layout {
    let maxHeight: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width
        let documentHeight = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil)).height
        return CGSize(width: width, height: min(documentHeight, maxHeight))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[1].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}

/// Observes only this session's metadata and async detail, not the transcript or dock.
struct PickyMountedAsyncTaskShelfView: View {
    let store: PickySessionStore
    let commands: any PickySessionCommands
    let maxListHeight: CGFloat
    var compact = false
    var bottomSpacing: CGFloat = 0
    var stopError: String?
    @State private var showsCompactWork = false
    @State private var pending = Set<PickyAsyncTaskShelfIdentity>()
    @State private var errors: [PickyAsyncTaskShelfIdentity: String] = [:]
    @State private var detailPending = Set<PickyAsyncTaskShelfIdentity>()
    @State private var detailErrors: [PickyAsyncTaskShelfIdentity: String] = [:]
    @State private var fetchedDetails: [PickyAsyncTaskShelfIdentity: PickyAsyncTaskDetail] = [:]

    var body: some View {
        if case .loaded(let metadata) = store.metaStore.metadataState,
           let summary = metadata.asyncWorkSummary,
           PickyAsyncTaskShelfPresentation.isVisible(summary: summary, detail: store.asyncTaskStore.detailState) {
            if compact {
                Button { showsCompactWork.toggle() } label: {
                    Label(L10n.t("hud.asyncTasks.title"), systemImage: "list.bullet.rectangle")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .overlay(alignment: .trailing) {
                            Text(summary.activeRootCount > 0 ? "\(summary.activeRootCount)" : "!")
                                .foregroundStyle(summary.attentionCount > 0 ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                        }
                        .frame(minHeight: 28)
                }
                .buttonStyle(.borderless)
                .help(L10n.t("hud.asyncTasks.showWork"))
                .accessibilityLabel(L10n.t("hud.asyncTasks.showWork"))
                .accessibilityValue(L10n.t("hud.asyncTasks.counts", summary.activeRootCount,
                    summary.pendingCompletionCount, summary.uncertainExecutionCount, summary.attentionCount))
                .padding(.bottom, bottomSpacing)
                .popover(isPresented: $showsCompactWork) {
                    shelf(summary: summary, metadata: metadata, maxListHeight: 200)
                        .frame(width: 380)
                        .padding(DS.Spacing.space2)
                }
            } else {
                shelf(summary: summary, metadata: metadata, maxListHeight: maxListHeight)
                    .padding(.bottom, bottomSpacing)
            }
        }
    }

    private func shelf(summary: PickyAsyncWorkSummary, metadata: PickySessionMetadata,
                       maxListHeight: CGFloat) -> some View {
            PickyAsyncTaskShelfView(summary: summary, detailState: store.asyncTaskStore.detailState,
                metadata: metadata, controlState: store.asyncTaskStore.controlState, stopError: stopError,
                maxListHeight: maxListHeight,
                fetchedDetail: { fetchedDetails[$0.shelfIdentity] },
                detailPending: { detailPending.contains($0.shelfIdentity) },
                detailError: { detailErrors[$0.shelfIdentity] },
                cancelAvailability: { task in
                    let id = task.shelfIdentity
                    if pending.contains(id) { return .pending }
                    if let error = errors[id] { return .failed(error) }
                    return summary.tracking == .ready ? .available : .unsupported
                }, onAction: { action in
                    switch action {
                    case .cancel(let owner, let taskID):
                        let id = PickyAsyncTaskShelfIdentity(owner: owner, taskID: taskID)
                        guard pending.insert(id).inserted else { return }
                        errors[id] = nil
                        Task { @MainActor in
                            defer { pending.remove(id) }
                            do {
                                try await commands.cancelAsyncTask(owner: owner, taskID: taskID)
                            } catch { errors[id] = error.localizedDescription }
                        }
                    case .detail(let owner, let taskID):
                        let id = PickyAsyncTaskShelfIdentity(owner: owner, taskID: taskID)
                        guard detailPending.insert(id).inserted else { return }
                        detailErrors[id] = nil
                        Task { @MainActor in
                            defer { detailPending.remove(id) }
                            do {
                                fetchedDetails[id] = try await commands.loadAsyncTaskDetail(owner: owner, taskID: taskID)
                            } catch { detailErrors[id] = error.localizedDescription }
                        }
                    }
                })
    }
}

extension PickyAsyncTask {
    var shelfIdentity: PickyAsyncTaskShelfIdentity { PickyAsyncTaskShelfIdentity(self) }
}

struct PickyAsyncTaskShelfRowView: View {
    let root: PickyAsyncTask
    let detail: PickyAsyncTaskDetail
    var supplementalDetail: PickyAsyncTaskDetail?
    let summary: PickyAsyncWorkSummary
    var runtimeInstanceId: String? = nil
    let availability: PickyAsyncTaskCancelAvailability
    let onAction: (PickyAsyncTaskShelfAction) -> Void
    @State var isExpanded = false
    var expandedBinding: Binding<Bool>?
    var providerBinding: Binding<Bool>?
    @State private var showsProviderDetails = false
    var isDetailPending = false
    var detailError: String?

    private var members: [PickyAsyncTask] { PickyAsyncTaskShelfPresentation.members(of: root, in: detail) }
    private var tickets: [PickyCompletionTicket] { PickyAsyncTaskShelfPresentation.tickets(for: root, in: detail) }
    private var canCancel: Bool {
        PickyAsyncTaskShelfPresentation.canCancel(root, in: detail, summary: summary, availability: availability)
    }
    private var primaryTask: PickyAsyncTask {
        guard root.execution == .succeeded, PickyAsyncTaskShelfPresentation.resultKey(tickets) == nil else { return root }
        return members.first(where: { $0.taskId != root.taskId && $0.presence == .active }) ?? root
    }
    private var kindSymbol: String {
        switch root.kind {
        case "bash": "terminal"
        case "subagent", "subagent_group", "subagent-group": "person.2"
        default: "gearshape.2"
        }
    }

    var body: some View {
        let disclosure = expandedBinding ?? $isExpanded
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            HStack(spacing: DS.Spacing.space2) {
                Image(systemName: kindSymbol)
                    .accessibilityHidden(true)
                Text(root.title)
                    .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize, weight: .semibold)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(disclosure.wrappedValue ? nil : 1)
                    .help(root.title)
                    .accessibilityLabel(root.title)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: DS.Spacing.space1) {
                    statusLabel(primaryTask,
                        key: PickyAsyncTaskShelfPresentation.primaryStateKey(primaryTask, tickets: tickets,
                            summary: summary, runtimeInstanceId: runtimeInstanceId))
                        .lineLimit(1)
                    if primaryTask.presence == .active {
                        Text(primaryTask.createdAt, style: .timer)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .pickyFont(size: PickyHUDTypography.metaNSFont(fontScale: 1).pointSize)
                            .lineLimit(1)
                    } else if root.presence == .settled {
                        Text(root.updatedAt, style: .relative)
                            .foregroundStyle(DS.Colors.textTertiary)
                            .pickyFont(size: PickyHUDTypography.metaNSFont(fontScale: 1).pointSize)
                            .lineLimit(1)
                    }
                }
                .fixedSize()
                Button {
                    guard canCancel else { return }
                    onAction(.cancel(owner: root.owner, taskID: root.taskId))
                } label: {
                    Text("hud.asyncTasks.stop")
                        .foregroundStyle(canCancel ? DS.Colors.accentText : DS.Colors.textTertiary)
                        .frame(minWidth: 28, minHeight: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .disabled(!canCancel)
                .accessibilityLabel(L10n.t("hud.asyncTasks.stopNamed", root.title))
                .help(availability.explanation ?? L10n.t("hud.asyncTasks.stopHelp"))
                Button {
                    if !disclosure.wrappedValue {
                        onAction(.detail(owner: root.owner, taskID: root.taskId))
                    }
                    disclosure.wrappedValue.toggle()
                } label: {
                    Image(systemName: disclosure.wrappedValue ? "chevron.up" : "chevron.down")
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .tint(DS.Colors.accentText)
                .accessibilityLabel(L10n.t("hud.asyncTasks.detailsNamed", root.title))
                .accessibilityValue(L10n.t(disclosure.wrappedValue
                    ? "hud.asyncTasks.showLess" : "hud.asyncTasks.details"))
                .help(L10n.t("hud.asyncTasks.detailsNamed", root.title))
            }
            switch availability {
            case .failed(let reason):
                failureLine("hud.asyncTasks.stopFailedShort", reason: reason)
            case .unavailable(let reason):
                failureLine("hud.asyncTasks.stopUnavailableShort", reason: reason)
            case .pending:
                Label(L10n.t("hud.asyncTasks.cancelPending"), systemImage: "info.circle")
                    .foregroundStyle(DS.Colors.warningText)
                    .lineLimit(1)
                    .help(L10n.t("hud.asyncTasks.cancelPending"))
            case .available, .unsupported:
                EmptyView()
            }
            if let failedTicket = tickets.first(where: { $0.state == .failed || $0.state == .unknown }) {
                failureLine("hud.asyncTasks.deliveryFailedShort", reason: failedTicket.failureReason)
            }
            if disclosure.wrappedValue {
                expandedDetails
                    .padding(.leading, DS.Spacing.space3)
            }
        }
        .pickyFont(size: PickyHUDTypography.labelSemiboldNSFont(fontScale: 1).pointSize)
        .foregroundStyle(DS.Colors.textSecondary)
        .padding(.vertical, DS.Spacing.space1)
    }

    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            if let progress = root.progress, !progress.isEmpty {
                Text(progress)
                    .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
                    .lineLimit(2).help(progress).textSelection(.enabled)
            }
            ForEach(members.filter { $0.taskId != root.taskId }, id: \.shelfIdentity) { child in
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space1) {
                    Text(child.title)
                        .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
                        .foregroundStyle(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .help(child.title)
                    Spacer(minLength: DS.Spacing.space1)
                    statusLabel(child, key: PickyAsyncTaskShelfPresentation.executionKey(child,
                        summary: summary, runtimeInstanceId: runtimeInstanceId))
                        .fixedSize()
                }
                if let progress = child.progress, !progress.isEmpty {
                    Text(progress)
                        .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
                        .lineLimit(2).help(progress).textSelection(.enabled)
                }
            }
            if case .failed(let reason) = availability {
                fullReason(reason)
            } else if case .unavailable(let reason) = availability {
                fullReason(reason)
            }
            ForEach(Array(tickets.enumerated()), id: \.offset) { _, ticket in
                if ticket.state == .failed || ticket.state == .unknown, let reason = ticket.failureReason {
                    fullReason(reason)
                }
            }
            if root.presence == .settled, root.execution == .succeeded,
               PickyAsyncTaskShelfPresentation.resultKey(tickets) != nil {
                statusLabel(root, key: PickyAsyncTaskShelfPresentation.executionKey(root,
                    summary: summary, runtimeInstanceId: runtimeInstanceId))
            }
            if isDetailPending { ProgressView().controlSize(.small) }
            if let detailError {
                failureLine("hud.asyncTasks.detailFailedShort", reason: detailError)
                fullReason(detailError)
                Button {
                    onAction(.detail(owner: root.owner, taskID: root.taskId))
                } label: {
                    Text("hud.asyncTasks.retryDetails")
                        .foregroundStyle(DS.Colors.accentText)
                        .frame(minHeight: 24)
                }
                .buttonStyle(.borderless)
            }
            let lines = PickyAsyncTaskShelfPresentation.supplementalLines(for: root, in: supplementalDetail)
            if !lines.isEmpty {
                DisclosureGroup(isExpanded: providerBinding ?? $showsProviderDetails) {
                    ForEach(lines, id: \.self) { line in
                        Text(line).pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
                            .textSelection(.enabled)
                    }
                } label: {
                    Text("hud.asyncTasks.details")
                }
                .tint(DS.Colors.accentText)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func failureLine(_ key: String, reason: String?) -> some View {
        Label(L10n.t(key), systemImage: "exclamationmark.triangle")
            .foregroundStyle(DS.Colors.destructiveText)
            .lineLimit(1)
            .help(reason ?? L10n.t(key))
            .accessibilityLabel(reason.map { "\(L10n.t(key)) \($0)" } ?? L10n.t(key))
    }

    private func fullReason(_ reason: String) -> some View {
        Text(reason)
            .pickyFont(size: PickyHUDTypography.bodyCompactNSFont(fontScale: 1).pointSize)
            .foregroundStyle(DS.Colors.destructiveText)
            .textSelection(.enabled)
    }

    private func statusLabel(_ task: PickyAsyncTask, key: String) -> some View {
        let unknown = key == "hud.asyncTasks.execution.unknown"
        let failed = key.hasSuffix("failed") ||
            task.execution == .interrupted && key == "hud.asyncTasks.execution.interrupted"
        let symbol = unknown ? "questionmark.circle" : failed ? "exclamationmark.triangle" :
            task.execution == .cancelled ? "stop.circle" : key.contains("result") ? "tray" :
            task.presence == .active || task.execution == .queued ? "clock" : "checkmark.circle"
        let color = unknown ? DS.Colors.warningText : failed ? DS.Colors.destructiveText :
            key.contains("result") ? DS.Colors.warningText : task.presence == .active ? DS.Colors.info : DS.Colors.textSecondary
        return Label(L10n.t("\(key).short"), systemImage: symbol)
            .font(PickyHUDTypography.status)
            .foregroundStyle(color)
            .accessibilityLabel(L10n.t(key))
    }
}
