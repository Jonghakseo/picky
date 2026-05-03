//
//  PickyAgentProtocol.swift
//  Picky
//
//  Codable app-daemon protocol models shared with picky-agentd contract fixtures.
//

import Foundation

let pickyAgentProtocolVersion = "2026-05-01"

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
        archived: Bool? = nil
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
    }
}

enum PickyCommandType: String, Codable, Equatable {
    case routeTask
    case createTask
    case followUp
    case steer
    case abort
    case listSessions
    case listMainMessages
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
    case error(PickyErrorEvent)
    case unknown(type: String)

    private enum CodingKeys: String, CodingKey {
        case sessions, session, sessionId, line, tool, request, artifact, artifactId, path, contextId, text, messages, message
    }

    init(type: String, decoder: Decoder) throws {
        switch type {
        case "hello": self = .hello(try PickyHelloEvent(from: decoder))
        case "quickReply":
            let c = try decoder.container(keyedBy: CodingKeys.self)
            self = .quickReply(PickyQuickReplyEvent(contextId: try c.decode(String.self, forKey: .contextId), text: try c.decode(String.self, forKey: .text)))
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
}

struct PickyErrorEvent: Decodable, Equatable {
    let code: String
    let message: String
    let commandId: String?
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

struct PickyAgentSession: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    var status: PickySessionStatus
    var cwd: String?
    let createdAt: Date
    var updatedAt: Date
    var lastSummary: String?
    var finalAnswer: String? = nil
    var logs: [String]
    var tools: [PickyToolActivity]
    var artifacts: [PickyArtifact]
    var changedFiles: [PickyChangedFile]
    var pendingExtensionUiRequest: PickyExtensionUiRequest?
    var notifyMainOnCompletion: Bool? = nil
    var archived: Bool? = nil
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
