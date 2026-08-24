//
//  PickySessionProjectionProtocol.swift
//  Picky
//
//  Dormant session projection v2 protocol codecs.
//

import Foundation

/// A field-level projection patch update. Absent keys leave existing state
/// unchanged; an explicit JSON null clears nullable fields; values replace it.
enum FieldUpdate<Value: Equatable>: Equatable {
    case unchanged
    case clear
    case set(Value)

    static func decode<K: CodingKey>(
        from container: KeyedDecodingContainer<K>,
        forKey key: K,
        allowsClear: Bool
    ) throws -> FieldUpdate<Value> where Value: Decodable {
        guard container.contains(key) else { return .unchanged }
        if try container.decodeNil(forKey: key) {
            guard allowsClear else {
                throw DecodingError.dataCorruptedError(
                    forKey: key,
                    in: container,
                    debugDescription: "\(key.stringValue) does not allow null"
                )
            }
            return .clear
        }
        return .set(try container.decode(Value.self, forKey: key))
    }
}

/// Dormant v2 scalar metadata patch. This mirrors
/// `PickySessionMetaPatchSchema`; collection fields have their own mutations.
struct PickySessionMetaPatch: Decodable, Equatable {
    let id: FieldUpdate<String>
    let title: FieldUpdate<String>
    let status: FieldUpdate<PickySessionStatus>
    let cwd: FieldUpdate<String>
    let piSessionFilePath: FieldUpdate<String>
    let createdAt: FieldUpdate<Date>
    let updatedAt: FieldUpdate<Date>
    let lastSummary: FieldUpdate<String>
    let thinkingPreview: FieldUpdate<String>
    let messageJournalAvailable: FieldUpdate<Bool>
    let contextUsage: FieldUpdate<PickyContextUsage>
    let currentAssistantRun: FieldUpdate<PickyAssistantRunMetadata>
    let notifyMainOnCompletion: FieldUpdate<Bool>
    let archived: FieldUpdate<Bool>
    let archivedAt: FieldUpdate<Date>
    let pinned: FieldUpdate<Bool>

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, status, cwd, piSessionFilePath, createdAt, updatedAt, lastSummary
        case thinkingPreview, messageJournalAvailable, contextUsage, currentAssistantRun
        case notifyMainOnCompletion, archived, archivedAt, pinned
    }

    init(from decoder: Decoder) throws {
        let allKeys = try decoder.container(keyedBy: PickyProjectionCodingKey.self).allKeys
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let unknownKeys = allKeys.map(\.stringValue).filter { !knownKeys.contains($0) }
        guard unknownKeys.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unknown meta patch keys: \(unknownKeys.sorted().joined(separator: ", "))"
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try FieldUpdate.decode(from: container, forKey: .id, allowsClear: false)
        title = try FieldUpdate.decode(from: container, forKey: .title, allowsClear: false)
        status = try FieldUpdate.decode(from: container, forKey: .status, allowsClear: false)
        cwd = try FieldUpdate.decode(from: container, forKey: .cwd, allowsClear: true)
        piSessionFilePath = try FieldUpdate.decode(from: container, forKey: .piSessionFilePath, allowsClear: true)
        createdAt = try FieldUpdate.decode(from: container, forKey: .createdAt, allowsClear: false)
        updatedAt = try FieldUpdate.decode(from: container, forKey: .updatedAt, allowsClear: false)
        lastSummary = try FieldUpdate.decode(from: container, forKey: .lastSummary, allowsClear: true)
        thinkingPreview = try FieldUpdate.decode(from: container, forKey: .thinkingPreview, allowsClear: true)
        messageJournalAvailable = try FieldUpdate.decode(from: container, forKey: .messageJournalAvailable, allowsClear: true)
        contextUsage = try FieldUpdate.decode(from: container, forKey: .contextUsage, allowsClear: true)
        currentAssistantRun = try FieldUpdate.decode(from: container, forKey: .currentAssistantRun, allowsClear: true)
        notifyMainOnCompletion = try FieldUpdate.decode(from: container, forKey: .notifyMainOnCompletion, allowsClear: true)
        archived = try FieldUpdate.decode(from: container, forKey: .archived, allowsClear: true)
        archivedAt = try FieldUpdate.decode(from: container, forKey: .archivedAt, allowsClear: true)
        pinned = try FieldUpdate.decode(from: container, forKey: .pinned, allowsClear: true)
    }
}

/// All v2 mutation variants. Unknown variant discriminators deliberately throw;
/// the containing transaction is then discarded as `.unknown` by `PickyEvent`.
enum PickySessionProjectionMutation: Decodable, Equatable {
    case metaPatch(PickySessionMetaPatch)
    case messageAppend(PickySessionMessage)
    case messageReplace(messageId: String, message: PickySessionMessage)
    case messageRemove(messageId: String)
    case messagesImport([PickySessionMessage])
    case logAppend(line: String)
    case toolUpsert(PickyToolActivity)
    case todoSet(PickyTodoState?)
    case subagentRunsSet([PickySubagentRun])
    case artifactUpsert(PickyArtifact)
    case changedFilesSet([PickyChangedFile])
    case queueSet(queuedSteers: [PickyQueueItem], queuedFollowUps: [PickyQueueItem], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode)
    case activitySet(PickyActivitySummary)
    case finalAnswerSet(String?)
    case extensionUiRequestSet(PickyExtensionUiRequest?)

    var type: String {
        switch self {
        case .metaPatch: "metaPatch"
        case .messageAppend: "messageAppend"
        case .messageReplace: "messageReplace"
        case .messageRemove: "messageRemove"
        case .messagesImport: "messagesImport"
        case .logAppend: "logAppend"
        case .toolUpsert: "toolUpsert"
        case .todoSet: "todoSet"
        case .subagentRunsSet: "subagentRunsSet"
        case .artifactUpsert: "artifactUpsert"
        case .changedFilesSet: "changedFilesSet"
        case .queueSet: "queueSet"
        case .activitySet: "activitySet"
        case .finalAnswerSet: "finalAnswerSet"
        case .extensionUiRequestSet: "extensionUiRequestSet"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, patch, message, messageId, messages, line, tool, todoState, runs, artifact
        case changedFiles, queuedSteers, queuedFollowUps, steeringMode, followUpMode, activitySummary
        case finalAnswer, request
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "metaPatch": self = .metaPatch(try container.decode(PickySessionMetaPatch.self, forKey: .patch))
        case "messageAppend": self = .messageAppend(try container.decode(PickySessionMessage.self, forKey: .message))
        case "messageReplace":
            let messageID = try container.decode(String.self, forKey: .messageId)
            let message = try container.decode(PickySessionMessage.self, forKey: .message)
            guard messageID == message.id else {
                throw DecodingError.dataCorruptedError(forKey: .messageId, in: container, debugDescription: "messageId must match message.id")
            }
            self = .messageReplace(messageId: messageID, message: message)
        case "messageRemove": self = .messageRemove(messageId: try container.decode(String.self, forKey: .messageId))
        case "messagesImport": self = .messagesImport(try container.decode([PickySessionMessage].self, forKey: .messages))
        case "logAppend": self = .logAppend(line: try container.decode(String.self, forKey: .line))
        case "toolUpsert": self = .toolUpsert(try container.decode(PickyToolActivity.self, forKey: .tool))
        case "todoSet":
            if try container.decodeNil(forKey: .todoState) {
                self = .todoSet(nil)
            } else {
                self = .todoSet(try container.decode(PickyTodoState.self, forKey: .todoState))
            }
        case "subagentRunsSet": self = .subagentRunsSet(try container.decode([PickySubagentRun].self, forKey: .runs))
        case "artifactUpsert": self = .artifactUpsert(try container.decode(PickyArtifact.self, forKey: .artifact))
        case "changedFilesSet": self = .changedFilesSet(try container.decode([PickyChangedFile].self, forKey: .changedFiles))
        case "queueSet":
            self = .queueSet(
                queuedSteers: try container.decode([PickyQueueItem].self, forKey: .queuedSteers),
                queuedFollowUps: try container.decode([PickyQueueItem].self, forKey: .queuedFollowUps),
                steeringMode: try container.decode(PickyQueueMode.self, forKey: .steeringMode),
                followUpMode: try container.decode(PickyQueueMode.self, forKey: .followUpMode)
            )
        case "activitySet": self = .activitySet(try container.decode(PickyActivitySummary.self, forKey: .activitySummary))
        case "finalAnswerSet":
            if try container.decodeNil(forKey: .finalAnswer) {
                self = .finalAnswerSet(nil)
            } else {
                self = .finalAnswerSet(try container.decode(String.self, forKey: .finalAnswer))
            }
        case "extensionUiRequestSet":
            if try container.decodeNil(forKey: .request) {
                self = .extensionUiRequestSet(nil)
            } else {
                self = .extensionUiRequestSet(try container.decode(PickyExtensionUiRequest.self, forKey: .request))
            }
        case let type:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown projection mutation type: \(type)")
        }
    }
}

private struct PickyProjectionCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct PickySessionProjectionTransaction: Decodable, Equatable {
    let sessionId: String
    let epoch: String
    let baseRevision: Int
    let revision: Int
    let mutations: [PickySessionProjectionMutation]

    private enum CodingKeys: String, CodingKey { case sessionId, epoch, baseRevision, revision, mutations }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        epoch = try container.decode(String.self, forKey: .epoch)
        baseRevision = try container.decode(Int.self, forKey: .baseRevision)
        revision = try container.decode(Int.self, forKey: .revision)
        mutations = try container.decode([PickySessionProjectionMutation].self, forKey: .mutations)
        guard baseRevision >= 0, revision > baseRevision, !mutations.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .revision, in: container, debugDescription: "Transactions require non-empty mutations and revision > baseRevision")
        }
        for mutation in mutations {
            guard case .extensionUiRequestSet(let request?) = mutation, request.sessionId != sessionId else { continue }
            throw DecodingError.dataCorruptedError(forKey: .mutations, in: container, debugDescription: "extension UI request sessionId must match transaction sessionId")
        }
    }
}

struct PickySessionProjectionSnapshot: Decodable, Equatable {
    let requestId: String?
    let sessionId: String
    let epoch: String
    let revision: Int
    let complete: Bool
    let omittedFields: [String]
    let projection: PickyAgentSession

    // Mirrors the persisted PickyAgentSession schema, including `archivedAt`,
    // which remains a dormant v2 patch field until the storage cutover.
    private static let persistedSessionFields: Set<String> = [
        "id", "title", "status", "cwd", "piSessionFilePath", "createdAt", "updatedAt",
        "lastSummary", "thinkingPreview", "finalAnswer", "logs", "tools", "todoState",
        "subagentRuns", "artifacts", "changedFiles", "messages", "messageJournalAvailable",
        "queuedSteers", "queuedFollowUps", "steeringMode", "followUpMode", "activitySummary",
        "contextUsage", "currentAssistantRun", "pendingExtensionUiRequest", "notifyMainOnCompletion",
        "archived", "archivedAt", "pinned",
    ]

    private enum CodingKeys: String, CodingKey {
        case requestId, sessionId, epoch, revision, complete, omittedFields, projection
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestId = try container.decodeIfPresent(String.self, forKey: .requestId)
        sessionId = try container.decode(String.self, forKey: .sessionId)
        epoch = try container.decode(String.self, forKey: .epoch)
        revision = try container.decode(Int.self, forKey: .revision)
        complete = try container.decode(Bool.self, forKey: .complete)
        omittedFields = try container.decode([String].self, forKey: .omittedFields)
        projection = try container.decode(PickyAgentSession.self, forKey: .projection)

        guard revision >= 0,
              Set(omittedFields).count == omittedFields.count,
              omittedFields.allSatisfy({ Self.persistedSessionFields.contains($0) }),
              !complete || omittedFields.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .omittedFields, in: container, debugDescription: "Invalid projection snapshot omission metadata")
        }
    }
}

extension PickyEvent {
    /// Decodes only the two dormant v2 events. Invalid payloads preserve the
    /// v1 all-or-nothing safety policy by becoming `.unknown(type:)`.
    static func decodeDormantSessionProjectionEvent(type: String, decoder: Decoder) -> PickyEvent {
        do {
            switch type {
            case "sessionProjectionTransaction":
                return .sessionProjectionTransaction(try PickySessionProjectionTransaction(from: decoder))
            case "sessionProjectionSnapshot":
                return .sessionProjectionSnapshot(try PickySessionProjectionSnapshot(from: decoder))
            default:
                return .unknown(type: type)
            }
        } catch {
            logDiscardedProjectionEvent(type: type, decoder: decoder, error: error)
            return .unknown(type: type)
        }
    }

    private static func logDiscardedProjectionEvent(type: String, decoder: Decoder, error: Error) {
        let diagnostics = try? decoder.container(keyedBy: PickyProjectionEventDiagnosticKey.self)
        let sessionID = diagnostics.flatMap { try? $0.decode(String.self, forKey: .sessionId) } ?? "unavailable"
        let revision = diagnostics
            .flatMap { try? $0.decode(Int.self, forKey: .revision) }
            .map { String($0) } ?? "unavailable"

        PickyLog.notice(
            .agentClient,
            prefix: "🔌 Picky agent client —",
            message: "discarded invalid dormant \(type) session=\(sessionID) revision=\(revision) reason=\(projectionDecodingErrorSummary(error))"
        )
    }
}

private enum PickyProjectionEventDiagnosticKey: String, CodingKey {
    case sessionId, revision
}

private func projectionDecodingErrorSummary(_ error: Error) -> String {
    switch error {
    case let DecodingError.dataCorrupted(context):
        context.debugDescription
    case let DecodingError.keyNotFound(key, _):
        "missing key \(key.stringValue)"
    case let DecodingError.typeMismatch(value, _):
        "type mismatch \(String(reflecting: value))"
    case let DecodingError.valueNotFound(value, _):
        "missing value \(String(reflecting: value))"
    default:
        "unexpected \(String(reflecting: type(of: error)))"
    }
}


