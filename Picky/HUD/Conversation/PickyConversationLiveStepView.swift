//
//  PickyConversationLiveStepView.swift
//  Picky
//
//  Focus Stack's narrow, read-only current-work projection.
//

import SwiftUI

enum PickyConversationFocusStackWidthTier: Equatable {
    case compact
    case standard
    case expanded

    init(cardWidth: CGFloat) {
        switch cardWidth {
        case ..<400: self = .compact
        case 520...: self = .expanded
        default: self = .standard
        }
    }
}

enum PickyConversationFocusStackHeightTier: Equatable {
    case constrained
    case regular

    init(availableHeight: CGFloat) {
        self = availableHeight <= 360 ? .constrained : .regular
    }
}

enum PickyFocusStackTodoDrawerLayoutPolicy {
    static var taskRowMinimumHeight: CGFloat {
        PickyHUDTypography.Size.supporting + (DS.Spacing.sm * 2)
    }

    static var viewportHeight: CGFloat { taskRowMinimumHeight * 3.5 }

    static func usesScrollableViewport(taskCount: Int) -> Bool { taskCount > 3 }
}

/// Card-owned Plan input. It intentionally observes only metadata and Todo
/// state, so Journal/tool/activity updates cannot invalidate the drawer.
@MainActor
struct PickyConversationPlanProjection: Equatable {
    let sessionID: String
    let status: PickySessionStatus
    let todoPresentation: PickyTodoProgressPresentation?

    init(metaStore: PickySessionMetaStore, todoStore: PickySessionTodoStore) {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            preconditionFailure("Focus Stack Plan requires loaded metadata")
        }
        sessionID = metadata.id
        status = metadata.status
        let todoState: PickyTodoState?
        if case .loaded(let value) = todoStore.todoState {
            todoState = value
        } else {
            todoState = nil
        }
        todoPresentation = PickyTodoProgressPresentation(state: todoState)
    }
}

enum PickyConversationPlanDrawerPolicy {
    static func canOpen(status: PickySessionStatus, todo: PickyTodoProgressPresentation?) -> Bool {
        status == .running && todo?.isComplete == false
    }

    static func shouldCollapse(status: PickySessionStatus, todo: PickyTodoProgressPresentation?) -> Bool {
        !canOpen(status: status, todo: todo)
    }

    static func shouldCollapse(_ plan: PickyConversationPlanProjection) -> Bool {
        shouldCollapse(status: plan.status, todo: plan.todoPresentation)
    }

    static func shouldRenderDrawer(status: PickySessionStatus, todo: PickyTodoProgressPresentation?, isExpanded: Bool) -> Bool {
        canOpen(status: status, todo: todo) && isExpanded
    }

    static func shouldRenderDrawer(plan: PickyConversationPlanProjection, isExpanded: Bool) -> Bool {
        shouldRenderDrawer(status: plan.status, todo: plan.todoPresentation, isExpanded: isExpanded)
    }
}

/// The checklist/count cluster is a disclosure control whenever the Plan drawer
/// can open. Keeping this projection pure makes that interaction contract
/// testable without a WindowServer-backed SwiftUI click test.
struct PickyConversationPlanProgressDisclosurePresentation: Equatable {
    let stepText: String
    let chevronName: String

    init?(status: PickySessionStatus, todo: PickyTodoProgressPresentation?, isExpanded: Bool) {
        guard PickyConversationPlanDrawerPolicy.canOpen(status: status, todo: todo),
              let todo else { return nil }
        stepText = todo.countText
        chevronName = isExpanded ? "chevron.up" : "chevron.down"
    }
}

struct PickyConversationViewportState: Equatable {
    var isPinnedToBottom: Bool
    var hasUnreadContent: Bool

    static let pinned = Self(isPinnedToBottom: true, hasUnreadContent: false)
}

enum PickyConversationNavigationTarget: Equatable {
    case none
    case latest
    case question(requestID: String)
}

struct PickyConversationNavigationRequest: Equatable {
    var token = 0
    var target: PickyConversationNavigationTarget = .none

    mutating func request(_ target: PickyConversationNavigationTarget) {
        token &+= 1
        self.target = target
    }
}

enum PickyConversationLiveStepNavigationPolicy {
    static func showsExternalLatest(status: PickySessionStatus, viewport: PickyConversationViewportState) -> Bool {
        status == .running && !viewport.isPinnedToBottom
    }

    static func questionMessageID(messages: [PickySessionMessage], requestID: String) -> String? {
        messages.last(where: { $0.question?.id == requestID })?.id
    }

    static func isCurrent(requestToken: Int, activeToken: Int) -> Bool {
        requestToken == activeToken
    }
}

/// Presentation-only snapshot for the Focus Stack activity strip. Transcript
/// streaming cannot invalidate this projection.
@MainActor
struct PickyConversationLiveStepProjection: Equatable {
    let sessionID: String
    let status: PickySessionStatus
    let todoPresentation: PickyTodoProgressPresentation?
    let activeTool: PickyToolActivity?
    let activityStartedAt: Date?
    let activitySummary: PickyActivitySummary
    let pendingQuestionRequestID: String?

    init(
        metaStore: PickySessionMetaStore,
        todoStore: PickySessionTodoStore,
        toolStore: PickySessionToolStore,
        activityStore: PickySessionActivityStore,
        extensionUiStore: PickySessionExtensionUiStore
    ) {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            preconditionFailure("Focus Stack Live Step requires loaded metadata")
        }
        sessionID = metadata.id
        status = metadata.status
        let todoState: PickyTodoState?
        if case .loaded(let value) = todoStore.todoState {
            todoState = value
        } else {
            todoState = nil
        }
        todoPresentation = PickyTodoProgressPresentation(state: todoState)
        let tools: [PickyToolActivity]
        if case .loaded(let value) = toolStore.toolsState {
            tools = value
        } else {
            tools = []
        }
        activeTool = tools.last(where: \.isActive)
        activityStartedAt = activeTool?.startedAt ?? todoPresentation?.updatedAt
        if case .loaded(let value) = activityStore.activityState {
            activitySummary = value
        } else {
            activitySummary = .zero
        }
        let request: PickyExtensionUiRequest?
        if case .loaded(let value) = extensionUiStore.requestState {
            request = value
        } else {
            request = nil
        }
        pendingQuestionRequestID = request?.id
    }

    func elapsedText(at date: Date) -> String? {
        guard status == .running, let activityStartedAt else { return nil }
        return PickyTurnSummary(
            stepCount: 0,
            toolCount: 0,
            elapsedSeconds: max(0, Int(date.timeIntervalSince(activityStartedAt))),
            showsStepCount: false
        ).elapsedDisplayText
    }
}

@MainActor
enum PickyConversationLiveStepPresentation: Equatable {
    case running(stepText: String?, detail: String, toolName: String?)
    case waitingForInput(requestID: String)

    init?(projection: PickyConversationLiveStepProjection) {
        switch projection.status {
        case .running:
            let detail = projection.todoPresentation?.activeText
                ?? projection.activeTool.flatMap(PickyToolActivityPresentation.compactDetail)
                ?? Self.activityDetail(for: projection.activitySummary)
            self = .running(
                stepText: projection.todoPresentation?.countText,
                detail: detail,
                toolName: projection.activeTool?.name
            )
        case .waiting_for_input:
            guard let requestID = projection.pendingQuestionRequestID else { return nil }
            self = .waitingForInput(requestID: requestID)
        case .queued, .blocked, .completed, .failed, .cancelled:
            return nil
        }
    }

    private static func activityDetail(for summary: PickyActivitySummary) -> String {
        guard summary.totalToolCalls > 0 else {
            return L10n.t("hud.liveStep.working")
        }
        return L10n.t(
            summary.totalToolCalls == 1 ? "hud.conversation.turn.tool.one" : "hud.conversation.turn.tool.many",
            Int64(summary.totalToolCalls)
        )
    }

    var label: String {
        switch self {
        case .running: return L10n.t("hud.liveStep.currentActivity")
        case .waitingForInput: return L10n.t("hud.liveStep.inputNeeded")
        }
    }

    var iconName: String {
        switch self {
        case .running: return "checklist"
        case .waitingForInput: return "exclamationmark.bubble"
        }
    }

    var tone: PickyConversationStatusTone {
        switch self {
        case .running: return .info
        case .waitingForInput: return .warning
        }
    }

    func accessibilityValue(projection: PickyConversationLiveStepProjection, at date: Date) -> String {
        switch self {
        case let .running(stepText, detail, toolName):
            return [L10n.t("hud.conversation.status.running"), stepText, detail, toolName, projection.elapsedText(at: date)]
                .compactMap { $0 }
                .joined(separator: ", ")
        case .waitingForInput:
            return L10n.t("hud.liveStep.waitingForQuestion")
        }
    }
}

struct PickyConversationLiveStepView: View {
    let projection: PickyConversationLiveStepProjection
    let presentation: PickyConversationLiveStepPresentation
    let isTodoExpanded: Bool
    let todoOpenerFocusRequestID: Int
    let heightTier: PickyConversationFocusStackHeightTier
    let onToggleTodo: () -> Void
    let onOpenToolHistory: () -> Void
    let onGoToQuestion: (String) -> Void
    @Environment(\.pickyHUDDetailWidth) private var pickyHUDDetailWidth
    @FocusState private var isTodoOpenerFocused: Bool

    init(
        projection: PickyConversationLiveStepProjection,
        isTodoExpanded: Bool,
        todoOpenerFocusRequestID: Int,
        heightTier: PickyConversationFocusStackHeightTier,
        onToggleTodo: @escaping () -> Void,
        onOpenToolHistory: @escaping () -> Void,
        onGoToQuestion: @escaping (String) -> Void
    ) {
        self.projection = projection
        presentation = PickyConversationLiveStepPresentation(projection: projection)!
        self.isTodoExpanded = isTodoExpanded
        self.todoOpenerFocusRequestID = todoOpenerFocusRequestID
        self.heightTier = heightTier
        self.onToggleTodo = onToggleTodo
        self.onOpenToolHistory = onOpenToolHistory
        self.onGoToQuestion = onGoToQuestion
    }

    var body: some View {
        let widthTier = PickyConversationFocusStackWidthTier(cardWidth: pickyHUDDetailWidth)
        Group {
            switch presentation {
            case let .running(stepText, detail, toolName):
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    runningContent(widthTier: widthTier, stepText: stepText, detail: detail, toolName: toolName, date: context.date)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(presentation.label)
                        // The aggregate changes each second but must not become a
                        // VoiceOver live region.
                        .accessibilityValue(presentation.accessibilityValue(projection: projection, at: context.date))
                }
            case let .waitingForInput(requestID):
                waitingContent(requestID: requestID)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(presentation.label)
                    .accessibilityValue(presentation.accessibilityValue(projection: projection, at: .now))
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(DS.Colors.surface2))
    }

    @ViewBuilder
    private func runningContent(widthTier: PickyConversationFocusStackWidthTier, stepText: String?, detail: String, toolName: String?, date: Date) -> some View {
        if heightTier == .constrained {
            HStack(spacing: DS.Spacing.sm) {
                runningPrimaryLine(stepText: stepText, toolName: toolName, elapsedText: projection.elapsedText(at: date))
                runningDetailButton(detail)
            }
        } else if widthTier == .compact {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                runningPrimaryLine(stepText: stepText, toolName: toolName, elapsedText: projection.elapsedText(at: date))
                runningDetailButton(detail)
            }
        } else {
            HStack(spacing: DS.Spacing.sm) {
                runningPrimaryLine(stepText: stepText, toolName: toolName, elapsedText: projection.elapsedText(at: date))
                runningDetailButton(detail)
            }
        }
    }

    private func runningPrimaryLine(stepText: String?, toolName: String?, elapsedText: String?) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            planProgressControl(stepText: stepText)
            if let toolName {
                Button(action: onOpenToolHistory) {
                    Text(toolName).font(PickyHUDTypography.statusMedium).foregroundStyle(DS.Colors.accentText).lineLimit(1)
                }
                .buttonStyle(.plain)
                .help(L10n.t("hud.liveStep.toolHistory.help"))
                .accessibilityLabel(L10n.t("hud.liveStep.currentTool.accessibilityLabel", toolName))
                .accessibilityHint(L10n.t("hud.liveStep.toolHistory.help"))
                .hoverAffordance()
            }
            if let elapsedText {
                Text(elapsedText).font(PickyHUDTypography.statusMonospacedMedium).foregroundStyle(DS.Colors.textTertiary).accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func planProgressControl(stepText: String?) -> some View {
        if let disclosure = PickyConversationPlanProgressDisclosurePresentation(
            status: projection.status,
            todo: projection.todoPresentation,
            isExpanded: isTodoExpanded
        ) {
            Button(action: onToggleTodo) {
                HStack(spacing: DS.Spacing.xs) {
                    planIcon
                    Text(disclosure.stepText)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundStyle(presentation.tone.textColor)
                    Image(systemName: disclosure.chevronName)
                        .pickyFont(size: 9.5, weight: .semibold)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("picky.todo.progress.disclosure")
            .accessibilityLabel(L10n.t("hud.liveStep.currentPlan.accessibilityLabel", disclosure.stepText))
            .accessibilityValue(projection.todoPresentation?.stepText ?? "")
            .accessibilityHint(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
            .help(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
            .hoverAffordance()
        } else {
            HStack(spacing: DS.Spacing.xs) {
                planIcon
                if let stepText {
                    Text(stepText)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundStyle(presentation.tone.textColor)
                }
            }
        }
    }

    private var planIcon: some View {
        Image(systemName: presentation.iconName)
            .font(PickyHUDTypography.statusSemibold)
            .foregroundStyle(presentation.tone.textColor)
            .accessibilityHidden(true)
    }

    private func runningDetailButton(_ detail: String) -> some View {
        Group {
            if PickyConversationPlanDrawerPolicy.canOpen(
                status: projection.status,
                todo: projection.todoPresentation
            ) {
                Button(action: onToggleTodo) {
                    detailText(detail)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusable()
                .focused($isTodoOpenerFocused)
                .help(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
                .accessibilityLabel(L10n.t("hud.liveStep.currentPlan.accessibilityLabel", detail))
                .accessibilityValue(projection.todoPresentation?.stepText ?? "")
                .accessibilityHint(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
                .hoverAffordance()
                .onChange(of: todoOpenerFocusRequestID) { _, _ in isTodoOpenerFocused = true }
            } else {
                detailText(detail)
            }
        }
    }

    private func detailText(_ detail: String) -> some View {
        Text(detail)
            .font(PickyHUDTypography.statusMedium)
            .foregroundStyle(DS.Colors.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func waitingContent(requestID: String) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: presentation.iconName).font(PickyHUDTypography.statusSemibold).foregroundStyle(presentation.tone.textColor).accessibilityHidden(true)
            Text(presentation.label).font(PickyHUDTypography.statusSemibold).foregroundStyle(presentation.tone.textColor)
            Button(L10n.t("hud.liveStep.goToQuestion")) { onGoToQuestion(requestID) }
                .buttonStyle(.plain)
                .font(PickyHUDTypography.statusMedium)
                .foregroundStyle(DS.Colors.accentText)
                .help(L10n.t("hud.liveStep.goToQuestion.help"))
                .accessibilityHint(L10n.t("hud.liveStep.goToQuestion.accessibilityHint"))
                .hoverAffordance()
        }
    }
}

/// Reads current-work stores only. Card owns all mutable Plan and navigation
/// state so this view cannot diverge from the drawer or List.
struct PickyConversationLiveStepZone: View {
    let metaStore: PickySessionMetaStore
    let todoStore: PickySessionTodoStore
    let toolStore: PickySessionToolStore
    let activityStore: PickySessionActivityStore
    let extensionUiStore: PickySessionExtensionUiStore
    @Binding var isTodoExpanded: Bool
    let todoOpenerFocusRequestID: Int
    let viewport: PickyConversationViewportState
    let heightTier: PickyConversationFocusStackHeightTier
    let onToggleTodo: () -> Void
    let onOpenToolHistory: () -> Void
    let onGoToQuestion: (String) -> Void
    let onGoToLatest: () -> Void

    var body: some View {
        let projection = PickyConversationLiveStepProjection(
            metaStore: metaStore,
            todoStore: todoStore,
            toolStore: toolStore,
            activityStore: activityStore,
            extensionUiStore: extensionUiStore
        )
        if PickyConversationLiveStepNavigationPolicy.showsExternalLatest(status: projection.status, viewport: viewport) {
            Button(L10n.t("hud.liveStep.runningBelowLatest"), action: onGoToLatest)
                .buttonStyle(.plain)
                .font(PickyHUDTypography.statusSemibold)
                .foregroundStyle(DS.Colors.accentText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.sm)
                .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(DS.Colors.surface2))
                .help(L10n.t("hud.liveStep.runningBelowLatest.help"))
                .accessibilityLabel(L10n.t("hud.liveStep.runningBelowLatest.accessibilityLabel"))
                .hoverAffordance()
        } else if let presentation = PickyConversationLiveStepPresentation(projection: projection) {
            PickyConversationLiveStepView(
                projection: projection,
                isTodoExpanded: isTodoExpanded,
                todoOpenerFocusRequestID: todoOpenerFocusRequestID,
                heightTier: heightTier,
                onToggleTodo: onToggleTodo,
                onOpenToolHistory: onOpenToolHistory,
                onGoToQuestion: onGoToQuestion
            )
            .accessibilityLabel(presentation.label)
        }
    }
}

struct PickyConversationLiveStepTodoDrawer: View {
    let plan: PickyConversationPlanProjection
    @Binding var isExpanded: Bool
    let focusRequestID: Int
    let onClose: () -> Void

    var body: some View {
        if let todoPresentation = plan.todoPresentation,
           PickyConversationPlanDrawerPolicy.shouldRenderDrawer(plan: plan, isExpanded: isExpanded) {
            PickyTodoProgressOverlayView(
                presentation: todoPresentation,
                isSessionRunning: plan.status == .running,
                isExpanded: $isExpanded,
                focusRequestID: focusRequestID,
                onClose: onClose
            )
        }
    }
}
