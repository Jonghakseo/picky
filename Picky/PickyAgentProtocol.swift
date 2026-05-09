//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-05-09"

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
    var enabled: Bool?
    var archived: Bool?
    var defaultCwd: String?
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel?
    var mainAgentModelPattern: String?
    var direction: PickyModelCycleDirection?
    /// User-additional instructions for `setMainAgentExtraInstructions`. Empty string clears the
    /// daemon-side override; nil omits the field for unrelated command types.
    var mainAgentExtraInstructions: String?
    var mode: String?
    var provider: String?
    var apiKey: String?
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

    init(
        id: String = "cmd-\(UUID().uuidString)",
        type: PickyCommandType,
        context: PickyContextPacket? = nil,
        sessionId: String? = nil,
        text: String? = nil,
        requestId: String? = nil,
        value: JSONValue? = nil,
        artifactId: String? = nil,
        enabled: Bool? = nil,
        archived: Bool? = nil,
        defaultCwd: String? = nil,
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mainAgentModelPattern: String? = nil,
        direction: PickyModelCycleDirection? = nil,
        mainAgentExtraInstructions: String? = nil,
        mode: String? = nil,
        provider: String? = nil,
        apiKey: String? = nil,
        modelOrDeployment: String? = nil,
        voice: String? = nil,
        reasoningEffort: String? = nil,
        transcriptionLanguage: String? = nil,
        azure: PickyOpenAIRealtimeAzureProtocolConfig? = nil,
        inputId: UUID? = nil,
        audioBase64: String? = nil,
        playedAudioMs: Double? = nil,
        kind: PickyQueueClearKind? = nil,
        baselinePiMessageId: String? = nil
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
        self.enabled = enabled
        self.archived = archived
        self.defaultCwd = defaultCwd
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentModelPattern = mainAgentModelPattern
        self.direction = direction
        self.mainAgentExtraInstructions = mainAgentExtraInstructions
        self.mode = mode
        self.provider = provider
        self.apiKey = apiKey
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
    case createEmptySideSession
    case duplicateSession
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
    case resetMainAgent
    case abortMainAgent
    case setMainAgentThinkingLevel
    case setMainAgentExtraInstructions
    case cycleSessionThinkingLevel
    case cycleSessionModel
    case listSlashCommands
    case getSession
    case answerExtensionUi
    case setNotifyMainOnCompletion
    case setSessionArchived
}

struct PickyEventEnvelope: Decodable, Equatable {
    let id: String
    let protocolVersion: String
    let timestamp: Date
    let event: PickyEvent

    enum CodingKeys: String, CodingKey { case id, protocolVersion, timestamp, type }

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
    case mainAgentModelsSnapshot([PickyMainAgentModelOption])
    case mainRealtimeStateChanged(PickyMainRealtimeStateEvent)
    case mainRealtimeInputTranscriptDelta(inputId: UUID, delta: String)
    case mainRealtimeInputTranscriptCompleted(inputId: UUID, transcript: String)
    case mainRealtimeOutputAudioDelta(inputId: UUID?, audioBase64: String)
    case mainRealtimeOutputAudioDone(inputId: UUID?)
    case mainRealtimeOutputTranscriptDelta(inputId: UUID?, delta: String)
    case mainRealtimeOutputTranscriptCompleted(inputId: UUID?, transcript: String)
    case mainRealtimeTurnDone(PickyMainRealtimeTurnDoneEvent)
    case sessionSnapshot([PickyAgentSession])
    case sessionUpdated(PickyAgentSession)
    case sessionLogAppended(sessionId: String, line: String)
    case toolActivityUpdated(sessionId: String, tool: PickyToolActivity)
    case extensionUiRequest(PickyExtensionUiRequest)
    case artifactUpdated(sessionId: String, artifact: PickyArtifact)
    case pointerOverlayRequested(PickyPointerOverlayRequest)
    case slashCommandsSnapshot(sessionId: String, commands: [PickySlashCommand])
    case sessionMessageAppended(sessionId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageReplaced(sessionId: String, messageId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageRemoved(sessionId: String, messageId: String, seq: Int)
    case sessionQueueUpdated(sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int)
    case sessionActivityUpdated(sessionId: String, activitySummary: PickyActivitySummary, seq: Int)
    case terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome)
    case error(PickyErrorEvent)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case sessions, session, sessionId, line, tool, request, artifact, contextId, text, messages, message, commands
        case messageId, seq, steering, followUp, steeringMode, followUpMode, activitySummary, originSource, replyKind, inputId
        case models
        case state, delta, transcript, audioBase64, status, finalTranscript
        case baselineFound, importedMessageCount, activeLastMessageId, baselinePiMessageId
    }

    init(type: String, decoder: Decoder) throws {
        switch type {
        case "hello": self = .hello(try PickyHelloEvent(from: decoder))
        case "quickReply":
            self = .quickReply(try PickyQuickReplyEvent(from: decoder))
        case "mainMessagesSnapshot":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainMessagesSnapshot(try c.decode([PickyMainAgentMessage].self, forKey: .messages))
        case "mainMessageAppended":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainMessageAppended(try c.decode(PickyMainAgentMessage.self, forKey: .message))
        case "mainAgentModelsSnapshot":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainAgentModelsSnapshot(try c.decode([PickyMainAgentModelOption].self, forKey: .models))
        case "mainRealtimeStateChanged":
            self = .mainRealtimeStateChanged(try PickyMainRealtimeStateEvent(from: decoder))
        case "mainRealtimeInputTranscriptDelta":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeInputTranscriptDelta(inputId: try c.decode(UUID.self, forKey: .inputId), delta: try c.decode(String.self, forKey: .delta))
        case "mainRealtimeInputTranscriptCompleted":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeInputTranscriptCompleted(inputId: try c.decode(UUID.self, forKey: .inputId), transcript: try c.decode(String.self, forKey: .transcript))
        case "mainRealtimeOutputAudioDelta":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeOutputAudioDelta(inputId: try c.decodeIfPresent(UUID.self, forKey: .inputId), audioBase64: try c.decode(String.self, forKey: .audioBase64))
        case "mainRealtimeOutputAudioDone":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeOutputAudioDone(inputId: try c.decodeIfPresent(UUID.self, forKey: .inputId))
        case "mainRealtimeOutputTranscriptDelta":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeOutputTranscriptDelta(inputId: try c.decodeIfPresent(UUID.self, forKey: .inputId), delta: try c.decode(String.self, forKey: .delta))
        case "mainRealtimeOutputTranscriptCompleted":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .mainRealtimeOutputTranscriptCompleted(inputId: try c.decodeIfPresent(UUID.self, forKey: .inputId), transcript: try c.decode(String.self, forKey: .transcript))
        case "mainRealtimeTurnDone":
            self = .mainRealtimeTurnDone(try PickyMainRealtimeTurnDoneEvent(from: decoder))
        case "sessionSnapshot":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionSnapshot(try c.decode([PickyAgentSession].self, forKey: .sessions))
        case "sessionUpdated":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionUpdated(try c.decode(PickyAgentSession.self, forKey: .session))
        case "sessionLogAppended":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionLogAppended(sessionId: try c.decode(String.self, forKey: .sessionId), line: try c.decode(String.self, forKey: .line))
        case "toolActivityUpdated":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .toolActivityUpdated(sessionId: try c.decode(String.self, forKey: .sessionId), tool: try c.decode(PickyToolActivity.self, forKey: .tool))
        case "extensionUiRequest":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .extensionUiRequest(try c.decode(PickyExtensionUiRequest.self, forKey: .request))
        case "artifactUpdated":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .artifactUpdated(sessionId: try c.decode(String.self, forKey: .sessionId), artifact: try c.decode(PickyArtifact.self, forKey: .artifact))
        case "pointerOverlayRequested":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .pointerOverlayRequested(try c.decode(PickyPointerOverlayRequest.self, forKey: .request))
        case "slashCommandsSnapshot":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .slashCommandsSnapshot(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                commands: try c.decode([PickySlashCommand].self, forKey: .commands)
            )
        case "sessionMessageAppended":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionMessageAppended(sessionId: try c.decode(String.self, forKey: .sessionId), message: try c.decode(PickySessionMessage.self, forKey: .message), seq: try c.decode(Int.self, forKey: .seq))
        case "sessionMessageReplaced":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionMessageReplaced(sessionId: try c.decode(String.self, forKey: .sessionId), messageId: try c.decode(String.self, forKey: .messageId), message: try c.decode(PickySessionMessage.self, forKey: .message), seq: try c.decode(Int.self, forKey: .seq))
        case "sessionMessageRemoved":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionMessageRemoved(sessionId: try c.decode(String.self, forKey: .sessionId), messageId: try c.decode(String.self, forKey: .messageId), seq: try c.decode(Int.self, forKey: .seq))
        case "sessionQueueUpdated":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionQueueUpdated(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                steering: try c.decode([PickyQueueItem].self, forKey: .steering),
                followUp: try c.decode([PickyQueueItem].self, forKey: .followUp),
                steeringMode: try c.decodeIfPresent(PickyQueueMode.self, forKey: .steeringMode),
                followUpMode: try c.decodeIfPresent(PickyQueueMode.self, forKey: .followUpMode),
                seq: try c.decode(Int.self, forKey: .seq)
            )
        case "sessionActivityUpdated":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .sessionActivityUpdated(sessionId: try c.decode(String.self, forKey: .sessionId), activitySummary: try c.decode(PickyActivitySummary.self, forKey: .activitySummary), seq: try c.decode(Int.self, forKey: .seq))
        case "terminalSessionSyncOutcome":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .terminalSessionSyncOutcome(PickyTerminalSessionSyncOutcome(
                sessionId: try c.decode(String.self, forKey: .sessionId),
                baselineFound: try c.decode(Bool.self, forKey: .baselineFound),
                importedMessageCount: try c.decode(Int.self, forKey: .importedMessageCount),
                activeLastMessageId: try c.decodeIfPresent(String.self, forKey: .activeLastMessageId),
                baselinePiMessageId: try c.decodeIfPresent(String.self, forKey: .baselinePiMessageId)
            ))
        case "error": self = .error(try PickyErrorEvent(from: decoder))
        default: self = .unknown(type: type)
        }
    }
}

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

enum PickyQueueMode: String, Codable, Equatable {
    case oneAtATime = "one-at-a-time"
    case all
}

struct PickyQueueItem: Codable, Equatable {
    let text: String
    let enqueuedAt: Date
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
}

extension PickySessionMessage {
    /// Markdown content that the user can pop open in the report viewer. Originally
    /// limited to `.agentText` (the latest agent reply), this now also covers user
    /// requests and system messages so any text-bearing bubble can be expanded into
    /// the larger markdown view from the conversation card.
    var openAsReportMarkdown: String? {
        switch kind {
        case .agentText, .userText, .system:
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        default:
            return nil
        }
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
        text: String? = nil
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
