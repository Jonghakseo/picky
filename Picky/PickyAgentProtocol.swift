//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-05-09"

/// Identifiers for Picky's built-in tools exposed to the main agent.
/// These names mirror `name:` on each `defineTool(...)` call in
/// `agentd/src/application/*-tool.ts` and must stay in sync with the daemon.
enum PickyBuiltinTool: String, Codable, CaseIterable, Hashable, Sendable {
    case startPickle = "picky_start_pickle"
    case pickleSessions = "picky_pickle_sessions"
    case steerPickle = "picky_steer_pickle"
    case abortPickle = "picky_abort_pickle"
    case readUserGuide = "read_picky_user_guide"

    /// L10n key for the user-facing display name shown in the settings UI.
    var displayNameKey: String {
        switch self {
        case .startPickle: "settings.builtinTools.tool.startPickle.name"
        case .pickleSessions: "settings.builtinTools.tool.pickleSessions.name"
        case .steerPickle: "settings.builtinTools.tool.steerPickle.name"
        case .abortPickle: "settings.builtinTools.tool.abortPickle.name"
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
    var session: PickyAgentSession?
    var delivered: Bool?
    var prompt: String?
    var enabled: Bool?
    var archived: Bool?
    var defaultCwd: String?
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel?
    var mainAgentModelPattern: String?
    var direction: PickyModelCycleDirection?
    var mode: String?
    var provider: String?
    var apiKey: String?
    /// Realtime auth mode for `configureMainRealtimeAuth`. `apiKey` (default when
    /// omitted) uses the Platform API key in `apiKey`. `codexOAuth` tells the
    /// daemon to authenticate with the signed-in ChatGPT subscription token from
    /// pi AuthStorage (`openai-codex` provider).
    var authMode: String?
    var modelOrDeployment: String?
    var voice: String?
    var reasoningEffort: String?
    var transcriptionLanguage: String?
    var azure: PickyOpenAIRealtimeAzureProtocolConfig?
    var inputId: UUID?
    var audioBase64: String?
    var playedAudioMs: Double?
    var kind: PickyQueueClearKind?
    /// Pi message id observed when a Picky terminal overlay was opened. The daemon imports only
    /// active Pi transcript messages after this id when syncing the terminal session back.
    var baselinePiMessageId: String?
    var disabledBuiltinTools: [String]?
    /// Identifies a single Realtime transcription stream (PTT cycle). Set on
    /// every `beginTranscriptionStream` / `appendTranscriptionAudio` /
    /// `endTranscriptionStream` / `cancelTranscriptionStream` envelope.
    var streamId: String?
    var language: String?
    var model: String?
    var keyterms: [String]?
    var action: PickyPushToTalkControlAction?

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
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        prompt: String? = nil,
        enabled: Bool? = nil,
        archived: Bool? = nil,
        defaultCwd: String? = nil,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mainAgentModelPattern: String? = nil,
        direction: PickyModelCycleDirection? = nil,
        mode: String? = nil,
        provider: String? = nil,
        apiKey: String? = nil,
        authMode: String? = nil,
        modelOrDeployment: String? = nil,
        voice: String? = nil,
        reasoningEffort: String? = nil,
        transcriptionLanguage: String? = nil,
        azure: PickyOpenAIRealtimeAzureProtocolConfig? = nil,
        inputId: UUID? = nil,
        audioBase64: String? = nil,
        playedAudioMs: Double? = nil,
        kind: PickyQueueClearKind? = nil,
        baselinePiMessageId: String? = nil,
        disabledBuiltinTools: [String]? = nil,
        streamId: String? = nil,
        language: String? = nil,
        model: String? = nil,
        keyterms: [String]? = nil,
        action: PickyPushToTalkControlAction? = nil
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
        self.session = session
        self.delivered = delivered
        self.prompt = prompt
        self.enabled = enabled
        self.archived = archived
        self.defaultCwd = defaultCwd
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentModelPattern = mainAgentModelPattern
        self.direction = direction
        self.mode = mode
        self.provider = provider
        self.apiKey = apiKey
        self.authMode = authMode
        self.modelOrDeployment = modelOrDeployment
        self.voice = voice
        self.reasoningEffort = reasoningEffort
        self.transcriptionLanguage = transcriptionLanguage
        self.azure = azure
        self.inputId = inputId
        self.audioBase64 = audioBase64
        self.playedAudioMs = playedAudioMs
        self.kind = kind
        self.baselinePiMessageId = baselinePiMessageId
        self.streamId = streamId
        self.language = language
        self.model = model
        self.keyterms = keyterms
        self.action = action
        self.disabledBuiltinTools = disabledBuiltinTools
    }
}

struct PickyOpenAIRealtimeAzureProtocolConfig: Codable, Equatable {
    var resourceEndpoint: String
    var apiVersion: String?
    var apiShape: String
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
    case controlPushToTalkFromExternal
    case completePushToTalkControlRequest
    case duplicatePickleSession
    case pinPickleSession
    case clearQueue
    case syncTerminalSession
    case followUp
    case steer
    case abort
    case listSessions
    case listMainMessages
    case listMainAgentModels
    case setDefaultCwd
    case setMainAgentModel
    case setMainAgentRuntimeMode
    case configureMainRealtimeAuth
    case beginMainRealtimeVoiceTurn
    case appendMainRealtimeInputAudio
    case commitMainRealtimeVoiceTurn
    case cancelMainRealtimeVoiceTurn
    case beginTranscriptionStream
    case appendTranscriptionAudio
    case endTranscriptionStream
    case cancelTranscriptionStream
    case resetMainAgent
    case abortMainAgent
    case setMainAgentThinkingLevel
    case cycleSessionThinkingLevel
    case cycleSessionModel
    case listSlashCommands
    case getSession
    case answerExtensionUi
    case setNotifyMainOnCompletion
    case setSessionArchived
    case notifyMainOfPickleCompletion
    case setDisabledBuiltinTools
    case setMainAgentNarrationEnabled

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
    case mainMessagesSnapshot([PickyMainAgentMessage])
    case mainMessageAppended(PickyMainAgentMessage)
    case mainAgentSessionInfoUpdated(sessionFilePath: String?, cwd: String?)
    case mainAgentModelsSnapshot([PickyMainAgentModelOption])
    case mainRealtimeStateChanged(PickyMainRealtimeStateEvent)
    case mainRealtimeInputTranscriptDelta(inputId: UUID, delta: String)
    case mainRealtimeInputTranscriptCompleted(inputId: UUID, transcript: String)
    case mainRealtimeOutputAudioDelta(inputId: UUID?, audioBase64: String)
    case mainRealtimeOutputAudioDone(inputId: UUID?)
    case mainRealtimeOutputTranscriptDelta(inputId: UUID?, delta: String)
    case mainRealtimeOutputTranscriptCompleted(inputId: UUID?, transcript: String)
    case mainRealtimeTurnDone(PickyMainRealtimeTurnDoneEvent)
    case transcriptionStreamStarted(streamId: String)
    case transcriptionDelta(streamId: String, delta: String)
    case transcriptionCompleted(streamId: String, transcript: String)
    case transcriptionStreamFailed(streamId: String, message: String)
    case transcriptionStreamClosed(streamId: String)
    case sessionSnapshot([PickyAgentSession])
    case sessionUpdated(PickyAgentSession)
    /// Authoritative archive-flag change signaled by agentd. Picky's session
    /// view model trusts THIS event to update its local
    /// `manuallyArchivedSessionIDs` UserDefaults; it deliberately ignores the
    /// `archived` field on plain `sessionUpdated` to avoid mid-flight
    /// unarchive flicker when an unrelated update arrives while the user has
    /// just toggled archive locally. Fired by agentd whenever
    /// `setSessionArchived` runs — from a Picky client command, from the
    /// `picky_unarchive_pickle` realtime tool, etc.
    case sessionArchivedAuthoritative(sessionId: String, archived: Bool)
    case sessionResourcesReloaded(sessionId: String)
    case sessionLogAppended(sessionId: String, line: String)
    case toolActivityUpdated(sessionId: String, tool: PickyToolActivity)
    case extensionUiRequest(PickyExtensionUiRequest)
    case artifactUpdated(sessionId: String, artifact: PickyArtifact)
    case pointerOverlayRequested(PickyPointerOverlayRequest)
    case pickleHandoffRequested(PickyPickleHandoffRequest)
    case narrateProgressRequested(PickyNarrateProgressRequest)
    case pickleBridgeRequested(PickyPickleBridgeRequest)
    case externalEntryRequested(PickyExternalEntryRequest)
    case pushToTalkControlRequested(PickyPushToTalkControlRequest)
    case slashCommandsSnapshot(sessionId: String, requestId: String?, commands: [PickySlashCommand])
    case sessionMessageAppended(sessionId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageReplaced(sessionId: String, messageId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageRemoved(sessionId: String, messageId: String, seq: Int)
    case sessionQueueUpdated(sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int)
    case sessionActivityUpdated(sessionId: String, activitySummary: PickyActivitySummary, seq: Int)
    case terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome)
    case error(PickyErrorEvent)
    case unknown(type: String)


    init(type: String, decoder: Decoder) throws {
        switch type {
        case "hello": self = .hello(try PickyHelloEvent(from: decoder))
        case "quickReply":
            self = .quickReply(try PickyQuickReplyEvent(from: decoder))
        case "mainMessagesSnapshot":
            let payload = try PickyMainMessagesSnapshotPayload(from: decoder)
            self = .mainMessagesSnapshot(payload.messages)
        case "mainMessageAppended":
            let payload = try PickyMainMessageAppendedPayload(from: decoder)
            self = .mainMessageAppended(payload.message)
        case "mainAgentSessionInfoUpdated":
            let payload = try PickyMainAgentSessionInfoUpdatedPayload(from: decoder)
            self = .mainAgentSessionInfoUpdated(sessionFilePath: payload.sessionFilePath, cwd: payload.cwd)
        case "mainAgentModelsSnapshot":
            let payload = try PickyMainAgentModelsSnapshotPayload(from: decoder)
            self = .mainAgentModelsSnapshot(payload.models)
        case "mainRealtimeStateChanged":
            self = .mainRealtimeStateChanged(try PickyMainRealtimeStateEvent(from: decoder))
        case "mainRealtimeInputTranscriptDelta":
            let payload = try PickyMainRealtimeInputTranscriptDeltaPayload(from: decoder)
            self = .mainRealtimeInputTranscriptDelta(inputId: payload.inputId, delta: payload.delta)
        case "mainRealtimeInputTranscriptCompleted":
            let payload = try PickyMainRealtimeInputTranscriptCompletedPayload(from: decoder)
            self = .mainRealtimeInputTranscriptCompleted(inputId: payload.inputId, transcript: payload.transcript)
        case "mainRealtimeOutputAudioDelta":
            let payload = try PickyMainRealtimeOutputAudioDeltaPayload(from: decoder)
            self = .mainRealtimeOutputAudioDelta(inputId: payload.inputId, audioBase64: payload.audioBase64)
        case "mainRealtimeOutputAudioDone":
            let payload = try PickyMainRealtimeOutputAudioDonePayload(from: decoder)
            self = .mainRealtimeOutputAudioDone(inputId: payload.inputId)
        case "mainRealtimeOutputTranscriptDelta":
            let payload = try PickyMainRealtimeOutputTranscriptDeltaPayload(from: decoder)
            self = .mainRealtimeOutputTranscriptDelta(inputId: payload.inputId, delta: payload.delta)
        case "mainRealtimeOutputTranscriptCompleted":
            let payload = try PickyMainRealtimeOutputTranscriptCompletedPayload(from: decoder)
            self = .mainRealtimeOutputTranscriptCompleted(inputId: payload.inputId, transcript: payload.transcript)
        case "mainRealtimeTurnDone":
            self = .mainRealtimeTurnDone(try PickyMainRealtimeTurnDoneEvent(from: decoder))
        case "transcriptionStreamStarted":
            let payload = try PickyTranscriptionStreamIdPayload(from: decoder)
            self = .transcriptionStreamStarted(streamId: payload.streamId)
        case "transcriptionDelta":
            let payload = try PickyTranscriptionDeltaPayload(from: decoder)
            self = .transcriptionDelta(streamId: payload.streamId, delta: payload.delta)
        case "transcriptionCompleted":
            let payload = try PickyTranscriptionCompletedPayload(from: decoder)
            self = .transcriptionCompleted(streamId: payload.streamId, transcript: payload.transcript)
        case "transcriptionStreamFailed":
            let payload = try PickyTranscriptionFailedPayload(from: decoder)
            self = .transcriptionStreamFailed(streamId: payload.streamId, message: payload.message)
        case "transcriptionStreamClosed":
            let payload = try PickyTranscriptionStreamIdPayload(from: decoder)
            self = .transcriptionStreamClosed(streamId: payload.streamId)
        case "sessionSnapshot":
            let payload = try PickySessionSnapshotPayload(from: decoder)
            self = .sessionSnapshot(payload.sessions)
        case "sessionUpdated":
            let payload = try PickySessionUpdatedPayload(from: decoder)
            self = .sessionUpdated(payload.session)
        case "sessionArchivedAuthoritative":
            let payload = try PickySessionArchivedAuthoritativePayload(from: decoder)
            self = .sessionArchivedAuthoritative(sessionId: payload.sessionId, archived: payload.archived)
        case "sessionResourcesReloaded":
            let payload = try PickySessionResourcesReloadedPayload(from: decoder)
            self = .sessionResourcesReloaded(sessionId: payload.sessionId)
        case "sessionLogAppended":
            let payload = try PickySessionLogAppendedPayload(from: decoder)
            self = .sessionLogAppended(sessionId: payload.sessionId, line: payload.line)
        case "toolActivityUpdated":
            let payload = try PickyToolActivityUpdatedPayload(from: decoder)
            self = .toolActivityUpdated(sessionId: payload.sessionId, tool: payload.tool)
        case "extensionUiRequest":
            let payload = try PickyExtensionUiRequestPayload(from: decoder)
            self = .extensionUiRequest(payload.request)
        case "artifactUpdated":
            let payload = try PickyArtifactUpdatedPayload(from: decoder)
            self = .artifactUpdated(sessionId: payload.sessionId, artifact: payload.artifact)
        case "pointerOverlayRequested":
            let payload = try PickyPointerOverlayRequestedPayload(from: decoder)
            self = .pointerOverlayRequested(payload.request)
        case "narrateProgressRequested":
            self = .narrateProgressRequested(try PickyNarrateProgressRequest(from: decoder))
        case "pickleHandoffRequested":
            self = .pickleHandoffRequested(try PickyPickleHandoffRequest(from: decoder))
        case "pickleBridgeRequested":
            self = .pickleBridgeRequested(try PickyPickleBridgeRequest(from: decoder))
        case "externalEntryRequested":
            self = .externalEntryRequested(try PickyExternalEntryRequest(from: decoder))
        case "pushToTalkControlRequested":
            self = .pushToTalkControlRequested(try PickyPushToTalkControlRequest(from: decoder))
        case "slashCommandsSnapshot":
            let payload = try PickySlashCommandsSnapshotPayload(from: decoder)
            self = .slashCommandsSnapshot(sessionId: payload.sessionId, requestId: payload.requestId, commands: payload.commands)
        case "sessionMessageAppended":
            let payload = try PickySessionMessageAppendedPayload(from: decoder)
            self = .sessionMessageAppended(sessionId: payload.sessionId, message: payload.message, seq: payload.seq)
        case "sessionMessageReplaced":
            let payload = try PickySessionMessageReplacedPayload(from: decoder)
            self = .sessionMessageReplaced(sessionId: payload.sessionId, messageId: payload.messageId, message: payload.message, seq: payload.seq)
        case "sessionMessageRemoved":
            let payload = try PickySessionMessageRemovedPayload(from: decoder)
            self = .sessionMessageRemoved(sessionId: payload.sessionId, messageId: payload.messageId, seq: payload.seq)
        case "sessionQueueUpdated":
            let payload = try PickySessionQueueUpdatedPayload(from: decoder)
            self = .sessionQueueUpdated(
                sessionId: payload.sessionId,
                steering: payload.steering,
                followUp: payload.followUp,
                steeringMode: payload.steeringMode,
                followUpMode: payload.followUpMode,
                seq: payload.seq
            )
        case "sessionActivityUpdated":
            let payload = try PickySessionActivityUpdatedPayload(from: decoder)
            self = .sessionActivityUpdated(sessionId: payload.sessionId, activitySummary: payload.activitySummary, seq: payload.seq)
        case "terminalSessionSyncOutcome":
            self = .terminalSessionSyncOutcome(try PickyTerminalSessionSyncOutcome(from: decoder))
        case "error": self = .error(try PickyErrorEvent(from: decoder))
        default: self = .unknown(type: type)
        }
    }
}

private struct PickyMainMessagesSnapshotPayload: Decodable { let messages: [PickyMainAgentMessage] }
private struct PickyMainMessageAppendedPayload: Decodable { let message: PickyMainAgentMessage }
private struct PickyMainAgentSessionInfoUpdatedPayload: Decodable { let sessionFilePath: String?; let cwd: String? }
private struct PickyMainAgentModelsSnapshotPayload: Decodable { let models: [PickyMainAgentModelOption] }
private struct PickyMainRealtimeInputTranscriptDeltaPayload: Decodable { let inputId: UUID; let delta: String }
private struct PickyMainRealtimeInputTranscriptCompletedPayload: Decodable { let inputId: UUID; let transcript: String }
private struct PickyMainRealtimeOutputAudioDeltaPayload: Decodable { let inputId: UUID?; let audioBase64: String }
private struct PickyMainRealtimeOutputAudioDonePayload: Decodable { let inputId: UUID? }
private struct PickyMainRealtimeOutputTranscriptDeltaPayload: Decodable { let inputId: UUID?; let delta: String }
private struct PickyMainRealtimeOutputTranscriptCompletedPayload: Decodable { let inputId: UUID?; let transcript: String }
private struct PickyTranscriptionStreamIdPayload: Decodable { let streamId: String }
private struct PickyTranscriptionDeltaPayload: Decodable { let streamId: String; let delta: String }
private struct PickyTranscriptionCompletedPayload: Decodable { let streamId: String; let transcript: String }
private struct PickyTranscriptionFailedPayload: Decodable { let streamId: String; let message: String }
private struct PickySessionSnapshotPayload: Decodable { let sessions: [PickyAgentSession] }
private struct PickySessionUpdatedPayload: Decodable { let session: PickyAgentSession }
private struct PickySessionArchivedAuthoritativePayload: Decodable { let sessionId: String; let archived: Bool }
private struct PickySessionResourcesReloadedPayload: Decodable { let sessionId: String }
private struct PickySessionLogAppendedPayload: Decodable { let sessionId: String; let line: String }
private struct PickyToolActivityUpdatedPayload: Decodable { let sessionId: String; let tool: PickyToolActivity }
private struct PickyExtensionUiRequestPayload: Decodable { let request: PickyExtensionUiRequest }
private struct PickyArtifactUpdatedPayload: Decodable { let sessionId: String; let artifact: PickyArtifact }
private struct PickyPointerOverlayRequestedPayload: Decodable { let request: PickyPointerOverlayRequest }
private struct PickySlashCommandsSnapshotPayload: Decodable { let sessionId: String; let requestId: String?; let commands: [PickySlashCommand] }
private struct PickySessionMessageAppendedPayload: Decodable { let sessionId: String; let message: PickySessionMessage; let seq: Int }
private struct PickySessionMessageReplacedPayload: Decodable { let sessionId: String; let messageId: String; let message: PickySessionMessage; let seq: Int }
private struct PickySessionMessageRemovedPayload: Decodable { let sessionId: String; let messageId: String; let seq: Int }
private struct PickySessionQueueUpdatedPayload: Decodable { let sessionId: String; let steering: [PickyQueueItem]; let followUp: [PickyQueueItem]; let steeringMode: PickyQueueMode?; let followUpMode: PickyQueueMode?; let seq: Int }
private struct PickySessionActivityUpdatedPayload: Decodable { let sessionId: String; let activitySummary: PickyActivitySummary; let seq: Int }

enum PickyMainRealtimeState: String, Codable, Equatable {
    case connecting, ready, listening, thinking, speaking, failed
}

struct PickyMainRealtimeStateEvent: Decodable, Equatable {
    let state: PickyMainRealtimeState
    let message: String?
}

enum PickyMainRealtimeTurnStatus: String, Codable, Equatable {
    case completed, cancelled, failed, incomplete
}

struct PickyMainRealtimeTurnDoneEvent: Decodable, Equatable {
    let inputId: UUID?
    let status: PickyMainRealtimeTurnStatus
    let finalTranscript: String?
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

    private enum CodingKeys: String, CodingKey {
        case contextId, text, originSource, replyKind, sessionId, inputId
    }

    init(
        contextId: String,
        text: String,
        originSource: PickyQuickReplyOriginSource? = nil,
        replyKind: PickyQuickReplyKind? = nil,
        sessionId: String? = nil,
        inputId: UUID? = nil
    ) {
        self.contextId = contextId
        self.text = text
        self.originSource = originSource
        self.replyKind = replyKind
        self.sessionId = sessionId
        self.inputId = inputId
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
    }
}

struct PickyErrorEvent: Decodable, Equatable {
    let code: String
    let message: String
    let commandId: String?
}

struct PickyNarrateProgressRequest: Decodable, Equatable {
    let text: String
    let sessionId: String?
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
/// flight. Used by the Messages tab to expose `Open in Pi` / `Copy resume
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
    case system
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
        case id, title, status, cwd, piSessionFilePath, createdAt, updatedAt, lastSummary, thinkingPreview, finalAnswer, logs, tools, artifacts, changedFiles
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
