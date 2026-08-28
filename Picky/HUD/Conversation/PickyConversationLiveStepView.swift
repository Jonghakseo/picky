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
    static func canOpen(status _: PickySessionStatus, todo: PickyTodoProgressPresentation?) -> Bool {
        todo != nil
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
    let pendingQuestionRequestID: String?

    init(
        metaStore: PickySessionMetaStore,
        todoStore: PickySessionTodoStore,
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
        let request: PickyExtensionUiRequest?
        if case .loaded(let value) = extensionUiStore.requestState {
            request = value
        } else {
            request = nil
        }
        pendingQuestionRequestID = request?.id
    }
}

@MainActor
enum PickyConversationLiveStepPresentation: Equatable {
    case running(stepText: String, detail: String)
    case waitingForInput(requestID: String)
    case todo(stepText: String, detail: String, status: PickyConversationStatusPresentation)

    init?(projection: PickyConversationLiveStepProjection) {
        self.init(
            status: projection.status,
            todoPresentation: projection.todoPresentation,
            pendingQuestionRequestID: projection.pendingQuestionRequestID
        )
    }

    init?(
        status: PickySessionStatus,
        todoPresentation: PickyTodoProgressPresentation?,
        pendingQuestionRequestID: String? = nil
    ) {
        switch status {
        case .running:
            guard let todoPresentation else { return nil }
            self = .running(
                stepText: todoPresentation.countText,
                detail: todoPresentation.activeText
            )
        case .waiting_for_input:
            if let pendingQuestionRequestID {
                self = .waitingForInput(requestID: pendingQuestionRequestID)
            } else if let todoPresentation {
                self = .todo(
                    stepText: todoPresentation.countText,
                    detail: todoPresentation.activeText,
                    status: PickyConversationStatusPresentation(status: status)
                )
            } else {
                return nil
            }
        case .queued, .blocked, .completed, .failed, .cancelled:
            guard let todoPresentation else { return nil }
            self = .todo(
                stepText: todoPresentation.countText,
                detail: todoPresentation.activeText,
                status: PickyConversationStatusPresentation(status: status)
            )
        }
    }

    var label: String {
        switch self {
        case .running: return L10n.t("hud.liveStep.currentActivity")
        case .waitingForInput: return L10n.t("hud.liveStep.inputNeeded")
        case .todo: return L10n.t("hud.todo.title")
        }
    }

    var iconName: String {
        switch self {
        case .running, .todo: return "checklist"
        case .waitingForInput: return "exclamationmark.bubble"
        }
    }

    var tone: PickyConversationStatusTone {
        switch self {
        case .running: return .info
        case .waitingForInput: return .warning
        case let .todo(_, _, status): return status.tone
        }
    }

    var accessibilityValue: String {
        switch self {
        case let .running(stepText, detail):
            return [L10n.t("hud.conversation.status.running"), stepText, detail].joined(separator: ", ")
        case .waitingForInput:
            return L10n.t("hud.liveStep.waitingForQuestion")
        case let .todo(stepText, detail, status):
            return [status.label, stepText, detail].joined(separator: ", ")
        }
    }
}

struct PickyConversationLiveStepView: View {
    let projection: PickyConversationLiveStepProjection
    let presentation: PickyConversationLiveStepPresentation
    let isTodoExpanded: Bool
    let onToggleTodo: () -> Void
    let onGoToQuestion: (String) -> Void

    init(
        projection: PickyConversationLiveStepProjection,
        isTodoExpanded: Bool,
        onToggleTodo: @escaping () -> Void,
        onGoToQuestion: @escaping (String) -> Void
    ) {
        self.projection = projection
        presentation = PickyConversationLiveStepPresentation(projection: projection)!
        self.isTodoExpanded = isTodoExpanded
        self.onToggleTodo = onToggleTodo
        self.onGoToQuestion = onGoToQuestion
    }

    var body: some View {
        Group {
            switch presentation {
            case let .running(stepText, detail):
                todoDisclosureContent(stepText: stepText, detail: detail)
            case let .waitingForInput(requestID):
                VStack(alignment: .leading, spacing: DS.Spacing.sm) {
                    if let todoPresentation = projection.todoPresentation {
                        todoDisclosureContent(
                            stepText: todoPresentation.countText,
                            detail: todoPresentation.activeText
                        )
                    }
                    waitingContent(requestID: requestID)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel(presentation.label)
                        .accessibilityValue(presentation.accessibilityValue)
                }
            case let .todo(stepText, detail, _):
                todoDisclosureContent(stepText: stepText, detail: detail)
            }
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous).fill(DS.Colors.surface2))
    }

    @ViewBuilder
    private func todoDisclosureContent(stepText: String, detail: String) -> some View {
        if let todoPresentation = projection.todoPresentation,
           let disclosure = PickyConversationPlanProgressDisclosurePresentation(
               status: projection.status,
               todo: todoPresentation,
               isExpanded: isTodoExpanded
           ) {
            Button(action: onToggleTodo) {
                HStack(spacing: DS.Spacing.sm) {
                    PickyTodoCircularProgressView(
                        fraction: todoPresentation.fraction,
                        isComplete: todoPresentation.isComplete,
                        side: 22,
                        lineWidth: 2.8
                    )
                    Text(disclosure.stepText)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundStyle(todoPresentation.isComplete ? DS.Colors.successText : DS.Colors.info)
                    detailText(detail)
                    Image(systemName: disclosure.chevronName)
                        .pickyFont(size: 9.5, weight: .semibold)
                        .foregroundStyle(DS.Colors.textTertiary)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("picky.todo.progress.disclosure")
            .accessibilityLabel(L10n.t("hud.liveStep.currentPlan.accessibilityLabel", disclosure.stepText))
            .accessibilityValue(todoPresentation.stepText)
            .accessibilityHint(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
            .help(isTodoExpanded ? L10n.t("hud.todo.collapse") : L10n.t("hud.todo.expand"))
            .hoverAffordance()
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
    let extensionUiStore: PickySessionExtensionUiStore
    @Binding var isTodoExpanded: Bool
    let viewport: PickyConversationViewportState
    let onToggleTodo: () -> Void
    let onGoToQuestion: (String) -> Void
    let onGoToLatest: () -> Void

    var body: some View {
        let projection = PickyConversationLiveStepProjection(
            metaStore: metaStore,
            todoStore: todoStore,
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
                onToggleTodo: onToggleTodo,
                onGoToQuestion: onGoToQuestion
            )
            .accessibilityLabel(presentation.label)
        }
    }
}

struct PickyConversationLiveStepTodoDrawer: View {
    let plan: PickyConversationPlanProjection
    @Binding var isExpanded: Bool

    var body: some View {
        if let todoPresentation = plan.todoPresentation,
           PickyConversationPlanDrawerPolicy.shouldRenderDrawer(plan: plan, isExpanded: isExpanded) {
            PickyTodoProgressOverlayView(
                presentation: todoPresentation,
                isSessionRunning: plan.status == .running,
                isExpanded: $isExpanded
            )
        }
    }
}
