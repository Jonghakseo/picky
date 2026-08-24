//
//  PickySessionStore.swift
//  Picky
//

import Observation

/// Stable child-store aggregate for a single session. It is dormant until W4.5.
@MainActor
@Observable
final class PickySessionStore {
    let sessionID: String
    let metaStore = PickySessionMetaStore()
    let logStore = PickySessionLogStore()
    let toolStore = PickySessionToolStore()
    let todoStore = PickySessionTodoStore()
    let subagentStore = PickySessionSubagentStore()
    let artifactStore = PickySessionArtifactStore()
    let conversationStore = PickyConversationStore()
    let queueStore = PickySessionQueueStore()
    let activityStore = PickySessionActivityStore()
    let extensionUiStore = PickySessionExtensionUiStore()

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    /// Rebuilds the legacy card input from independently owned child snapshots.
    /// Unavailable sections intentionally contribute their empty/default value,
    /// so omitted P0 hydration data can never revive stale child projection.
    func materializedSessionCard() -> PickySessionListViewModel.SessionCard? {
        guard case .loaded(let metadata) = metaStore.metadataState,
              metadata.id == sessionID else {
            return nil
        }

        let logs = logStore.logsState.loadedValue ?? []
        let tools = toolStore.toolsState.loadedValue ?? []
        let todoState: PickyTodoState? = {
            guard case .loaded(let value) = todoStore.todoState else { return nil }
            return value
        }()
        let subagentRuns = subagentStore.runsState.loadedValue ?? []
        let artifacts = artifactStore.artifactsState.loadedValue ?? []
        let changedFiles = artifactStore.changedFilesProjectionState.loadedValue ?? []
        let messages = conversationStore.messagesState.loadedValue ?? []
        let messageJournalAvailable: Bool? = {
            guard case .loaded(let value) = conversationStore.messageJournalAvailabilityState else { return nil }
            return value
        }()
        let queue = queueStore.queueState.loadedValue
        let activity = activityStore.activityState.loadedValue ?? .zero
        let request: PickyExtensionUiRequest? = {
            guard case .loaded(let value) = extensionUiStore.requestState else { return nil }
            return value
        }()

        return .fromAgentSession(PickyAgentSession(
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
            logs: logs,
            tools: tools,
            todoState: todoState,
            subagentRuns: subagentRuns,
            artifacts: artifacts,
            changedFiles: changedFiles,
            messages: messages,
            messageJournalAvailable: messageJournalAvailable,
            queuedSteers: queue?.steers ?? [],
            queuedFollowUps: queue?.followUps ?? [],
            steeringMode: queue?.steeringMode ?? .oneAtATime,
            followUpMode: queue?.followUpMode ?? .oneAtATime,
            activitySummary: activity,
            contextUsage: metadata.contextUsage,
            currentAssistantRun: metadata.currentAssistantRun,
            pendingExtensionUiRequest: request,
            notifyMainOnCompletion: metadata.notifyMainOnCompletion,
            archived: metadata.archived,
            pinned: metadata.pinned
        ))
    }
}

private extension PickyProjectionSectionState {
    var loadedValue: Value? {
        guard case .loaded(let value) = self else { return nil }
        return value
    }
}
