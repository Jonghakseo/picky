//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-07-19"

/// Identifiers for Picky's built-in tools exposed to the main agent.
/// These names mirror `name:` on each `defineTool(...)` call in
/// `agentd/src/application/*-tool.ts` and must stay in sync with the daemon.
enum PickyBuiltinTool: String, Codable, CaseIterable, Hashable, Sendable {
    case startPickle = "picky_start_pickle"
    case pickleSessions = "picky_pickle_sessions"
    case steerPickle = "picky_steer_pickle"
    case abortPickle = "picky_abort_pickle"
    case screenOverlay = "picky_screen_overlay"
    case readUserGuide = "read_picky_user_guide"

    /// L10n key for the user-facing display name shown in the settings UI.
    var displayNameKey: String {
        switch self {
        case .startPickle: "settings.builtinTools.tool.startPickle.name"
        case .pickleSessions: "settings.builtinTools.tool.pickleSessions.name"
        case .steerPickle: "settings.builtinTools.tool.steerPickle.name"
        case .abortPickle: "settings.builtinTools.tool.abortPickle.name"
        case .screenOverlay: "settings.builtinTools.tool.screenOverlay.name"
        case .readUserGuide: "settings.builtinTools.tool.readUserGuide.name"
        }
    }

    /// L10n key for the short description shown under the tool name.
    var descriptionKey: String {
        switch self {
        case .startPickle: "settings.builtinTools.tool.startPickle.description"
        case .pickleSessions: "settings.builtinTools.tool.pickleSessions.description"
        case .steerPickle: "settings.builtinTools.tool.steerPickle.description"
        case .abortPickle: "settings.builtinTools.tool.abortPickle.description"
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
    var sessionId: String?
    var text: String?
    var requestId: String?
    var value: JSONValue?
    var artifactId: String?
    var title: String?
    var instructions: String?
    var cwd: String?
    var errorMessage: String?
    var capabilities: [String]?
    var sessions: [PickyAgentSession]?
    var groups: [PickyDockGroupPayload]?
    var session: PickyAgentSession?
    var delivered: Bool?
    var prompt: String?
    var enabled: Bool?
    var archived: Bool?
    var defaultCwd: String?
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel?
    var mainAgentModelPattern: String?
    var direction: PickyModelCycleDirection?
    var kind: PickyQueueClearKind?
    /// Pi message id observed when a Picky terminal overlay was opened. The daemon imports only
    /// active Pi transcript messages after this id when syncing the terminal session back.
    var baselinePiMessageId: String?
    var disabledBuiltinTools: [String]?
    var action: PickyPushToTalkControlAction?
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

    init(
        id: String = "cmd-\(UUID().uuidString)",
        type: PickyCommandType,
        context: PickyContextPacket? = nil,
        sessionId: String? = nil,
        text: String? = nil,
        requestId: String? = nil,
        value: JSONValue? = nil,
        artifactId: String? = nil,
        title: String? = nil,
        instructions: String? = nil,
        cwd: String? = nil,
        errorMessage: String? = nil,
        capabilities: [String]? = nil,
        sessions: [PickyAgentSession]? = nil,
        groups: [PickyDockGroupPayload]? = nil,
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        prompt: String? = nil,
        enabled: Bool? = nil,
        archived: Bool? = nil,
        defaultCwd: String? = nil,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mainAgentModelPattern: String? = nil,
        direction: PickyModelCycleDirection? = nil,
        kind: PickyQueueClearKind? = nil,
        baselinePiMessageId: String? = nil,
        disabledBuiltinTools: [String]? = nil,
        action: PickyPushToTalkControlAction? = nil,
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
        visualDslEnabled: Bool? = nil
    ) {
        self.id = id
        self.protocolVersion = pickyAgentProtocolVersion
        self.type = type
        self.context = context
        self.sessionId = sessionId
        self.text = text
        self.requestId = requestId
        self.value = value
        self.artifactId = artifactId
        self.title = title
        self.instructions = instructions
        self.cwd = cwd
        self.errorMessage = errorMessage
        self.capabilities = capabilities
        self.sessions = sessions
        self.groups = groups
        self.session = session
        self.delivered = delivered
        self.prompt = prompt
        self.enabled = enabled
        self.archived = archived
        self.defaultCwd = defaultCwd
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentModelPattern = mainAgentModelPattern
        self.direction = direction
        self.kind = kind
        self.baselinePiMessageId = baselinePiMessageId
        self.action = action
        self.entryId = entryId
        self.disabledBuiltinTools = disabledBuiltinTools
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
    }
}

enum PickyQueueClearKind: String, Codable, Equatable {
    case steering, followUp, all
}

enum PickyModelCycleDirection: String, Codable, Equatable {
    case forward, backward
}

enum PickyCommandType: String, Codable, Equatable {
    case routeTask
    case createTask
    case createEmptyPickleSession
    case createPickleFromHandoff
    case completePickleHandoff
    case registerAppCapabilities
    case completePickleBridgeRequest
    case completeExternalEntryRequest
    case completeDockGroupsRequest
    case controlPushToTalkFromExternal
    case completePushToTalkControlRequest
    case duplicatePickleSession
    case pinPickleSession
    case clearQueue
    case syncTerminalSession
    case setTerminalSessionTailEnabled
    case followUp
    case steer
    case abort
    case listSessions
    case listMainMessages
    case listMainAgentModels
    case setDefaultCwd
    case setMainAgentModel
    case resetMainAgent
    case abortMainAgent
    case setMainAgentThinkingLevel
    case cycleSessionThinkingLevel
    case cycleSessionModel
    case listSlashCommands
    case getAutocompleteCapabilities
    case autocompleteQuery
    case autocompleteApply
    case listRewindTargets
    case rewindSession
    case getSession
    case answerExtensionUi
    case setNotifyMainOnCompletion
    case setSessionArchived
    case deleteSession
    case notifyMainOfPickleCompletion
    case setDisabledBuiltinTools
    case setMainAgentTTSEnabled
    case reloadPlugins

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
    case mainAgentSessionInfoUpdated(sessionFilePath: String?, cwd: String?)
    case mainAgentModelsSnapshot([PickyMainAgentModelOption])
    case sessionSnapshot([PickyAgentSession])
    case sessionUpdated(PickyAgentSession)
    /// Authoritative archive-flag change signaled by agentd. Picky's session
    /// view model trusts THIS event to update its local
    /// `manuallyArchivedSessionIDs` UserDefaults; it deliberately ignores the
    /// `archived` field on plain `sessionUpdated` to avoid mid-flight
    /// unarchive flicker when an unrelated update arrives while the user has
    /// just toggled archive locally. Fired by agentd whenever
    /// `setSessionArchived` runs — from a Picky client command or tool.
    case sessionArchivedAuthoritative(sessionId: String, archived: Bool)
    case sessionResourcesReloaded(sessionId: String)
    case pluginsReloaded(PickyPluginsReloadedEvent)
    case sessionLogAppended(sessionId: String, line: String)
    case toolActivityUpdated(sessionId: String, tool: PickyToolActivity)
    case sessionTodoStateUpdated(sessionId: String, todoState: PickyTodoState?, seq: Int)
    case extensionUiRequest(PickyExtensionUiRequest)
    case artifactUpdated(sessionId: String, artifact: PickyArtifact)
    case pointerOverlayRequested(PickyPointerOverlayRequest)
    case annotationOverlayRequested(PickyAnnotationOverlayRequest)
    case pickleHandoffRequested(PickyPickleHandoffRequest)
    case pickleBridgeRequested(PickyPickleBridgeRequest)
    case externalEntryRequested(PickyExternalEntryRequest)
    case externalEntryAccepted(PickyExternalEntryAcceptedEvent)
    case dockGroupsRequested(requestId: String)
    case pushToTalkControlRequested(PickyPushToTalkControlRequest)
    case slashCommandsSnapshot(sessionId: String, requestId: String?, commands: [PickySlashCommand])
    case autocompleteCapabilitiesSnapshot(PickyAutocompleteCapabilitiesSnapshot)
    case autocompleteSuggestionsSnapshot(PickyAutocompleteSuggestionsSnapshot)
    case autocompleteCompletionApplied(PickyAutocompleteCompletionApplied)
    case rewindTargetsSnapshot(sessionId: String, requestId: String?, targets: [PickyRewindTarget])
    case sessionRewound(sessionId: String, editorText: String?, removedIds: [String])
    case sessionMessageAppended(sessionId: String, message: PickySessionMessage, seq: Int)
    /// Bulk append for terminal-sync / history-restore imports. The whole batch
    /// shares one seq so the conversation updates in a single publish instead of
    /// replaying the import message-by-message.
    case sessionMessagesImported(sessionId: String, messages: [PickySessionMessage], seq: Int)
    case sessionMessageReplaced(sessionId: String, messageId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageRemoved(sessionId: String, messageId: String, seq: Int)
    case sessionQueueUpdated(sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int)
    case sessionActivityUpdated(sessionId: String, activitySummary: PickyActivitySummary, seq: Int)
    case terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome)
    case error(PickyErrorEvent)
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
        case "mainAgentSessionInfoUpdated":
            let payload = try PickyMainAgentSessionInfoUpdatedPayload(from: decoder)
            return .mainAgentSessionInfoUpdated(sessionFilePath: payload.sessionFilePath, cwd: payload.cwd)
        case "mainAgentModelsSnapshot":
            let payload = try PickyMainAgentModelsSnapshotPayload(from: decoder)
            return .mainAgentModelsSnapshot(payload.models)
        case "error": return .error(try PickyErrorEvent(from: decoder))
        default: return nil
        }
    }

    /// Pickle session lifecycle, journal, queue, and artifact events.
    private static func decodeSessionEvent(type: String, decoder: Decoder) throws -> PickyEvent? {
        switch type {
        case "sessionSnapshot":
            let payload = try PickySessionSnapshotPayload(from: decoder)
            return .sessionSnapshot(payload.sessions)
        case "sessionUpdated":
            let payload = try PickySessionUpdatedPayload(from: decoder)
            return .sessionUpdated(payload.session)
        case "sessionArchivedAuthoritative":
            let payload = try PickySessionArchivedAuthoritativePayload(from: decoder)
            return .sessionArchivedAuthoritative(sessionId: payload.sessionId, archived: payload.archived)
        case "sessionResourcesReloaded":
            let payload = try PickySessionResourcesReloadedPayload(from: decoder)
            return .sessionResourcesReloaded(sessionId: payload.sessionId)
        case "sessionLogAppended":
            let payload = try PickySessionLogAppendedPayload(from: decoder)
            return .sessionLogAppended(sessionId: payload.sessionId, line: payload.line)
        case "toolActivityUpdated":
            let payload = try PickyToolActivityUpdatedPayload(from: decoder)
            return .toolActivityUpdated(sessionId: payload.sessionId, tool: payload.tool)
        case "sessionTodoStateUpdated":
            let payload = try PickyTodoStateUpdatedPayload(from: decoder)
            return .sessionTodoStateUpdated(sessionId: payload.sessionId, todoState: payload.todoState, seq: payload.seq)
        case "artifactUpdated":
            let payload = try PickyArtifactUpdatedPayload(from: decoder)
            return .artifactUpdated(sessionId: payload.sessionId, artifact: payload.artifact)
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
        case "sessionRewound":
            let payload = try PickySessionRewoundPayload(from: decoder)
            return .sessionRewound(sessionId: payload.sessionId, editorText: payload.editorText, removedIds: payload.removedIds)
        case "sessionMessageAppended":
            let payload = try PickySessionMessageAppendedPayload(from: decoder)
            return .sessionMessageAppended(sessionId: payload.sessionId, message: payload.message, seq: payload.seq)
        case "sessionMessagesImported":
            let payload = try PickySessionMessagesImportedPayload(from: decoder)
            return .sessionMessagesImported(sessionId: payload.sessionId, messages: payload.messages, seq: payload.seq)
        case "sessionMessageReplaced":
            let payload = try PickySessionMessageReplacedPayload(from: decoder)
            return .sessionMessageReplaced(sessionId: payload.sessionId, messageId: payload.messageId, message: payload.message, seq: payload.seq)
        case "sessionMessageRemoved":
            let payload = try PickySessionMessageRemovedPayload(from: decoder)
            return .sessionMessageRemoved(sessionId: payload.sessionId, messageId: payload.messageId, seq: payload.seq)
        case "sessionQueueUpdated":
            let payload = try PickySessionQueueUpdatedPayload(from: decoder)
            return .sessionQueueUpdated(
                sessionId: payload.sessionId,
                steering: payload.steering,
                followUp: payload.followUp,
                steeringMode: payload.steeringMode,
                followUpMode: payload.followUpMode,
                seq: payload.seq
            )
        case "sessionActivityUpdated":
            let payload = try PickySessionActivityUpdatedPayload(from: decoder)
            return .sessionActivityUpdated(sessionId: payload.sessionId, activitySummary: payload.activitySummary, seq: payload.seq)
        case "terminalSessionSyncOutcome":
            return .terminalSessionSyncOutcome(try PickyTerminalSessionSyncOutcome(from: decoder))
        default: return nil
        }
    }

    /// Extension UI, pointer overlay, handoff, and external entry bridge events.
    private static func decodeBridgeEvent(type: String, decoder: Decoder) throws -> PickyEvent? {
        switch type {
        case "pluginsReloaded":
            return .pluginsReloaded(try PickyPluginsReloadedEvent(from: decoder))
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
        default: return nil
        }
    }
}

private struct PickyMainMessagesSnapshotPayload: Decodable { let messages: [PickyMainAgentMessage] }
private struct PickyMainMessageAppendedPayload: Decodable { let message: PickyMainAgentMessage }
private struct PickyMainAgentSessionInfoUpdatedPayload: Decodable { let sessionFilePath: String?; let cwd: String? }
private struct PickyMainAgentModelsSnapshotPayload: Decodable { let models: [PickyMainAgentModelOption] }
private struct PickyMainTurnSettledPayload: Decodable { let contextId: String }
private struct PickySessionSnapshotPayload: Decodable { let sessions: [PickyAgentSession] }
private struct PickySessionUpdatedPayload: Decodable { let session: PickyAgentSession }
private struct PickySessionArchivedAuthoritativePayload: Decodable { let sessionId: String; let archived: Bool }
private struct PickySessionResourcesReloadedPayload: Decodable { let sessionId: String }

struct PickyPluginsReloadedEvent: Decodable, Equatable {
    let requestId: String?
    let pickyReloaded: Bool
    let pickleReloadedCount: Int
    let pickleAbortedCount: Int
    let pickleDeferredCount: Int
}
private struct PickySessionLogAppendedPayload: Decodable { let sessionId: String; let line: String }
private struct PickyToolActivityUpdatedPayload: Decodable { let sessionId: String; let tool: PickyToolActivity }
private struct PickyTodoStateUpdatedPayload: Decodable { let sessionId: String; let todoState: PickyTodoState?; let seq: Int }
private struct PickyExtensionUiRequestPayload: Decodable { let request: PickyExtensionUiRequest }
private struct PickyArtifactUpdatedPayload: Decodable { let sessionId: String; let artifact: PickyArtifact }
private struct PickyPointerOverlayRequestedPayload: Decodable { let request: PickyPointerOverlayRequest }
private struct PickyAnnotationOverlayRequestedPayload: Decodable { let request: PickyAnnotationOverlayRequest }
private struct PickySlashCommandsSnapshotPayload: Decodable { let sessionId: String; let requestId: String?; let commands: [PickySlashCommand] }
private struct PickyRewindTargetsSnapshotPayload: Decodable { let sessionId: String; let requestId: String?; let targets: [PickyRewindTarget] }
private struct PickySessionRewoundPayload: Decodable { let sessionId: String; let editorText: String?; let removedIds: [String] }
private struct PickySessionMessageAppendedPayload: Decodable { let sessionId: String; let message: PickySessionMessage; let seq: Int }
private struct PickySessionMessagesImportedPayload: Decodable { let sessionId: String; let messages: [PickySessionMessage]; let seq: Int }
private struct PickySessionMessageReplacedPayload: Decodable { let sessionId: String; let messageId: String; let message: PickySessionMessage; let seq: Int }
private struct PickySessionMessageRemovedPayload: Decodable { let sessionId: String; let messageId: String; let seq: Int }
private struct PickySessionQueueUpdatedPayload: Decodable { let sessionId: String; let steering: [PickyQueueItem]; let followUp: [PickyQueueItem]; let steeringMode: PickyQueueMode?; let followUpMode: PickyQueueMode?; let seq: Int }
private struct PickySessionActivityUpdatedPayload: Decodable { let sessionId: String; let activitySummary: PickyActivitySummary; let seq: Int }

enum PickyAnnotationOverlayMode: String, Codable, Equatable {
    case replace, append, clear
}

enum PickyAnnotationOverlayShape: String, Codable, Equatable {
    case rect, line, path
}

enum PickyAnnotationPathCommandType: String, Codable, Equatable {
    case move, line, cubic
}

struct PickyAnnotationPathCommand: Codable, Equatable {
    let type: PickyAnnotationPathCommandType
    let x: Double
    let y: Double
    let c1x: Double?
    let c1y: Double?
    let c2x: Double?
    let c2y: Double?

    init(
        type: PickyAnnotationPathCommandType,
        x: Double,
        y: Double,
        c1x: Double? = nil,
        c1y: Double? = nil,
        c2x: Double? = nil,
        c2y: Double? = nil
    ) {
        self.type = type
        self.x = x
        self.y = y
        self.c1x = c1x
        self.c1y = c1y
        self.c2x = c2x
        self.c2y = c2y
    }
}

struct PickyAnnotationOverlayAnnotation: Codable, Equatable, Identifiable {
    let id: String
    let shape: PickyAnnotationOverlayShape
    let x: Double?
    let y: Double?
    let w: Double?
    let h: Double?
    let x1: Double?
    let y1: Double?
    let x2: Double?
    let y2: Double?
    let commands: [PickyAnnotationPathCommand]?
    let spotlight: Bool?
    let label: String?
    let clamped: Bool?

    init(
        id: String,
        shape: PickyAnnotationOverlayShape,
        x: Double? = nil,
        y: Double? = nil,
        w: Double? = nil,
        h: Double? = nil,
        x1: Double? = nil,
        y1: Double? = nil,
        x2: Double? = nil,
        y2: Double? = nil,
        commands: [PickyAnnotationPathCommand]? = nil,
        spotlight: Bool? = nil,
        label: String? = nil,
        clamped: Bool? = nil
    ) {
        self.id = id
        self.shape = shape
        self.x = x
        self.y = y
        self.w = w
        self.h = h
        self.x1 = x1
        self.y1 = y1
        self.x2 = x2
        self.y2 = y2
        self.commands = commands
        self.spotlight = spotlight
        self.label = label
        self.clamped = clamped
    }
}

struct PickyAnnotationOverlayRequest: Codable, Equatable, Identifiable {
    let id: String
    let mode: PickyAnnotationOverlayMode
    let annotations: [PickyAnnotationOverlayAnnotation]
    let contextId: String?
    let contextGeneration: Int?
    let screenId: String?
    let screenBounds: PickyCGRect?
    let screenshotSize: PickyPointerScreenshotSize?

    init(
        id: String,
        mode: PickyAnnotationOverlayMode,
        annotations: [PickyAnnotationOverlayAnnotation],
        contextId: String? = nil,
        contextGeneration: Int? = nil,
        screenId: String? = nil,
        screenBounds: PickyCGRect? = nil,
        screenshotSize: PickyPointerScreenshotSize? = nil
    ) {
        self.id = id
        self.mode = mode
        self.annotations = annotations
        self.contextId = contextId
        self.contextGeneration = contextGeneration
        self.screenId = screenId
        self.screenBounds = screenBounds
        self.screenshotSize = screenshotSize
    }
}

struct PickyVisualNarrationSegmentIdentity: Codable, Equatable, Hashable {
    let contextId: String
    let contextGeneration: Int
    let turnToken: String
    let segmentId: String
    let ordinal: Int
}

enum PickyPreparedVisualNarrationVisual: Codable, Equatable {
    case point(PickyPointerOverlayRequest)
    case annotations(PickyAnnotationOverlayRequest)

    private enum CodingKeys: String, CodingKey { case kind, request }
    private enum Kind: String, Codable { case point, annotations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .point:
            self = .point(try container.decode(PickyPointerOverlayRequest.self, forKey: .request))
        case .annotations:
            self = .annotations(try container.decode(PickyAnnotationOverlayRequest.self, forKey: .request))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .point(let request):
            try container.encode(Kind.point, forKey: .kind)
            try container.encode(request, forKey: .request)
        case .annotations(let request):
            try container.encode(Kind.annotations, forKey: .kind)
            try container.encode(request, forKey: .request)
        }
    }
}

struct PickyVisualNarrationSegmentPreparedEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let visual: PickyPreparedVisualNarrationVisual
}

struct PickyVisualNarrationSegmentSentenceEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let index: Int
    let text: String
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?
}

struct PickyVisualNarrationSegmentCommittedEvent: Decodable, Equatable {
    let identity: PickyVisualNarrationSegmentIdentity
    let text: String?
    let sentenceCount: Int
    let originSource: PickyQuickReplyOriginSource?
    let replyKind: PickyQuickReplyKind?
    let sessionId: String?
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

/// App-owned dock group snapshot exchanged with the CLI via agentd.
struct PickyDockGroupPayload: Codable, Equatable {
    let id: String
    let name: String
    let color: Int
    let memberSessionIds: [String]
    let collapsed: Bool
}

private struct PickyDockGroupsRequestedPayload: Decodable { let requestId: String }

enum PickyPushToTalkControlAction: String, Codable, Equatable {
    case press
    case release
}

struct PickyPushToTalkControlRequest: Decodable, Equatable {
    let requestId: String
    let action: PickyPushToTalkControlAction
}

enum PickyPickleBridgeOperation: String, Decodable, Equatable {
    case listSessions
    case steer
    case abort
    case notifyMainOfPickleCompletion
}

struct PickyPickleBridgeRequest: Decodable, Equatable {
    let requestId: String
    let operation: PickyPickleBridgeOperation
    let sessionId: String?
    let text: String?
    let prompt: String?
    let cwd: String?
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

struct PickyMainAgentModelOption: Codable, Equatable, Identifiable {
    var id: String { pattern }
    let provider: String
    let modelId: String
    let displayName: String
    let pattern: String
}

/// Snapshot of where Picky's always-on main agent currently has its Pi
/// session file and cwd. Both fields can be nil before agentd has prewarmed a
/// real Pi session, after a `/new`, or while a runtime mode switch is in
/// flight. Used by the Status → Recent conversation sub-page to expose `Open in Pi` / `Copy resume
/// command` escape hatches.
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
    let text: String
    let enqueuedAt: Date
    let id: String?

    init(text: String, enqueuedAt: Date, id: String? = nil) {
        self.text = text
        self.enqueuedAt = enqueuedAt
        self.id = id
    }
}

struct PickyActivitySummary: Codable, Equatable {
    var edit: Int
    var bash: Int
    var thinking: Int
    var other: Int
    var read: Int
    var write: Int

    static let zero = PickyActivitySummary(edit: 0, bash: 0, thinking: 0, other: 0, read: 0, write: 0)

    init(edit: Int = 0, bash: Int = 0, thinking: Int = 0, other: Int = 0, read: Int = 0, write: Int = 0) {
        self.edit = edit
        self.bash = bash
        self.thinking = thinking
        self.other = other
        self.read = read
        self.write = write
    }

    private enum CodingKeys: String, CodingKey {
        case read, bash, edit, write, thinking, other
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        read = try container.decodeIfPresent(Int.self, forKey: .read) ?? 0
        bash = try container.decodeIfPresent(Int.self, forKey: .bash) ?? 0
        edit = try container.decodeIfPresent(Int.self, forKey: .edit) ?? 0
        write = try container.decodeIfPresent(Int.self, forKey: .write) ?? 0
        thinking = try container.decodeIfPresent(Int.self, forKey: .thinking) ?? 0
        other = try container.decodeIfPresent(Int.self, forKey: .other) ?? 0
    }
}

enum PickyMessageOrigin: String, Codable, Equatable {
    case user
    case mainAgent = "main_agent"
    case piExtension = "pi_extension"
}

enum PickySessionMessageKind: String, Codable, Equatable {
    case userText = "user_text"
    case agentText = "agent_text"
    case agentThinking = "agent_thinking"
    case agentQuestion = "agent_question"
    case agentError = "agent_error"
    case agentActivity = "agent_activity"
    case commandReceipt = "command_receipt"
    case system
}

enum PickyCommandReceiptStatus: String, Codable, Equatable {
    case submitted
    case failed
}

struct PickyCommandReceipt: Codable, Equatable {
    let command: String
    let status: PickyCommandReceiptStatus
    let detail: String?
}

enum PickyExtensionNotifyType: String, Codable, Equatable {
    case info
    case warning
    case error
}

struct PickyAssistantRunMetadata: Codable, Equatable {
    var model: String?
    var thinkingLevel: PickyMainAgentThinkingLevel?

    var displayText: String? {
        let parts = [model.map(Self.compactModelName), thinkingLevel?.rawValue]
            .compactMap { value -> String? in
                let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return trimmed.isEmpty ? nil : trimmed
            }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " ")
    }

    private static func compactModelName(_ rawModel: String) -> String {
        let leaf = rawModel.split(separator: "/").last.map(String.init) ?? rawModel
        for prefix in ["claude-", "openai-"] where leaf.hasPrefix(prefix) {
            return String(leaf.dropFirst(prefix.count))
        }
        return leaf
    }
}

struct PickySessionMessage: Codable, Equatable, Identifiable {
    let id: String
    let kind: PickySessionMessageKind
    let createdAt: Date
    let originatedBy: PickyMessageOrigin?
    let text: String?
    let question: PickyExtensionUiRequest?
    let cancelledAt: Date?
    let activitySnapshot: PickyActivitySummary?
    var assistantRun: PickyAssistantRunMetadata? = nil
    let errorContext: String?
    let errorMessage: String?
    var notifyType: PickyExtensionNotifyType? = nil
    var commandReceipt: PickyCommandReceipt? = nil
    /// Count of image attachments that travelled with this user_text via the
    /// structured context channel (PTT / QuickInput screenshots). Nil for
    /// messages that have no attachments or for non-user kinds.
    var attachedImagesCount: Int? = nil
}

extension PickySessionMessage {
    /// Markdown content that the user can pop open in the report viewer. Originally
    /// limited to `.agentText` (the latest agent reply), this now also covers user
    /// requests and system messages so any text-bearing bubble can be expanded into
    /// the larger markdown view from the conversation card.
    var openAsReportMarkdown: String? {
        switch kind {
        case .agentText, .userText, .system:
            let source = text ?? ""
            let reportText = notifyType == nil ? source : PickyAnsiEscapeSanitizer.stripped(source)
            let trimmed = reportText.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
    }
}

enum PickyAnsiEscapeSanitizer {
    static func stripped(_ value: String) -> String {
        var output = String.UnicodeScalarView()
        let scalars = Array(value.unicodeScalars)
        var index = 0

        while index < scalars.count {
            let scalar = scalars[index]
            guard scalar.value == 0x1B else {
                output.append(scalar)
                index += 1
                continue
            }

            guard index + 1 < scalars.count else { break }
            let next = scalars[index + 1]
            if next == "[" {
                index += 2
                while index < scalars.count {
                    let value = scalars[index].value
                    index += 1
                    if value >= 0x40 && value <= 0x7E { break }
                }
                continue
            }
            if next == "]" {
                index += 2
                while index < scalars.count {
                    if scalars[index].value == 0x07 {
                        index += 1
                        break
                    }
                    if scalars[index].value == 0x1B,
                       index + 1 < scalars.count,
                       scalars[index + 1] == "\\" {
                        index += 2
                        break
                    }
                    index += 1
                }
                continue
            }
            if next.value >= 0x40 && next.value <= 0x5F {
                index += 2
                continue
            }

            output.append(scalar)
            index += 1
        }

        return String(output)
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
    var artifacts: [PickyArtifact]
    var changedFiles: [PickyChangedFile]
    var messages: [PickySessionMessage] = []
    var queuedSteers: [PickyQueueItem] = []
    var queuedFollowUps: [PickyQueueItem] = []
    var steeringMode: PickyQueueMode = .oneAtATime
    var followUpMode: PickyQueueMode = .oneAtATime
    var activitySummary: PickyActivitySummary = .zero
    var contextUsage: PickyContextUsage? = nil
    var currentAssistantRun: PickyAssistantRunMetadata? = nil
    var pendingExtensionUiRequest: PickyExtensionUiRequest?
    var notifyMainOnCompletion: Bool? = nil
    var archived: Bool? = nil
    var pinned: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, status, cwd, piSessionFilePath, createdAt, updatedAt, lastSummary, thinkingPreview, finalAnswer, logs, tools, todoState, artifacts, changedFiles
        case messages, queuedSteers, queuedFollowUps, steeringMode, followUpMode, activitySummary, contextUsage, currentAssistantRun
        case pendingExtensionUiRequest, notifyMainOnCompletion, archived, pinned
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
        artifacts: [PickyArtifact],
        changedFiles: [PickyChangedFile],
        messages: [PickySessionMessage] = [],
        queuedSteers: [PickyQueueItem] = [],
        queuedFollowUps: [PickyQueueItem] = [],
        steeringMode: PickyQueueMode = .oneAtATime,
        followUpMode: PickyQueueMode = .oneAtATime,
        activitySummary: PickyActivitySummary = .zero,
        contextUsage: PickyContextUsage? = nil,
        currentAssistantRun: PickyAssistantRunMetadata? = nil,
        pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
        notifyMainOnCompletion: Bool? = nil,
        archived: Bool? = nil,
        pinned: Bool? = nil
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
        self.artifacts = artifacts
        self.changedFiles = changedFiles
        self.messages = messages
        self.queuedSteers = queuedSteers
        self.queuedFollowUps = queuedFollowUps
        self.steeringMode = steeringMode
        self.followUpMode = followUpMode
        self.activitySummary = activitySummary
        self.contextUsage = contextUsage
        self.currentAssistantRun = currentAssistantRun
        self.pendingExtensionUiRequest = pendingExtensionUiRequest
        self.notifyMainOnCompletion = notifyMainOnCompletion
        self.archived = archived
        self.pinned = pinned
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
        artifacts = try container.decodeIfPresent([PickyArtifact].self, forKey: .artifacts) ?? []
        changedFiles = try container.decodeIfPresent([PickyChangedFile].self, forKey: .changedFiles) ?? []
        messages = try container.decodeIfPresent([PickySessionMessage].self, forKey: .messages) ?? []
        queuedSteers = try container.decodeIfPresent([PickyQueueItem].self, forKey: .queuedSteers) ?? []
        queuedFollowUps = try container.decodeIfPresent([PickyQueueItem].self, forKey: .queuedFollowUps) ?? []
        steeringMode = try container.decodeIfPresent(PickyQueueMode.self, forKey: .steeringMode) ?? .oneAtATime
        followUpMode = try container.decodeIfPresent(PickyQueueMode.self, forKey: .followUpMode) ?? .oneAtATime
        activitySummary = try container.decodeIfPresent(PickyActivitySummary.self, forKey: .activitySummary) ?? .zero
        contextUsage = try container.decodeIfPresent(PickyContextUsage.self, forKey: .contextUsage)
        currentAssistantRun = try container.decodeIfPresent(PickyAssistantRunMetadata.self, forKey: .currentAssistantRun)
        pendingExtensionUiRequest = try container.decodeIfPresent(PickyExtensionUiRequest.self, forKey: .pendingExtensionUiRequest)
        notifyMainOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyMainOnCompletion)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
    }
}

enum PickySessionStatus: String, Codable, Equatable {
    case queued, running, waiting_for_input, blocked, completed, failed, cancelled
}

struct PickyContextUsage: Codable, Equatable {
    var tokens: Int?
    var contextWindow: Int
    var percent: Double?

    // The agentd Zod schema requires `tokens` and `percent` to be present as
    // number|null. Swift's synthesized encoder omits nil keys, which would
    // make completePickleBridgeRequest fail validation and cause
    // picky_pickle_sessions to time out, so emit explicit nulls here.
    private enum CodingKeys: String, CodingKey { case tokens, contextWindow, percent }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(percent, forKey: .percent)
    }
}

struct PickyToolActivity: Codable, Equatable, Identifiable {
    var id: String { toolCallId }
    let toolCallId: String
    let name: String
    let status: String
    let preview: String?
    let argsPreview: String?
    let resultPreview: String?
    let startedAt: Date?
    let endedAt: Date?

    init(toolCallId: String, name: String, status: String, preview: String? = nil, argsPreview: String? = nil, resultPreview: String? = nil, startedAt: Date? = nil, endedAt: Date? = nil) {
        self.toolCallId = toolCallId
        self.name = name
        self.status = status
        self.preview = preview
        self.argsPreview = argsPreview
        self.resultPreview = resultPreview
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
}

struct PickyChangedFile: Codable, Equatable {
    let path: String
    let status: String
    let summary: String?
}

struct PickyExtensionUiRequest: Codable, Equatable, Identifiable {
    let id: String
    let sessionId: String
    let method: String
    let title: String?
    let prompt: String?
    let description: String?
    let options: [String]?
    let questions: [PickyExtensionUiQuestion]?
    let createdAt: Date
    let text: String?
    let notifyType: PickyExtensionNotifyType?

    init(
        id: String,
        sessionId: String,
        method: String,
        title: String? = nil,
        prompt: String? = nil,
        description: String? = nil,
        options: [String]? = nil,
        questions: [PickyExtensionUiQuestion]? = nil,
        createdAt: Date,
        text: String? = nil,
        notifyType: PickyExtensionNotifyType? = nil
    ) {
        self.id = id
        self.sessionId = sessionId
        self.method = method
        self.title = title
        self.prompt = prompt
        self.description = description
        self.options = options
        self.questions = questions
        self.createdAt = createdAt
        self.text = text
        self.notifyType = notifyType
    }
}

struct PickyExtensionUiQuestion: Codable, Equatable, Identifiable {
    let id: String?
    let type: PickyExtensionUiQuestionType
    let prompt: String?
    let label: String?
    let options: [PickyExtensionUiQuestionOption]?
    let allowOther: Bool?
    let required: Bool?
    let placeholder: String?
    let defaultValue: JSONValue?

    enum CodingKeys: String, CodingKey {
        case id, type, prompt, label, options, allowOther, required, placeholder
        case defaultValue = "default"
    }

}

enum PickyExtensionUiQuestionType: String, Codable, Equatable {
    case radio, checkbox, text
}

struct PickyExtensionUiQuestionOption: Codable, Equatable, Identifiable {
    let value: String
    let label: String
    let description: String?

    enum CodingKeys: String, CodingKey {
        case value, label, description
    }

    var id: String { value }

    init(value: String, label: String, description: String? = nil) {
        self.value = value
        self.label = label
        self.description = description
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self.value = value
            self.label = value
            self.description = nil
            return
        }
        let object = try decoder.container(keyedBy: CodingKeys.self)
        self.value = try object.decode(String.self, forKey: .value)
        self.label = try object.decode(String.self, forKey: .label)
        self.description = try object.decodeIfPresent(String.self, forKey: .description)
    }
}

enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

private enum PickyISO8601 {
    static let fractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    static let plain: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

extension JSONDecoder {
    static func pickyAgentProtocolDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            if let date = PickyISO8601.fractional.date(from: value) ?? PickyISO8601.plain.date(from: value) {
                return date
            }
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid ISO8601 date: \(value)"))
        }
        return decoder
    }
}

extension JSONEncoder {
    static func pickyAgentProtocolEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(PickyISO8601.fractional.string(from: date))
        }
        return encoder
    }
}
