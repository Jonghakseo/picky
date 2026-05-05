//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-05-05"

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
    var mainAgentThinkingLevel: PickyMainAgentThinkingLevel?
    /// User-additional instructions for `setMainAgentExtraInstructions`. Empty string clears the
    /// daemon-side override; nil omits the field for unrelated command types.
    var mainAgentExtraInstructions: String?
    var kind: PickyQueueClearKind?

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
        mainAgentThinkingLevel: PickyMainAgentThinkingLevel? = nil,
        mainAgentExtraInstructions: String? = nil,
        kind: PickyQueueClearKind? = nil
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
        self.mainAgentThinkingLevel = mainAgentThinkingLevel
        self.mainAgentExtraInstructions = mainAgentExtraInstructions
        self.kind = kind
    }
}

enum PickyQueueClearKind: String, Codable, Equatable {
    case steering, followUp, all
}

enum PickyCommandType: String, Codable, Equatable {
    case routeTask
    case createTask
    case createEmptySideSession
    case clearQueue
    case followUp
    case steer
    case abort
    case listSessions
    case listMainMessages
    case resetMainAgent
    case abortMainAgent
    case setMainAgentThinkingLevel
    case setMainAgentExtraInstructions
    case listSlashCommands
    case getSession
    case answerExtensionUi
    case openArtifact
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
    case sessionSnapshot([PickyAgentSession])
    case sessionUpdated(PickyAgentSession)
    case sessionLogAppended(sessionId: String, line: String)
    case toolActivityUpdated(sessionId: String, tool: PickyToolActivity)
    case extensionUiRequest(PickyExtensionUiRequest)
    case artifactUpdated(sessionId: String, artifact: PickyArtifact)
    case artifactOpened(sessionId: String, artifactId: String, path: String)
    case pointerOverlayRequested(PickyPointerOverlayRequest)
    case slashCommandsSnapshot(sessionId: String, commands: [PickySlashCommand])
    case sessionMessageAppended(sessionId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageReplaced(sessionId: String, messageId: String, message: PickySessionMessage, seq: Int)
    case sessionMessageRemoved(sessionId: String, messageId: String, seq: Int)
    case sessionQueueUpdated(sessionId: String, steering: [PickyQueueItem], followUp: [PickyQueueItem], steeringMode: PickyQueueMode?, followUpMode: PickyQueueMode?, seq: Int)
    case sessionActivityUpdated(sessionId: String, activitySummary: PickyActivitySummary, seq: Int)
    case error(PickyErrorEvent)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case sessions, session, sessionId, line, tool, request, artifact, artifactId, path, contextId, text, messages, message, commands
        case messageId, seq, steering, followUp, steeringMode, followUpMode, activitySummary, originSource, replyKind, inputId
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
        case "artifactOpened":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .artifactOpened(sessionId: try c.decode(String.self, forKey: .sessionId), artifactId: try c.decode(String.self, forKey: .artifactId), path: try c.decode(String.self, forKey: .path))
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
        case "error": self = .error(try PickyErrorEvent(from: decoder))
        default: self = .unknown(type: type)
        }
    }
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

enum PickySlashCommandSource: String, Codable, Equatable {
    case `extension`
    case prompt
    case skill

    var displayName: String {
        switch self {
        case .extension: "Extension"
        case .prompt: "Prompt"
        case .skill: "Skill"
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

    static let zero = PickyActivitySummary(edit: 0, bash: 0, thinking: 0, other: 0)
}

struct PickyFinalReport: Codable, Equatable {
    let summary: String
    let body: String
    let status: Status
    let artifacts: [Artifact]

    enum Status: String, Codable, Equatable { case success, partial, blocked }
    struct Artifact: Codable, Equatable {
        let kind: String
        let title: String
        let url: URL?
    }

    init(summary: String, body: String, status: Status, artifacts: [Artifact] = []) {
        self.summary = summary
        self.body = body
        self.status = status
        self.artifacts = artifacts
    }

    enum CodingKeys: String, CodingKey { case summary, body, status, artifacts }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        summary = try container.decode(String.self, forKey: .summary)
        body = try container.decode(String.self, forKey: .body)
        status = try container.decode(Status.self, forKey: .status)
        artifacts = try container.decodeIfPresent([Artifact].self, forKey: .artifacts) ?? []
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
    case agentReport = "agent_report"
    case agentError = "agent_error"
    case agentActivity = "agent_activity"
    case system
}

struct PickySessionMessage: Codable, Equatable, Identifiable {
    let id: String
    let kind: PickySessionMessageKind
    let createdAt: Date
    let originatedBy: PickyMessageOrigin?
    let text: String?
    let question: PickyExtensionUiRequest?
    let cancelledAt: Date?
    let report: PickyFinalReport?
    let activitySnapshot: PickyActivitySummary?
    let errorContext: String?
    let errorMessage: String?
}

extension PickyFinalReport {
    var markdownReport: String {
        var lines: [String] = ["# Final report", "", "Status: `\(status.rawValue)`", ""]
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedSummary.isEmpty {
            lines.append("## Summary")
            lines.append(trimmedSummary)
            lines.append("")
        }
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedBody.isEmpty {
            lines.append("## Details")
            lines.append(trimmedBody)
            lines.append("")
        }
        if !artifacts.isEmpty {
            lines.append("## Artifacts")
            for artifact in artifacts {
                if let url = artifact.url {
                    lines.append("- [\(artifact.title)](\(url.absoluteString))")
                } else {
                    lines.append("- \(artifact.title)")
                }
            }
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

extension PickySessionMessage {
    var openAsReportMarkdown: String? {
        switch kind {
        case .agentText:
            let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : trimmed
        case .agentReport:
            return report?.markdownReport
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
    var finalReport: PickyFinalReport? = nil
    var pendingExtensionUiRequest: PickyExtensionUiRequest?
    var notifyMainOnCompletion: Bool? = nil
    var archived: Bool? = nil
    var pinned: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case id, title, status, cwd, createdAt, updatedAt, lastSummary, thinkingPreview, finalAnswer, logs, tools, artifacts, changedFiles
        case messages, queuedSteers, queuedFollowUps, steeringMode, followUpMode, activitySummary, finalReport
        case pendingExtensionUiRequest, notifyMainOnCompletion, archived, pinned
    }

    init(
        id: String,
        title: String,
        status: PickySessionStatus,
        cwd: String? = nil,
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
        finalReport: PickyFinalReport? = nil,
        pendingExtensionUiRequest: PickyExtensionUiRequest? = nil,
        notifyMainOnCompletion: Bool? = nil,
        archived: Bool? = nil,
        pinned: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.cwd = cwd
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
        self.finalReport = finalReport
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
        finalReport = try container.decodeIfPresent(PickyFinalReport.self, forKey: .finalReport)
        pendingExtensionUiRequest = try container.decodeIfPresent(PickyExtensionUiRequest.self, forKey: .pendingExtensionUiRequest)
        notifyMainOnCompletion = try container.decodeIfPresent(Bool.self, forKey: .notifyMainOnCompletion)
        archived = try container.decodeIfPresent(Bool.self, forKey: .archived)
        pinned = try container.decodeIfPresent(Bool.self, forKey: .pinned)
    }
}

enum PickySessionStatus: String, Codable, Equatable {
    case queued, running, waiting_for_input, blocked, completed, failed, cancelled
}

struct PickyToolActivity: Codable, Equatable, Identifiable {
    var id: String { toolCallId }
    let toolCallId: String
    let name: String
    let status: String
    let preview: String?
    let startedAt: Date?
    let endedAt: Date?
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
