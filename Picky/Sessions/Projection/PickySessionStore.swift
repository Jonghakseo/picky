//
//  PickySessionStore.swift
//  Picky
//

import Observation

/// Stable child-store aggregate for a single session.
@MainActor
@Observable
final class PickySessionStore {
    let sessionID: String
    let metaStore = PickySessionMetaStore()
    /// Dock-only scalar projection. Its equality-guarded updates isolate tiles
    /// from high-frequency conversation/tool/log mutations.
    let dockStore = PickySessionDockStore()
    let logStore = PickySessionLogStore()
    let toolStore = PickySessionToolStore()
    let todoStore = PickySessionTodoStore()
    let subagentStore = PickySessionSubagentStore()
    let artifactStore = PickySessionArtifactStore()
    let conversationStore = PickyConversationStore()
    let queueStore = PickySessionQueueStore()
    let activityStore = PickySessionActivityStore()
    let extensionUiStore = PickySessionExtensionUiStore()

    /// SessionCard has a handful of presentation-only values that have no
    /// daemon field owner (for example an optimistic request timestamp). Keep
    /// only those scalar values beside their owning child stores; never retain
    /// a writable SessionCard or session-list array.
    @ObservationIgnored private var presentation = PickySessionCardPresentation.empty

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Imports the current v1 façade card into independently-owned sections.
    /// Empty v1 collections are the only representation available for a P0
    /// omitted section at this boundary, so they explicitly clear the child to
    /// `.unavailable` rather than retaining a previous hydrated value.
    func replace(card: PickySessionListViewModel.SessionCard) {
        precondition(card.id == sessionID)
        metaStore.replace(PickySessionMetadata(card: card))
        presentation = PickySessionCardPresentation(card: card)

        replaceLogs(for: card)
        replaceTools(for: card)
        replaceTodo(for: card)
        replaceSubagentRuns(for: card)
        replaceArtifacts(for: card)
        replaceMessages(for: card)
        replaceQueue(for: card)
        activityStore.replace(card.activitySummary)
        replaceExtensionUiRequest(for: card)
        refreshDockProjection()
    }

    /// Refreshes the dock-only scalar projection after a v2 mutation has
    /// updated independently owned children. The dock store itself suppresses
    /// equivalent values, so a message-only transaction remains invisible to
    /// dock tiles.
    func refreshDockProjection() {
        guard case .loaded(let metadata) = metaStore.metadataState else {
            dockStore.markUnavailable()
            return
        }
        let todoState: PickyTodoState? = {
            guard case .loaded(let value) = todoStore.todoState else { return nil }
            return value
        }()
        dockStore.replace(metadata: metadata, todoState: todoState)
    }

    /// Rebuilds the legacy card input from independently owned child snapshots.
    /// Unavailable sections intentionally contribute their empty/default value,
    /// so omitted P0 hydration data can never revive stale child projection.
    func materializedSessionCard() -> PickySessionListViewModel.SessionCard? {
        guard case .loaded(let metadata) = metaStore.metadataState,
              metadata.id == sessionID else {
            return nil
        }

        let tools = toolStore.toolsState.loadedValue ?? []
        let todoState: PickyTodoState? = {
            guard case .loaded(let value) = todoStore.todoState else { return nil }
            return value
        }()
        let subagentRuns = subagentStore.runsState.loadedValue ?? []
        let artifacts = artifactStore.artifactsState.loadedValue ?? []
        let changedFiles = artifactStore.changedFilesProjectionState.loadedValue ?? []
        let messages = conversationStore.messagesState.loadedValue ?? []
        let queue = queueStore.queueState.loadedValue
        let queueModes = queueStore.queueModes
        let activity = activityStore.activityState.loadedValue ?? .zero
        let request: PickyExtensionUiRequest? = {
            guard case .loaded(let value) = extensionUiStore.requestState else { return nil }
            return value
        }()

        return PickySessionListViewModel.SessionCard(
            id: metadata.id,
            title: metadata.title,
            status: metadata.status,
            cwd: metadata.cwd,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            lastSummary: metadata.lastSummary ?? "",
            thinkingPreview: metadata.thinkingPreview,
            logPreview: presentation.logPreview,
            lastRequestText: presentation.lastRequestText,
            lastRequestAt: presentation.lastRequestAt,
            tools: tools,
            todoState: todoState,
            subagentRuns: subagentRuns,
            artifacts: artifacts,
            changedFiles: changedFiles,
            messages: messages,
            queuedSteers: queue?.steers ?? [],
            queuedFollowUps: queue?.followUps ?? [],
            steeringMode: queueModes.steeringMode,
            followUpMode: queueModes.followUpMode,
            activitySummary: activity,
            lastTerminalSyncOutcome: presentation.lastTerminalSyncOutcome,
            contextUsage: metadata.contextUsage,
            currentAssistantRun: metadata.currentAssistantRun,
            pendingExtensionUiRequest: request,
            piSessionFilePath: presentation.piSessionFilePath ?? metadata.piSessionFilePath,
            notifyMainOnCompletion: metadata.notifyMainOnCompletion,
            pinned: metadata.pinned ?? false,
            archived: metadata.archived ?? false,
            hasRuntimeDetachedFollowUpRejection: presentation.hasRuntimeDetachedFollowUpRejection,
            isMainAgentHandoff: presentation.isMainAgentHandoff
        )
    }

    /// Rebuilds the CLI bridge summary from the registry-owned metadata and
    /// child stores. Unlike `SessionCard`, this preserves terminal-only
    /// metadata (`finalAnswer` and `archivedAt`) that the CLI needs for its
    /// management loop. The bridge never owns or mutates this projection.
    func materializedAgentSessionSummary() -> PickyAgentSession? {
        guard case .loaded(let metadata) = metaStore.metadataState,
              metadata.id == sessionID else {
            return nil
        }

        let queue = queueStore.queueState.loadedValue
        let queueModes = queueStore.queueModes
        let todoState: PickyTodoState? = {
            guard case .loaded(let value) = todoStore.todoState else { return nil }
            return value
        }()
        let pendingExtensionUiRequest: PickyExtensionUiRequest? = {
            guard case .loaded(let request) = extensionUiStore.requestState else { return nil }
            return request
        }()
        return PickyAgentSession(
            id: metadata.id,
            title: metadata.title,
            status: metadata.status,
            cwd: metadata.cwd,
            piSessionFilePath: metadata.piSessionFilePath,
            createdAt: metadata.createdAt,
            updatedAt: metadata.updatedAt,
            lastSummary: metadata.lastSummary,
            thinkingPreview: metadata.thinkingPreview,
            finalAnswer: metadata.finalAnswer,
            logs: logStore.logsState.loadedValue ?? [],
            tools: toolStore.toolsState.loadedValue ?? [],
            todoState: todoState,
            subagentRuns: subagentStore.runsState.loadedValue ?? [],
            artifacts: artifactStore.artifactsState.loadedValue ?? [],
            changedFiles: artifactStore.changedFilesProjectionState.loadedValue ?? [],
            messages: [],
            messageJournalAvailable: false,
            queuedSteers: queue?.steers ?? [],
            queuedFollowUps: queue?.followUps ?? [],
            steeringMode: queueModes.steeringMode,
            followUpMode: queueModes.followUpMode,
            activitySummary: activityStore.activityState.loadedValue ?? .zero,
            contextUsage: metadata.contextUsage,
            currentAssistantRun: metadata.currentAssistantRun,
            pendingExtensionUiRequest: pendingExtensionUiRequest,
            notifyMainOnCompletion: metadata.notifyMainOnCompletion,
            archived: metadata.archived,
            archivedAt: metadata.archivedAt,
            pinned: metadata.pinned
        )
    }

    private func replaceLogs(for card: PickySessionListViewModel.SessionCard) {
        guard !card.logPreview.isEmpty else {
            logStore.markUnavailable()
            return
        }
        logStore.replace([card.logPreview])
    }

    private func replaceTools(for card: PickySessionListViewModel.SessionCard) {
        guard !card.tools.isEmpty else {
            toolStore.markUnavailable()
            return
        }
        toolStore.replace(card.tools)
    }

    private func replaceTodo(for card: PickySessionListViewModel.SessionCard) {
        guard let todoState = card.todoState else {
            todoStore.markUnavailable()
            return
        }
        todoStore.replace(todoState)
    }

    private func replaceSubagentRuns(for card: PickySessionListViewModel.SessionCard) {
        guard !card.subagentRuns.isEmpty else {
            subagentStore.markUnavailable()
            return
        }
        subagentStore.replace(card.subagentRuns)
    }

    private func replaceArtifacts(for card: PickySessionListViewModel.SessionCard) {
        guard !card.artifacts.isEmpty || !card.changedFiles.isEmpty else {
            artifactStore.markUnavailable()
            return
        }
        artifactStore.replace(artifacts: card.artifacts, changedFiles: card.changedFiles)
    }

    private func replaceMessages(for card: PickySessionListViewModel.SessionCard) {
        guard !card.messages.isEmpty else {
            conversationStore.markMessagesUnavailable()
            return
        }
        conversationStore.replaceMessages(card.messages)
        conversationStore.replaceMessageJournalAvailability(true)
    }

    private func replaceQueue(for card: PickySessionListViewModel.SessionCard) {
        guard !card.queuedSteers.isEmpty || !card.queuedFollowUps.isEmpty else {
            queueStore.markUnavailable(steeringMode: card.steeringMode, followUpMode: card.followUpMode)
            return
        }
        queueStore.replace(
            steers: card.queuedSteers,
            followUps: card.queuedFollowUps,
            steeringMode: card.steeringMode,
            followUpMode: card.followUpMode
        )
    }

    private func replaceExtensionUiRequest(for card: PickySessionListViewModel.SessionCard) {
        guard let request = card.pendingExtensionUiRequest else {
            extensionUiStore.markUnavailable()
            return
        }
        extensionUiStore.replace(request)
    }

    func appendProjectionLog(_ line: String) {
        if PickySessionListViewModel.SessionCard.isDisplayableLogPreview(line) {
            presentation.logPreview = line
        }
        if PickySessionListViewModel.SessionCard.isMainAgentHandoffLogLine(line) {
            presentation.isMainAgentHandoff = true
        }
        if let piSessionFilePath = PickySessionListViewModel.SessionCard.piSessionFilePath(fromLogLine: line) {
            presentation.piSessionFilePath = piSessionFilePath
        }
        if let requestText = PickySessionListViewModel.SessionCard.requestText(fromLogLine: line) {
            presentation.lastRequestText = requestText
            presentation.lastRequestAt = Date()
        }
        if PickySessionListViewModel.SessionCard.isRuntimeDetachedFollowUpRejection(line) {
            presentation.hasRuntimeDetachedFollowUpRejection = true
        }
    }

    func applyProjectionTool(_ tool: PickyToolActivity) {
        presentation.logPreview = [tool.name, tool.preview].compactMap { $0 }.joined(separator: ": ")
    }
}

private struct PickySessionCardPresentation {
    var logPreview: String
    var lastRequestText: String?
    var lastRequestAt: Date?
    var piSessionFilePath: String?
    var lastTerminalSyncOutcome: PickyTerminalSessionSyncOutcome?
    var hasRuntimeDetachedFollowUpRejection: Bool
    var isMainAgentHandoff: Bool

    static let empty = Self(
        logPreview: "",
        lastRequestText: nil,
        lastRequestAt: nil,
        piSessionFilePath: nil,
        lastTerminalSyncOutcome: nil,
        hasRuntimeDetachedFollowUpRejection: false,
        isMainAgentHandoff: false
    )

    init(card: PickySessionListViewModel.SessionCard) {
        logPreview = card.logPreview
        lastRequestText = card.lastRequestText
        lastRequestAt = card.lastRequestAt
        piSessionFilePath = card.piSessionFilePath
        lastTerminalSyncOutcome = card.lastTerminalSyncOutcome
        hasRuntimeDetachedFollowUpRejection = card.hasRuntimeDetachedFollowUpRejection
        isMainAgentHandoff = card.isMainAgentHandoff
    }

    private init(
        logPreview: String,
        lastRequestText: String?,
        lastRequestAt: Date?,
        piSessionFilePath: String?,
        lastTerminalSyncOutcome: PickyTerminalSessionSyncOutcome?,
        hasRuntimeDetachedFollowUpRejection: Bool,
        isMainAgentHandoff: Bool
    ) {
        self.logPreview = logPreview
        self.lastRequestText = lastRequestText
        self.lastRequestAt = lastRequestAt
        self.piSessionFilePath = piSessionFilePath
        self.lastTerminalSyncOutcome = lastTerminalSyncOutcome
        self.hasRuntimeDetachedFollowUpRejection = hasRuntimeDetachedFollowUpRejection
        self.isMainAgentHandoff = isMainAgentHandoff
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
