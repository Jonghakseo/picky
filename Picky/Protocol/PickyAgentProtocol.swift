//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-08-25"

/// User-configurable Picky main-agent tools. Pickle delegation and management
/// use the local `picky` CLI through bash and are always available, so only
/// capabilities that still add dedicated agent context belong here.
enum PickyBuiltinTool: String, Codable, CaseIterable, Hashable, Sendable {
    case screenOverlay = "picky_screen_overlay"
    case readUserGuide = "read_picky_user_guide"

    /// L10n key for the user-facing display name shown in the settings UI.
    var displayNameKey: String {
        switch self {
        case .screenOverlay: "settings.builtinTools.tool.screenOverlay.name"
        case .readUserGuide: "settings.builtinTools.tool.readUserGuide.name"
        }
    }

    /// L10n key for the short description shown under the tool name.
    var descriptionKey: String {
        switch self {
        case .screenOverlay: "settings.builtinTools.tool.screenOverlay.description"
        case .readUserGuide: "settings.builtinTools.tool.readUserGuide.description"
        }
    }
}

struct PickyCommandEnvelope: Codable, Equatable {
    let id: String
    let protocolVersion: String
    let type: PickyCommandType
    var context: PickyContextPacket?
    var caller: String?
    var sessionId: String?
    var text: String?
    var source: String?
    var requestId: String?
    var toolCallId: String?
    var expectedSessionFile: String?
    var part: PickyToolHistoryDetailPart?
    var cursor: String?
    var view: PickySessionDiffView?
    var value: JSONValue?
    var providerId: PickyPiOAuthLoginProvider?
    var promptId: String?
    var cancelled: Bool?
    var artifactId: String?
    var title: String?
    var instructions: String?
    var cwd: String?
    var errorMessage: String?
    var errorCode: String?
    var result: JSONValue?
    var capabilities: [String]?
    var profile: PickyClientProfile?
    var sessions: [PickyAgentSession]?
    var groups: [PickyDockGroupPayload]?
    var session: PickyAgentSession?
    var delivered: Bool?
    var prompt: String?
    var enabled: Bool?
    /// Optional for compatibility with app/daemon versions predating new-Pickle defaults.
    var notifyMainOnCompletion: Bool?
    var notifyMacOSOnCompletion: Bool?
    var command: PickyAsyncTaskCommand?
    var archiveMode: PickyAsyncTaskCommand.ArchiveMode?
    var archived: Bool?
    var defaultCwd: String?
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel?
    var mainAgentModelPattern: String?
    var direction: PickyModelCycleDirection?
    var kind: PickyQueueClearKind?
    /// `abort` only. `.response` stops the model turn and keeps background async tasks running.
    var scope: PickyAbortScope?
    /// `PickyQueueItem.id` targeted by a per-item queue command.
    var itemId: String?
    /// `PickyScheduledMessage.id` targeted by a scheduled-message command.
    var scheduledId: String?
    /// Send delay for `scheduleMessage`, in milliseconds. Always > 0.
    var delayMs: Int?
    /// Pi message id observed when a Picky terminal overlay was opened. The daemon imports only
    /// active Pi transcript messages after this id when syncing the terminal session back.
    var baselinePiMessageId: String?
    var disabledBuiltinTools: [String]?
    /// Curated package sources for `inspectPackageConflicts`.
    var sources: [String]?
    var action: PickyCommandAction?
    /// `controlMainTask` / `resolveMainDelegation` targets. See PickyMainTaskProtocol.swift.
    var taskId: String?, decisionId: String?, choice: PickyMainDelegationChoice?
    /// `setMainTaskModelPresets` payload.
    var taskModelPresets: PickyMainTaskModelPresets?
    var groupAction: PickyDockGroupManagementAction?
    var pickleAction: PickyPickleCLIAction?
    var groupId: String?
    var name: String?
    var sessionIds: [String]?
    var entryId: String?
    var generation: Int?
    var lines: [String]?
    var cursorLine: Int?
    var cursorCol: Int?
    var force: Bool?
    var draftRevision: Int?
    var draftFingerprint: String?
    var item: PickyAutocompleteItem?
    var prefix: String?
    /// Enables turn-scoped visual annotation DSL parsing for an explicitly armed Pickle input.
    /// Agentd still requires at least one screenshot before activating the capability.
    var visualDslEnabled: Bool?
    var provider: String?
    var modelId: String?
    var thinkingLevel: PickyMainAgentThinkingLevel?
    var mode: PickyRuntimeModelScopeMode?
    var patterns: [String]?
    var expectedRevision: String?
    /// Stable durable terminal identity for a Pickle completion bridge request.
    var completionId: String?
    var status: PickySessionStatus?
    var summary: String?
    /// Explicit opt-in for sending bounded Pickle metadata to the configured model provider.
    var classificationEnabled: Bool?
    /// `addMcpServer`: one `mcpServers` entry as JSON text; agentd validates it with Pi's rules.
    var configJson: String?
    var pickyScope: PickyMcpScope?
    /// CLI caller identity forwarded to the owning daemon for `validateCliCaller`
    /// and for a `--self` rename. The app never derives identity from it.
    var callerContext: PickyCliCallerContext?

    init(
        id: String = "cmd-\(UUID().uuidString)",
        type: PickyCommandType,
        context: PickyContextPacket? = nil,
        caller: String? = nil,
        sessionId: String? = nil,
        text: String? = nil,
        source: String? = nil,
        requestId: String? = nil,
        view: PickySessionDiffView? = nil,
        value: JSONValue? = nil,
        providerId: PickyPiOAuthLoginProvider? = nil,
        promptId: String? = nil,
        cancelled: Bool? = nil,
        artifactId: String? = nil,
        title: String? = nil,
        instructions: String? = nil,
        cwd: String? = nil,
        errorMessage: String? = nil,
        errorCode: String? = nil,
        result: JSONValue? = nil,
        capabilities: [String]? = nil,
        profile: PickyClientProfile? = nil,
        sessions: [PickyAgentSession]? = nil,
        groups: [PickyDockGroupPayload]? = nil,
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        prompt: String? = nil,
        enabled: Bool? = nil,
        notifyMainOnCompletion: Bool? = nil,
        notifyMacOSOnCompletion: Bool? = nil,
        command: PickyAsyncTaskCommand? = nil,
        archiveMode: PickyAsyncTaskCommand.ArchiveMode? = nil,
        archived: Bool? = nil,
        defaultCwd: String? = nil,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mainAgentModelPattern: String? = nil,
        direction: PickyModelCycleDirection? = nil,
        kind: PickyQueueClearKind? = nil,
        scope: PickyAbortScope? = nil,
        itemId: String? = nil,
        scheduledId: String? = nil,
        delayMs: Int? = nil,
        baselinePiMessageId: String? = nil,
        disabledBuiltinTools: [String]? = nil,
        sources: [String]? = nil,
        action: PickyCommandAction? = nil,
        groupAction: PickyDockGroupManagementAction? = nil,
        pickleAction: PickyPickleCLIAction? = nil,
        groupId: String? = nil,
        name: String? = nil,
        sessionIds: [String]? = nil,
        entryId: String? = nil,
        generation: Int? = nil,
        lines: [String]? = nil,
        cursorLine: Int? = nil,
        cursorCol: Int? = nil,
        force: Bool? = nil,
        draftRevision: Int? = nil,
        draftFingerprint: String? = nil,
        item: PickyAutocompleteItem? = nil,
        prefix: String? = nil,
        visualDslEnabled: Bool? = nil,
        provider: String? = nil,
        modelId: String? = nil,
        thinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mode: PickyRuntimeModelScopeMode? = nil,
        patterns: [String]? = nil,
        expectedRevision: String? = nil,
        completionId: String? = nil,
        status: PickySessionStatus? = nil,
        summary: String? = nil,
        classificationEnabled: Bool? = nil,
        configJson: String? = nil,
        pickyScope: PickyMcpScope? = nil,
        callerContext: PickyCliCallerContext? = nil
    ) {
        self.id = id
        self.protocolVersion = pickyAgentProtocolVersion
        self.type = type
        self.context = context
        self.caller = caller
        self.sessionId = sessionId
        self.text = text
        self.source = source
        self.requestId = requestId
        self.view = view
        self.value = value
        self.providerId = providerId
        self.promptId = promptId
        self.cancelled = cancelled
        self.artifactId = artifactId
        self.title = title
        self.instructions = instructions
        self.cwd = cwd
        self.errorMessage = errorMessage
        self.errorCode = errorCode
        self.result = result
        self.capabilities = capabilities
        self.profile = profile
        self.sessions = sessions
        self.groups = groups
        self.session = session
        self.delivered = delivered
        self.prompt = prompt
        self.enabled = enabled
        self.notifyMainOnCompletion = notifyMainOnCompletion
        self.notifyMacOSOnCompletion = notifyMacOSOnCompletion
        self.command = command
        self.archiveMode = archiveMode
        self.archived = archived
        self.defaultCwd = defaultCwd
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentModelPattern = mainAgentModelPattern
        self.direction = direction
        self.kind = kind
        self.scope = scope
        self.itemId = itemId
        self.scheduledId = scheduledId
        self.delayMs = delayMs
        self.baselinePiMessageId = baselinePiMessageId
        self.action = action
        self.groupAction = groupAction
        self.pickleAction = pickleAction
        self.groupId = groupId
        self.name = name
        self.sessionIds = sessionIds
        self.entryId = entryId
        self.disabledBuiltinTools = disabledBuiltinTools
        self.sources = sources
        self.generation = generation
        self.lines = lines
        self.cursorLine = cursorLine
        self.cursorCol = cursorCol
        self.force = force
        self.draftRevision = draftRevision
        self.draftFingerprint = draftFingerprint
        self.item = item
        self.prefix = prefix
        self.visualDslEnabled = visualDslEnabled
        self.provider = provider
        self.modelId = modelId
        self.thinkingLevel = thinkingLevel
        self.mode = mode
        self.patterns = patterns
        self.expectedRevision = expectedRevision
        self.completionId = completionId
        self.status = status
        self.summary = summary
        self.classificationEnabled = classificationEnabled
        self.configJson = configJson
        self.pickyScope = pickyScope
        self.callerContext = callerContext
    }
}

enum PickyQueueClearKind: String, Codable, Equatable {
    case steering, followUp, all
}

/// What a Pickle stop ends. `.all` also stops background async tasks (the default abort).
enum PickyAbortScope: String, Codable, Equatable {
    case response, all
}

enum PickyModelCycleDirection: String, Codable, Equatable {
    case forward, backward
}

enum PickyCommandType: String, Codable, Equatable {
    case getAsyncControlContext
    case asyncTaskCommand
    case routeTask
    case createTask
    case createEmptyPickleSession
    case createPickleFromHandoff
    case completePickleHandoff
    case registerAppCapabilities
    case completePickleBridgeRequest
    case completeExternalEntryRequest
    case completeDockGroupsRequest
    case createPickleFromMain
    case listPickles
    case getPickle
    case controlPickle
    case setPickleArchived
    case deletePickle
    case manageDockGroups
    case controlPushToTalkFromExternal
    case completePushToTalkControlRequest
    case completePickySettingsRequest
    case duplicatePickleSession
    case pinPickleSession
    /// CLI-originated: `picky whoami` and `picky pickle-rename`. The app never
    /// sends these — the daemon turns them into a Pickle bridge request — but
    /// they stay in the shared command table so protocol fixtures and logs
    /// decode on both ends.
    case whoami
    case renamePickle
    /// Owner-local CLI caller validation. Answered only by the daemon that owns
    /// the claimed runtime session; a strict ack is the only success signal.
    case validateCliCaller
    /// Owner-local rename of a session the receiving daemon owns. Acknowledged
    /// after the new title is durably committed.
    case renameSession
    /// Metadata-only rename performed by the primary daemon for a Pickle whose
    /// child daemon is confirmed stopped. It must never start a runtime.
    case renameStoredPickle
    case clearQueue
    /// Removes one queued steer or follow-up by `PickyQueueItem.id`.
    case removeQueuedInput
    case editQueuedFollowUp
    case sendQueuedFollowUpNow
    case scheduleMessage
    case cancelScheduledMessage
    case editScheduledMessage
    case sendScheduledMessageNow
    case syncTerminalSession
    case setTerminalSessionTailEnabled
    case followUp
    case steer
    case abort
    case listMainMessages
    case listMainAgentModels
    case getPiOAuthStatus
    case signInPiOAuth
    case signOutPiOAuth
    case answerPiOAuthPrompt
    case cancelPiOAuth
    case reloadPiAuthentication
    case setDefaultCwd
    case setMainAgentModel
    case resetMainAgent
    case abortMainAgent
    case setMainAgentThinkingLevel
    case setMainAgentFastMode
    case cycleSessionThinkingLevel
    case listSessionRuntimeOptions
    case setGlobalModelScope
    case setSessionModel
    case setSessionThinkingLevel
    case setSessionFastMode
    case cycleSessionModel
    case listSlashCommands
    case getAutocompleteCapabilities
    case autocompleteQuery
    case autocompleteApply
    case listRewindTargets
    case getSessionDiff
    case getToolHistoryDetail
    case rewindSession
    case getSessionProjectionSnapshot
    case answerExtensionUi
    case answerMainExtensionUi
    case setNotifyMainOnCompletion
    case setNotifyMacOSOnCompletion
    case setSessionArchived
    case deleteSession
    case notifyMainOfPickleCompletion
    case setDisabledBuiltinTools
    case setMainAgentTTSEnabled
    case installPackage
    case removePackage
    case checkPackageUpdates
    case inspectPackageConflicts
    case updatePackage
    case setupPackage
    case reloadPlugins
    case listMcpServers
    case addMcpServer
    case updateMcpServer
    case removeMcpServer
    case signInMcpServer
    case signOutMcpServer
    case getHubStatistics, resetHubStatistics, configureHubStatistics, getUsageLimits
    case controlMainTask, resolveMainDelegation
    case setMainTaskModelPresets, getMainTaskModelPresets
}

struct PickyEventEnvelope: Decodable, Equatable {
    let id: String
    let protocolVersion: String
    let timestamp: Date
    let event: PickyEvent

    enum CodingKeys: String, CodingKey { case id, protocolVersion, timestamp, type }

    init(id: String, protocolVersion: String, timestamp: Date, event: PickyEvent) {
        self.id = id
        self.protocolVersion = protocolVersion
        self.timestamp = timestamp
        self.event = event
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        protocolVersion = try container.decode(String.self, forKey: .protocolVersion)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        let type = try container.decode(String.self, forKey: .type)
        event = try PickyEvent(type: type, decoder: decoder)
    }
}

enum PickyEvent: Equatable {
    case asyncControlContext(PickyAsyncControlContext)
    case asyncTaskCommandResult(PickyAsyncTaskCommandResult)
    case hello(PickyHelloEvent)
    case quickReply(PickyQuickReplyEvent)
    /// Main-agent turn finished without user-visible reply text (for example, DSL-only screen guidance).
    case mainTurnSettled(contextId: String)
    case mainNarrationChunk(PickyMainNarrationChunkEvent)
    case mainVisualNarrationSegmentPrepared(PickyVisualNarrationSegmentPreparedEvent)
    case mainVisualNarrationSegmentSentence(PickyVisualNarrationSegmentSentenceEvent)
    case mainVisualNarrationSegmentCommitted(PickyVisualNarrationSegmentCommittedEvent)
    case mainMessagesSnapshot([PickyMainAgentMessage])
    case mainMessageAppended(PickyMainAgentMessage)
    case mainActivityUpdated(PickyMainActivity?)
    case mainExtensionUiRequested(PickyExtensionUiRequest)
    case mainExtensionUiCancelled(requestId: String)
    case mainAgentSessionInfoUpdated(sessionFilePath: String?, cwd: String?)
    case mainAgentModelsSnapshot([PickyMainAgentModelOption])
    case mainTasksUpdated(PickyMainTasksSnapshot)
    /// Answer to `getMainTaskModelPresets`. `automatic` is nil until the main agent starts.
    case mainTaskModelPresets(automatic: PickyMainTaskAutomaticModels?)
    case sessionRuntimeOptionsSnapshot(sessionId: String, requestId: String, models: [PickySessionRuntimeModelOption], allModels: [PickySessionRuntimeModelOption]?, globalScope: PickyRuntimeModelScope?, projectScope: PickyRuntimeModelScope?, effectiveScope: PickyRuntimeModelScope?, thinkingLevels: [PickyMainAgentThinkingLevel], currentModel: PickySessionRuntimeModelIdentity?)
    case piOAuthStatus(PickyPiOAuthStatusEvent)
    case piOAuthUrlRequested(PickyPiOAuthUrlRequestEvent)
    case piOAuthPromptRequested(PickyPiOAuthPromptRequestEvent)
    case piAuthenticationReloaded(PickyPiAuthenticationReloadedEvent)
    case sessionProjectionTransaction(PickySessionProjectionTransaction), sessionProjectionSnapshot(PickySessionProjectionSnapshot)
    case sessionProjectionBootstrapComplete(PickySessionProjectionBootstrapComplete)
    case sessionResourcesReloaded(sessionId: String)
    case pluginsReloaded(PickyPluginsReloadedEvent)
    case hubStatisticsResult(PickyHubStatisticsResultEvent), usageLimitsResult(PickyUsageLimitsResultEvent)
    case packageUpdatesAvailable(PickyPackageUpdatesAvailableEvent)
    case packageConflicts(PickyPackageConflictsEvent)
    case packageOperationProgress(PickyPackageOperationProgressEvent)
    case packageOperationCompleted(PickyPackageOperationCompletedEvent)
    case mcpServerList(PickyMcpServerListEvent)
    case mcpServerOperationCompleted(PickyMcpServerOperationCompletedEvent)
    case extensionUiRequest(PickyExtensionUiRequest)
    case pointerOverlayRequested(PickyPointerOverlayRequest)
    case annotationOverlayRequested(PickyAnnotationOverlayRequest)
    case pickleHandoffRequested(PickyPickleHandoffRequest)
    case pickleBridgeRequested(PickyPickleBridgeRequest)
    case externalEntryRequested(PickyExternalEntryRequest)
    case externalEntryAccepted(PickyExternalEntryAcceptedEvent)
    case dockGroupsRequested(requestId: String)
    case pushToTalkControlRequested(PickyPushToTalkControlRequest)
    case pickySettingsRequested(PickySettingsRequest)
    case slashCommandsSnapshot(sessionId: String, requestId: String?, commands: [PickySlashCommand])
    case autocompleteCapabilitiesSnapshot(PickyAutocompleteCapabilitiesSnapshot)
    case autocompleteSuggestionsSnapshot(PickyAutocompleteSuggestionsSnapshot)
    case autocompleteCompletionApplied(PickyAutocompleteCompletionApplied)
    case rewindTargetsSnapshot(sessionId: String, requestId: String?, targets: [PickyRewindTarget])
    case toolHistoryDetailResult(PickyToolHistoryDetailResult)
    case sessionDiffResult(PickySessionDiffResult)
    case sessionRewound(sessionId: String, editorText: String?, removedIds: [String])
    /// Live-only presence signal: the model is streaming its reply text. The
    /// daemon deliberately does not persist this, so it is never hydrated from
    /// a snapshot and an older daemon simply never sends it.
    case sessionReplyWritingUpdated(sessionId: String, writing: Bool)
    /// Live-only presence signal: the model is streaming a tool call's
    /// arguments, which can take far longer than running the tool. Same
    /// contract as `sessionReplyWritingUpdated`.
    case sessionToolCallPreparingUpdated(sessionId: String, preparing: Bool)
    /// Live-only presence signal: Pi is waiting to re-send a failed model
    /// request (rate limit, 5xx, network); nil once the model makes progress or
    /// the turn ends. Same contract as `sessionReplyWritingUpdated`.
    case sessionAutoRetryUpdated(sessionId: String, retry: PickyAutoRetryStatus?)
    case terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome)
    /// The owning daemon's committed answer to a rename, correlated by the
    /// command id and unicast to the sender. `revision` is the committed
    /// projection revision when the daemon reports one.
    case pickleSessionUpdated(commandId: String, session: PickyAgentSession, revision: Int?)
    case error(PickyErrorEvent)
    case ack(PickyAckEvent)
    case unknown(type: String)

    init(type: String, decoder: Decoder) throws {
        if let event = try Self.decodeMainAgentEvent(type: type, decoder: decoder)
            ?? Self.decodeSessionEvent(type: type, decoder: decoder)
            ?? Self.decodeBridgeEvent(type: type, decoder: decoder) {
            self = event
        } else {
            self = .unknown(type: type)
        }
    }

    /// Main companion conversation events (hello, quick replies, transcript, models, errors).
    private static func decodeMainAgentEvent(type: String, decoder: Decoder) throws -> PickyEvent? {
        switch type {
        case "asyncControlContext": return .asyncControlContext(try PickyAsyncControlContext(from: decoder))
        case "asyncTaskCommandResult": return .asyncTaskCommandResult(try PickyAsyncTaskResultEvent(from: decoder).result)
        case "hello": return .hello(try PickyHelloEvent(from: decoder))
        case "quickReply":
            return .quickReply(try PickyQuickReplyEvent(from: decoder))
        case "mainTurnSettled":
            return .mainTurnSettled(contextId: try PickyMainTurnSettledPayload(from: decoder).contextId)
        case "mainNarrationChunk":
            return .mainNarrationChunk(try PickyMainNarrationChunkEvent(from: decoder))
        case "mainVisualNarrationSegmentPrepared":
            return .mainVisualNarrationSegmentPrepared(try PickyVisualNarrationSegmentPreparedEvent(from: decoder))
        case "mainVisualNarrationSegmentSentence":
            return .mainVisualNarrationSegmentSentence(try PickyVisualNarrationSegmentSentenceEvent(from: decoder))
        case "mainVisualNarrationSegmentCommitted":
            return .mainVisualNarrationSegmentCommitted(try PickyVisualNarrationSegmentCommittedEvent(from: decoder))
        case "mainMessagesSnapshot":
            let payload = try PickyMainMessagesSnapshotPayload(from: decoder)
            return .mainMessagesSnapshot(payload.messages)
        case "mainMessageAppended":
            let payload = try PickyMainMessageAppendedPayload(from: decoder)
            return .mainMessageAppended(payload.message)
        case "mainActivityUpdated":
            return .mainActivityUpdated(try PickyMainActivityUpdatedPayload(from: decoder).activity)
        case "mainExtensionUiRequested":
            return .mainExtensionUiRequested(try PickyMainExtensionUiRequestedPayload(from: decoder).request)
        case "mainExtensionUiCancelled":
            return .mainExtensionUiCancelled(requestId: try PickyMainExtensionUiCancelledPayload(from: decoder).requestId)
        case "mainAgentSessionInfoUpdated":
            let payload = try PickyMainAgentSessionInfoUpdatedPayload(from: decoder)
            return .mainAgentSessionInfoUpdated(sessionFilePath: payload.sessionFilePath, cwd: payload.cwd)
        case "mainAgentModelsSnapshot":
            let payload = try PickyMainAgentModelsSnapshotPayload(from: decoder)
            return .mainAgentModelsSnapshot(payload.models)
        case "mainTasksUpdated": return .mainTasksUpdated(try PickyMainTasksSnapshot(from: decoder))
        case "mainTaskModelPresets":
            return .mainTaskModelPresets(automatic: try PickyMainTaskModelPresetsPayload(from: decoder).automatic)
        case "sessionRuntimeOptionsSnapshot":
            let payload = try PickySessionRuntimeOptionsSnapshotPayload(from: decoder)
            return .sessionRuntimeOptionsSnapshot(sessionId: payload.sessionId, requestId: payload.requestId, models: payload.models, allModels: payload.allModels, globalScope: payload.globalScope, projectScope: payload.projectScope, effectiveScope: payload.effectiveScope, thinkingLevels: payload.thinkingLevels, currentModel: payload.currentModel)
        case "piOAuthStatus": return .piOAuthStatus(try PickyPiOAuthStatusEvent(from: decoder))
        case "piOAuthUrlRequested": return .piOAuthUrlRequested(try PickyPiOAuthUrlRequestEvent(from: decoder))
        case "piOAuthPromptRequested": return .piOAuthPromptRequested(try PickyPiOAuthPromptRequestEvent(from: decoder))
        case "piAuthenticationReloaded": return .piAuthenticationReloaded(try PickyPiAuthenticationReloadedEvent(from: decoder))
        case "error": return .error(try PickyErrorEvent(from: decoder))
        case "ack": return .ack(try PickyAckEvent(from: decoder))
        default: return nil
        }
    }

    /// Pickle session lifecycle, journal, queue, and artifact events.
    private static func decodeSessionEvent(type: String, decoder: Decoder) throws -> PickyEvent? {
        switch type {
        case "sessionProjectionTransaction", "sessionProjectionSnapshot", "sessionProjectionBootstrapComplete":
            return Self.decodeDormantSessionProjectionEvent(type: type, decoder: decoder)
        case "sessionResourcesReloaded":
            let payload = try PickySessionResourcesReloadedPayload(from: decoder)
            return .sessionResourcesReloaded(sessionId: payload.sessionId)
        case "slashCommandsSnapshot":
            let payload = try PickySlashCommandsSnapshotPayload(from: decoder)
            return .slashCommandsSnapshot(sessionId: payload.sessionId, requestId: payload.requestId, commands: payload.commands)
        case "autocompleteCapabilitiesSnapshot":
            return .autocompleteCapabilitiesSnapshot(try PickyAutocompleteCapabilitiesSnapshot(from: decoder))
        case "autocompleteSuggestionsSnapshot":
            return .autocompleteSuggestionsSnapshot(try PickyAutocompleteSuggestionsSnapshot(from: decoder))
        case "autocompleteCompletionApplied":
            return .autocompleteCompletionApplied(try PickyAutocompleteCompletionApplied(from: decoder))
        case "rewindTargetsSnapshot":
            let payload = try PickyRewindTargetsSnapshotPayload(from: decoder)
            return .rewindTargetsSnapshot(sessionId: payload.sessionId, requestId: payload.requestId, targets: payload.targets)
        case "toolHistoryDetailResult":
            return .toolHistoryDetailResult(try PickyToolHistoryDetailResult(from: decoder))
        case "sessionDiffResult":
            return .sessionDiffResult(try PickySessionDiffResult(from: decoder))
        case "sessionRewound":
            let payload = try PickySessionRewoundPayload(from: decoder)
            return .sessionRewound(sessionId: payload.sessionId, editorText: payload.editorText, removedIds: payload.removedIds)
        case "sessionReplyWritingUpdated":
            let payload = try PickySessionReplyWritingUpdatedPayload(from: decoder)
            return .sessionReplyWritingUpdated(sessionId: payload.sessionId, writing: payload.writing)
        case "sessionToolCallPreparingUpdated":
            let payload = try PickySessionToolCallPreparingUpdatedPayload(from: decoder)
            return .sessionToolCallPreparingUpdated(sessionId: payload.sessionId, preparing: payload.preparing)
        case "sessionAutoRetryUpdated":
            let payload = try PickySessionAutoRetryUpdatedPayload(from: decoder)
            return .sessionAutoRetryUpdated(sessionId: payload.sessionId, retry: payload.retry)
        case "terminalSessionSyncOutcome":
            return .terminalSessionSyncOutcome(try PickyTerminalSessionSyncOutcome(from: decoder))
        case "pickleSessionUpdated":
            let payload = try PickyPickleSessionUpdatedPayload(from: decoder)
            return .pickleSessionUpdated(commandId: payload.commandId, session: payload.session, revision: payload.revision)
        default: return nil
        }
    }

    /// Extension UI, pointer overlay, handoff, and external entry bridge events.
    private static func decodeBridgeEvent(type: String, decoder: Decoder) throws -> PickyEvent? {
        switch type {
        case "pluginsReloaded":
            return .pluginsReloaded(try PickyPluginsReloadedEvent(from: decoder))
        case "hubStatisticsResult":
            return .hubStatisticsResult(try PickyHubStatisticsResultEvent(from: decoder))
        case "usageLimitsResult": return .usageLimitsResult(try PickyUsageLimitsResultEvent(from: decoder))
        case "packageUpdatesAvailable":
            return .packageUpdatesAvailable(try PickyPackageUpdatesAvailableEvent(from: decoder))
        case "packageConflicts":
            return .packageConflicts(try PickyPackageConflictsEvent(from: decoder))
        case "packageOperationProgress":
            return .packageOperationProgress(try PickyPackageOperationProgressEvent(from: decoder))
        case "packageOperationCompleted":
            return .packageOperationCompleted(try PickyPackageOperationCompletedEvent(from: decoder))
        case "mcpServerList":
            return .mcpServerList(try PickyMcpServerListEvent(from: decoder))
        case "mcpServerOperationCompleted":
            return .mcpServerOperationCompleted(try PickyMcpServerOperationCompletedEvent(from: decoder))
        case "extensionUiRequest":
            let payload = try PickyExtensionUiRequestPayload(from: decoder)
            return .extensionUiRequest(payload.request)
        case "pointerOverlayRequested":
            let payload = try PickyPointerOverlayRequestedPayload(from: decoder)
            return .pointerOverlayRequested(payload.request)
        case "annotationOverlayRequested":
            let payload = try PickyAnnotationOverlayRequestedPayload(from: decoder)
            return .annotationOverlayRequested(payload.request)
        case "pickleHandoffRequested":
            return .pickleHandoffRequested(try PickyPickleHandoffRequest(from: decoder))
        case "pickleBridgeRequested":
            return .pickleBridgeRequested(try PickyPickleBridgeRequest(from: decoder))
        case "externalEntryRequested":
            return .externalEntryRequested(try PickyExternalEntryRequest(from: decoder))
        case "externalEntryAccepted":
            return .externalEntryAccepted(try PickyExternalEntryAcceptedEvent(from: decoder))
        case "dockGroupsRequested":
            let payload = try PickyDockGroupsRequestedPayload(from: decoder)
            return .dockGroupsRequested(requestId: payload.requestId)
        case "pushToTalkControlRequested":
            return .pushToTalkControlRequested(try PickyPushToTalkControlRequest(from: decoder))
        case "pickySettingsRequested":
            return .pickySettingsRequested(try PickySettingsRequest(from: decoder))
        default: return nil
        }
    }
}

struct PickyPiOAuthStatusEvent: Decodable, Equatable {
    let requestId: String
    let providerId: PickyPiOAuthLoginProvider
    let configured: Bool
    let source: String?
    let label: String?

    var authStatus: PickyPiOAuthLoginAuthStatus {
        PickyPiOAuthLoginAuthStatus(configured: configured, source: source, label: label)
    }
}

struct PickyPiOAuthUrlRequestEvent: Decodable, Equatable {
    let requestId: String
    let providerId: PickyPiOAuthLoginProvider
    let url: String
    let instructions: String?
    let userCode: String?
}

enum PickyPiOAuthPromptType: String, Decodable, Equatable {
    case text
    case secret
    case select
    case manualCode = "manual_code"
}

struct PickyPiOAuthPromptOption: Decodable, Equatable {
    let id: String
    let label: String
    let description: String?
}

struct PickyPiOAuthPromptRequestEvent: Decodable, Equatable {
    let requestId: String
    let providerId: PickyPiOAuthLoginProvider
    let promptId: String
    let promptType: PickyPiOAuthPromptType
    let message: String
    let placeholder: String?
    let options: [PickyPiOAuthPromptOption]?
}

struct PickyPiAuthenticationReloadedEvent: Decodable, Equatable {
    let requestId: String
    let reloadedHandleCount: Int
}

/// A daemon session snapshot plus local decode completeness metadata.
///

struct PickyPluginsReloadedEvent: Decodable, Equatable {
    let requestId: String?
    let pickyReloaded: Bool
    let pickleReloadedCount: Int
    let pickleAbortedCount: Int
    let pickleDeferredCount: Int
    /// Sessions whose reload failed. Absent from older daemons.
    var failedCount: Int? = nil
}

/// Reply to `getHubStatistics` / `resetHubStatistics`. `snapshot` is present
/// only on success.
struct PickyHubStatisticsResultEvent: Decodable, Equatable {
    let commandId: String
    let ok: Bool
    let errorMessage: String?
    let snapshot: PickyHubStatisticsSnapshot?
}

struct PickyHelloEvent: Decodable, Equatable {
    let serverName: String
    let supportedProtocolVersions: [String]
}

struct PickyQuickReplyEvent: Decodable, Equatable {
    let contextId: String
    let text: String
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?
    let inputId: UUID?
    let didStreamNarration: Bool?

    private enum CodingKeys: String, CodingKey {
        case contextId, text, originSource, replyKind, sessionId, inputId, didStreamNarration
    }

    init(
        contextId: String,
        text: String,
        originSource: PickyQuickReplyOriginSource? = nil,
        replyKind: PickyQuickReplyKind? = nil,
        sessionId: String? = nil,
        inputId: UUID? = nil,
        didStreamNarration: Bool? = nil
    ) {
        self.contextId = contextId
        self.text = text
        self.originSource = originSource
        self.replyKind = replyKind
        self.sessionId = sessionId
        self.inputId = inputId
        self.didStreamNarration = didStreamNarration
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contextId = try c.decode(String.self, forKey: .contextId)
        text = try c.decode(String.self, forKey: .text)
        originSource = try c.decodeIfPresent(PickyQuickReplyOriginSource.self, forKey: .originSource)
        replyKind = try c.decodeIfPresent(PickyQuickReplyKind.self, forKey: .replyKind)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        if let rawInputId = try c.decodeIfPresent(String.self, forKey: .inputId) {
            inputId = UUID(uuidString: rawInputId)
        } else {
            inputId = nil
        }
        didStreamNarration = try c.decodeIfPresent(Bool.self, forKey: .didStreamNarration)
    }
}

struct PickyMainNarrationChunkEvent: Decodable, Equatable {
    let contextId: String
    let text: String
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?

    private enum CodingKeys: String, CodingKey { case contextId, text, originSource, replyKind, sessionId }
}

struct PickyErrorEvent: Decodable, Equatable {
    let code: String
    let message: String
    let commandId: String?
}

/// Positive per-command acknowledgement unicast by agentd after a command
/// handler resolves. Races against `error` in `sendAwaitingError` so callers
/// settle as soon as the daemon confirms instead of waiting out the timeout.
struct PickyAckEvent: Decodable, Equatable {
    let commandId: String
}

struct PickyPickleHandoffRequest: Decodable, Equatable {
    let requestId: String
    let context: PickyContextPacket
    let title: String
    let instructions: String
    let cwd: String
}

enum PickyExternalEntryKind: String, Codable, Equatable {
    case submitMain
    case createPickle
}

struct PickyExternalEntryRequest: Decodable, Equatable {
    let requestId: String
    let kind: PickyExternalEntryKind
    let text: String?
    let title: String?
    let instructions: String?
    let cwd: String?
}

struct PickyExternalEntryAcceptedEvent: Decodable, Equatable {
    let commandId: String
    let kind: PickyExternalEntryKind
    let contextId: String
    let sessionId: String?
    let group: String?
}

enum PickyPushToTalkControlAction: String, Codable, Equatable {
    case press
    case release
}

struct PickyPushToTalkControlRequest: Decodable, Equatable {
    let requestId: String
    let action: PickyPushToTalkControlAction
}

struct PickyTerminalSessionSyncOutcome: Decodable, Equatable {
    let sessionId: String
    let baselineFound: Bool
    let importedMessageCount: Int
    let activeLastMessageId: String?
    let baselinePiMessageId: String?
}

enum PickySlashCommandSource: String, Codable, Equatable {
    case `extension`
    case prompt
    case skill
    case builtin

    var displayName: String {
        switch self {
        case .extension: "Extension"
        case .prompt: "Prompt"
        case .skill: "Skill"
        case .builtin: "Built-in"
        }
    }
}

struct PickySlashCommand: Codable, Equatable, Identifiable {
    var id: String { "\(source.rawValue):\(name)" }
    let name: String
    let description: String?
    let source: PickySlashCommandSource
}

struct PickyAutocompleteItem: Codable, Equatable, Sendable {
    let value: String
    let label: String
    let description: String?

    init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }
}

struct PickyAutocompleteCapabilitiesSnapshot: Codable, Equatable, Sendable {
    let sessionId: String
    let requestId: String
    let generation: Int
    let triggerCharacters: [String]
}

struct PickyAutocompleteSuggestionsSnapshot: Codable, Equatable, Sendable {
    let sessionId: String
    let requestId: String
    let generation: Int
    let draftRevision: Int
    let draftFingerprint: String
    let cursorLine: Int
    let cursorCol: Int
    let prefix: String?
    let items: [PickyAutocompleteItem]
}

struct PickyAutocompleteCompletionApplied: Codable, Equatable, Sendable {
    let sessionId: String
    let requestId: String
    let generation: Int
    let draftRevision: Int
    let draftFingerprint: String
    let lines: [String]
    let cursorLine: Int
    let cursorCol: Int
}

struct PickyRewindTarget: Decodable, Equatable, Identifiable {
    var id: String { entryId }
    let entryId: String
    let text: String
    let createdAt: Date?
}

struct PickyMainAgentMessage: Codable, Equatable, Identifiable {
    enum Role: String, Codable, Equatable {
        case user, assistant
    }

    var id: String { "\(createdAt.timeIntervalSince1970)-\(role.rawValue)-\(text.hashValue)" }
    let role: Role
    let text: String
    let createdAt: Date
}

/// Snapshot of where Picky's always-on main agent currently has its Pi
/// session file and cwd. Both fields can be nil before agentd has prewarmed a
/// real Pi session, after a `/new`, or while a runtime mode switch is in
/// flight. Used by the Status → Recent conversation sub-page to expose the
/// `Copy resume command` escape hatch.
struct PickyMainAgentSessionInfo: Equatable {
    var sessionFilePath: String?
    var cwd: String?

    init(sessionFilePath: String? = nil, cwd: String? = nil) {
        self.sessionFilePath = sessionFilePath
        self.cwd = cwd
    }

    var canOpenInPi: Bool {
        guard let path = sessionFilePath?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return !path.isEmpty
    }
}

enum PickyQueueMode: String, Codable, Equatable {
    case oneAtATime = "one-at-a-time"
    case all
}

struct PickyQueueItem: Codable, Equatable {
    /// The text the runtime holds, which for a Picky submission is the built prompt envelope.
    let text: String
    /// The user's own instruction, resolved by agentd. Nil for queue items journaled before
    /// the daemon sent this field, and for anything an older daemon sends now: a
    /// `PICKY_AGENTD_ROOT` dev override can point a current app at a pre-Phase-0 agentd.
    /// Callers fall back to `text`.
    let displayText: String?
    let enqueuedAt: Date
    let id: String?
    /// Display-only screenshot count. Never a restorable attachment reference.
    let attachedImagesCount: Int?

    init(text: String, enqueuedAt: Date, id: String? = nil, attachedImagesCount: Int? = nil, displayText: String? = nil) {
        self.text = text
        self.displayText = displayText
        self.enqueuedAt = enqueuedAt
        self.id = id
        self.attachedImagesCount = attachedImagesCount
    }

    /// The text every surface shows and restores into the composer. Never the prompt envelope:
    /// agentd resolves it, and an older item without `displayText` predates envelope wrapping
    /// for that queue or was queued as raw text.
    var userFacingText: String { displayText ?? text }
}

/// A delayed-action timed message the daemon projects from the plugin's own
/// store. Picky never writes that store directly; it sends schedule/cancel
/// commands and re-reads the projection.
struct PickyScheduledMessage: Codable, Equatable, Identifiable {
    let id: String
    let text: String
    let dueAt: Date
    let createdAt: Date

    init(id: String, text: String, dueAt: Date, createdAt: Date) {
        self.id = id
        self.text = text
        self.dueAt = dueAt
        self.createdAt = createdAt
    }
}

struct PickyActivitySummary: Codable, Equatable {
    var edit: Int
    var bash: Int
    var thinking: Int
    var other: Int
    var read: Int
    var write: Int
    var todo: Int
    var subagent: Int

    static let zero = PickyActivitySummary()

    init(
        edit: Int = 0,
        bash: Int = 0,
        thinking: Int = 0,
        other: Int = 0,
        read: Int = 0,
        write: Int = 0,
        todo: Int = 0,
        subagent: Int = 0
    ) {
        self.edit = edit
        self.bash = bash
        self.thinking = thinking
        self.other = other
        self.read = read
        self.write = write
        self.todo = todo
        self.subagent = subagent
    }

    private enum CodingKeys: String, CodingKey {
        case read, bash, edit, write, todo, subagent, thinking, other
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = try container.decodeIfPresent(Int.self, forKey: .read) ?? 0
        bash = try container.decodeIfPresent(Int.self, forKey: .bash) ?? 0
        edit = try container.decodeIfPresent(Int.self, forKey: .edit) ?? 0
        write = try container.decodeIfPresent(Int.self, forKey: .write) ?? 0
        todo = try container.decodeIfPresent(Int.self, forKey: .todo) ?? 0
        subagent = try container.decodeIfPresent(Int.self, forKey: .subagent) ?? 0
        thinking = try container.decodeIfPresent(Int.self, forKey: .thinking) ?? 0
        other = try container.decodeIfPresent(Int.self, forKey: .other) ?? 0
    }
}

enum PickyTodoStatus: String, Codable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed
}

struct PickyTodoTask: Codable, Equatable, Identifiable {
    let id: String
    let content: String
    let status: PickyTodoStatus
    let activeForm: String?
    let notes: String?

    init(
        id: String,
        content: String,
        status: PickyTodoStatus,
        activeForm: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.content = content
        self.status = status
        self.activeForm = activeForm
        self.notes = notes
    }
}

struct PickyTodoState: Codable, Equatable {
    let tasks: [PickyTodoTask]
    let updatedAt: Date

    var completedCount: Int {
        tasks.count { $0.status == .completed }
    }
}

struct PickySessionLastRequest: Codable, Equatable {
    enum Source: String, Codable, Equatable {
        case steer, followUp, handoff, extensionAnswer, transcript
    }

    var source: Source
    var text: String
}

enum PickySessionStatus: String, Codable, Equatable {
    case queued, running, waiting_for_input, blocked, completed, failed, cancelled
}

enum PickyMainActivityKind: String, Codable, Equatable {
    case thinking
    case tool
}

struct PickyMainActivity: Codable, Equatable {
    let kind: PickyMainActivityKind
    let toolCallId: String?
    let toolName: String?
    let status: String?
    let argsPreview: String?
    let thinkingPreview: String?

    init(
        kind: PickyMainActivityKind,
        toolCallId: String? = nil,
        toolName: String? = nil,
        status: String? = nil,
        argsPreview: String? = nil,
        thinkingPreview: String? = nil
    ) {
        self.kind = kind
        self.toolCallId = toolCallId
        self.toolName = toolName
        self.status = status
        self.argsPreview = argsPreview
        self.thinkingPreview = thinkingPreview
    }
}

struct PickySubagentToolSummary: Codable, Equatable {
    let action: String
    let agents: [String]
}

struct PickyToolActivity: Codable, Equatable, Identifiable {
    var id: String { toolCallId }
    let toolCallId: String
    let name: String
    let status: String
    let preview: String?
    let argsPreview: String?
    let resultPreview: String?
    let resultJSONPreview: String?
    let resultPreviewTruncated: Bool?
    let resultPreviewRepaired: Bool?
    let subagentSummary: PickySubagentToolSummary?
    let startedAt: Date?
    let endedAt: Date?

    init(
        toolCallId: String,
        name: String,
        status: String,
        preview: String? = nil,
        argsPreview: String? = nil,
        resultPreview: String? = nil,
        resultJSONPreview: String? = nil,
        resultPreviewTruncated: Bool? = nil,
        resultPreviewRepaired: Bool? = nil,
        subagentSummary: PickySubagentToolSummary? = nil,
        startedAt: Date? = nil,
        endedAt: Date? = nil
    ) {
        self.toolCallId = toolCallId
        self.name = name
        self.status = status
        self.preview = preview
        self.argsPreview = argsPreview
        self.resultPreview = resultPreview
        self.resultJSONPreview = resultJSONPreview
        self.resultPreviewTruncated = resultPreviewTruncated
        self.resultPreviewRepaired = resultPreviewRepaired
        self.subagentSummary = subagentSummary
        self.startedAt = startedAt
        self.endedAt = endedAt
    }
}

struct PickyArtifact: Codable, Equatable, Identifiable {
    let id: String
    let kind: String
    let title: String
    let path: String?
    let url: URL?
    let updatedAt: Date

    init(id: String, kind: String, title: String, path: String?, url: URL?, updatedAt: Date) {
        self.id = id
        self.kind = kind
        self.title = title
        self.path = path
        self.url = url
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, path, url, updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        title = try container.decode(String.self, forKey: .title)
        path = try container.decodeIfPresent(String.self, forKey: .path)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        // Decode the URL leniently. A single artifact URL that Foundation
        // rejects (e.g. a stray backtick captured from markdown) must not
        // fail the whole session — that would blank the entire dock. Fall
        // back to percent-encoding the raw string, then to `nil`.
        url = PickyArtifact.lenientURL(from: try container.decodeIfPresent(String.self, forKey: .url))
    }

    static func lenientURL(from raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        if let url = URL(string: raw) { return url }
        let allowed = CharacterSet.urlQueryAllowed.union(CharacterSet(charactersIn: "#%"))
        if let encoded = raw.addingPercentEncoding(withAllowedCharacters: allowed),
           let url = URL(string: encoded) {
            return url
        }
        return nil
    }
}

struct PickyChangedFile: Codable, Equatable {
    let path: String
    let status: String
    let summary: String?
}
