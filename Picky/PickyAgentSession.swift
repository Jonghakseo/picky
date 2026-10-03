import Foundation

struct PickyAgentSession: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    var status: PickySessionStatus
    var cwd: String?
    var piSessionFilePath: String? = nil
    let createdAt: Date
    var updatedAt: Date
    var lastSummary: String?
    var thinkingPreview: String? = nil
    var finalAnswer: String? = nil
    var logs: [String]
    var tools: [PickyToolActivity]
    var todoState: PickyTodoState? = nil
    var subagentRuns: [PickySubagentRun] = []
    var agentCycle: PickyAgentCycle? = nil
    var asyncWorkSummary: PickyAsyncWorkSummary? = nil
    var asyncTasks: [PickyAsyncTask]? = nil
    var completionTickets: [PickyCompletionTicket]? = nil
    var asyncControl: PickyAsyncControlState? = nil
    var artifacts: [PickyArtifact]
    var changedFiles: [PickyChangedFile]
    var messages: [PickySessionMessage] = []
    /// `false` means this is a bridge list summary; its empty `messages`
    /// collection is intentionally not an authoritative journal.
    var messageJournalAvailable: Bool? = nil
    var queuedSteers: [PickyQueueItem] = []
    var queuedFollowUps: [PickyQueueItem] = []
    /// Delayed-action timed messages waiting for their send time, sorted by `dueAt`.
    var scheduledMessages: [PickyScheduledMessage] = []
    var steeringMode: PickyQueueMode = .oneAtATime
    var followUpMode: PickyQueueMode = .oneAtATime
    var activitySummary: PickyActivitySummary = .zero
    var contextUsage: PickyContextUsage? = nil
    var currentAssistantRun: PickyAssistantRunMetadata? = nil
    var pendingExtensionUiRequest: PickyExtensionUiRequest?
    var notifyMainOnCompletion: Bool? = nil
    var notifyMacOSOnCompletion: Bool? = nil
    var archived: Bool? = nil, archivedAt: Date? = nil
    var pinned: Bool? = nil
    /// Newest user-authored input the daemon accepted, typed by the daemon so the
    /// app never reconstructs it from log-line prefixes.
    var lastRequest: PickySessionLastRequest? = nil
    enum CodingKeys: String, CodingKey {
        case id, title, status, cwd, piSessionFilePath, createdAt, updatedAt, lastSummary, thinkingPreview, finalAnswer, logs, tools, todoState, subagentRuns, artifacts, changedFiles
        case agentCycle, asyncWorkSummary, asyncTasks, completionTickets, asyncControl
        case messages, messageJournalAvailable, queuedSteers, queuedFollowUps, scheduledMessages, steeringMode, followUpMode, activitySummary, contextUsage, currentAssistantRun
        case pendingExtensionUiRequest, notifyMainOnCompletion, notifyMacOSOnCompletion, archived, archivedAt, pinned, lastRequest
    }
    init(
        id: String,
        title: String,
        status: PickySessionStatus,
        cwd: String? = nil,
        piSessionFilePath: String? = nil,
        createdAt: Date,
        updatedAt: Date,
        lastSummary: String? = nil,
        thinkingPreview: String? = nil,
        finalAnswer: String? = nil,
        logs: [String],
        tools: [PickyToolActivity],
        todoState: PickyTodoState? = nil,
        subagentRuns: [PickySubagentRun] = [],
        agentCycle: PickyAgentCycle? = nil,
        asyncWorkSummary: PickyAsyncWorkSummary? = nil,
        asyncTasks: [PickyAsyncTask]? = nil,
        completionTickets: [PickyCompletionTicket]? = nil,
        asyncControl: PickyAsyncControlState? = nil,
        artifacts: [PickyArtifact],
        changedFiles: [PickyChangedFile],
        messages: [PickySessionMessage] = [],
        messageJournalAvailable: Bool? = nil,
        queuedSteers: [PickyQueueItem] = [],
        queuedFollowUps: [PickyQueueItem] = [],
        scheduledMessages: [PickyScheduledMessage] = [],
        steeringMode: PickyQueueMode = .oneAtATime,
        followUpMode: PickyQueueMode = .oneAtATime,
        activitySummary: PickyActivitySummary = .zero,
        contextUsage: PickyContextUsage? = nil,
        currentAssistantRun: PickyAssistantRunMetadata? = nil,
        pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
        notifyMainOnCompletion: Bool? = nil,
        notifyMacOSOnCompletion: Bool? = nil,
        archived: Bool? = nil, archivedAt: Date? = nil,
        pinned: Bool? = nil,
        lastRequest: PickySessionLastRequest? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.cwd = cwd
        self.piSessionFilePath = piSessionFilePath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSummary = lastSummary
        self.thinkingPreview = thinkingPreview
        self.finalAnswer = finalAnswer
        self.logs = logs
        self.tools = tools
        self.todoState = todoState
        self.subagentRuns = subagentRuns
        self.agentCycle = agentCycle
        self.asyncWorkSummary = asyncWorkSummary
        self.asyncTasks = asyncTasks
        self.completionTickets = completionTickets
        self.asyncControl = asyncControl
        self.artifacts = artifacts
        self.changedFiles = changedFiles
        self.messages = messages
        self.messageJournalAvailable = messageJournalAvailable
        self.queuedSteers = queuedSteers
        self.queuedFollowUps = queuedFollowUps
        self.scheduledMessages = scheduledMessages
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.activitySummary = activitySummary
        self.contextUsage = contextUsage
        self.currentAssistantRun = currentAssistantRun
        self.pendingExtensionUiRequest = pendingExtensionUiRequest
        self.notifyMainOnCompletion = notifyMainOnCompletion
        self.notifyMacOSOnCompletion = notifyMacOSOnCompletion
        self.archived = archived
        self.archivedAt = archivedAt
        self.pinned = pinned
        self.lastRequest = lastRequest
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        status = try container.decode(PickySessionStatus.self, forKey: .status)
        cwd = try container.decodeIfPresent(String.self, forKey: .cwd)
        piSessionFilePath = try container.decodeIfPresent(String.self, forKey: .piSessionFilePath)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        lastSummary = try container.decodeIfPresent(String.self, forKey: .lastSummary)
        thinkingPreview = try container.decodeIfPresent(String.self, forKey: .thinkingPreview)
        finalAnswer = try container.decodeIfPresent(String.self, forKey: .finalAnswer)
        logs = try container.decodeIfPresent([String].self, forKey: .logs) ?? []
        tools = try container.decodeIfPresent([PickyToolActivity].self, forKey: .tools) ?? []
        todoState = try container.decodeIfPresent(PickyTodoState.self, forKey: .todoState)
        subagentRuns = try container.decodeIfPresent([PickySubagentRun].self, forKey: .subagentRuns) ?? []
        agentCycle = try container.decodeIfPresent(PickyAgentCycle.self, forKey: .agentCycle)
        asyncWorkSummary = try container.decodeIfPresent(PickyAsyncWorkSummary.self, forKey: .asyncWorkSummary)
        asyncTasks = try container.decodeIfPresent([PickyAsyncTask].self, forKey: .asyncTasks)
        completionTickets = try container.decodeIfPresent([PickyCompletionTicket].self, forKey: .completionTickets)
        asyncControl = try container.decodeIfPresent(PickyAsyncControlState.self, forKey: .asyncControl)
        artifacts = try container.decodeIfPresent([PickyArtifact].self, forKey: .artifacts) ?? []
        changedFiles = try container.decodeIfPresent([PickyChangedFile].self, forKey: .changedFiles) ?? []
        messages = try container.decodeIfPresent([PickySessionMessage].self, forKey: .messages) ?? []
        messageJournalAvailable = try container.decodeIfPresent(Bool.self, forKey: .messageJournalAvailable)
        queuedSteers = try container.decodeIfPresent([PickyQueueItem].self, forKey: .queuedSteers) ?? []
        queuedFollowUps = try container.decodeIfPresent([PickyQueueItem].self, forKey: .queuedFollowUps) ?? []
        scheduledMessages = try container.decodeIfPresent([PickyScheduledMessage].self, forKey: .scheduledMessages) ?? []
        steeringMode = try container.decodeIfPresent(PickyQueueMode.self, forKey: .steeringMode) ?? .oneAtATime
        followUpMode = try container.decodeIfPresent(PickyQueueMode.self, forKey: .followUpMode) ?? .oneAtATime
        activitySummary = try container.decodeIfPresent(PickyActivitySummary.self, forKey: .activitySummary) ?? .zero
        contextUsage = try container.decodeIfPresent(PickyContextUsage.self, forKey: .contextUsage)
        currentAssistantRun = try container.decodeIfPresent(PickyAssistantRunMetadata.self, forKey: .currentAssistantRun)
        pendingExtensionUiRequest = try container.decodeIfPresent(PickyExtensionUiRequest.self, forKey: .pendingExtensionUiRequest)
        notifyMainOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyMainOnCompletion)
        notifyMacOSOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyMacOSOnCompletion)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        archivedAt = try container.decodeIfPresent(Date.self, forKey: .archivedAt)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
        lastRequest = try container.decodeIfPresent(PickySessionLastRequest.self, forKey: .lastRequest)
        if let asyncTasks, let completionTickets {
            try PickyAsyncTaskDetail(tasks: asyncTasks, tickets: completionTickets).validate(codingPath: decoder.codingPath)
            guard asyncTasks.allSatisfy({ $0.sessionId == id }) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Async task session mismatch"))
            }
        }
    }
}

extension PickyAgentSession {
    var hasAsyncTracking: Bool {
        asyncWorkSummary != nil || asyncControl != nil || asyncTasks != nil || completionTickets != nil || agentCycle != nil
    }
}
