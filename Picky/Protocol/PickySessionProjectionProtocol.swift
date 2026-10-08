//
//  PickySessionProjectionProtocol.swift
//  Picky
//
//  Dormant session projection v2 protocol codecs.
//

import Foundation

struct PickyContextUsage: Codable, Equatable {
    var tokens: Int?
    var contextWindow: Int
    var percent: Double?

    // The agentd Zod schema requires `tokens` and `percent` to be present as
    // number|null. Swift's synthesized encoder omits nil keys, which would
    // make app-daemon session payload validation fail, so emit explicit nulls here.
    private enum CodingKeys: String, CodingKey { case tokens, contextWindow, percent }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tokens, forKey: .tokens)
        try container.encode(contextWindow, forKey: .contextWindow)
        try container.encode(percent, forKey: .percent)
    }
}

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

/// All v2 mutation variants. Unknown variant discriminators deliberately throw;
/// the containing transaction is then discarded as `.unknown` by `PickyEvent`.
enum PickySessionProjectionMutation: Decodable, Equatable {
    case metaPatch(PickySessionMetaPatch)
    case messageAppend(PickySessionMessage)
    case messageReplace(messageId: String, message: PickySessionMessage)
    case messageRemove(messageId: String)
    case messagesImport([PickySessionMessage])
    case logAppend(line: String)
    case logsSet([String])
    case toolUpsert(PickyToolActivity)
    case toolsSet([PickyToolActivity])
    case todoSet(PickyTodoState?)
    case subagentRunsSet([PickySubagentRun])
    case asyncTaskDetailSet(PickyAsyncTaskDetail?)
    case asyncControlSet(PickyAsyncControlState?)
    case artifactUpsert(PickyArtifact)
    case artifactsSet([PickyArtifact])
    case changedFilesSet([PickyChangedFile])
    case queueSet(queuedSteers: [PickyQueueItem], queuedFollowUps: [PickyQueueItem], scheduledMessages: [PickyScheduledMessage], steeringMode: PickyQueueMode, followUpMode: PickyQueueMode)
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
        case .logsSet: "logsSet"
        case .toolUpsert: "toolUpsert"
        case .toolsSet: "toolsSet"
        case .todoSet: "todoSet"
        case .subagentRunsSet: "subagentRunsSet"
        case .asyncTaskDetailSet: "asyncTaskDetailSet"
        case .asyncControlSet: "asyncControlSet"
        case .artifactUpsert: "artifactUpsert"
        case .artifactsSet: "artifactsSet"
        case .changedFilesSet: "changedFilesSet"
        case .queueSet: "queueSet"
        case .activitySet: "activitySet"
        case .finalAnswerSet: "finalAnswerSet"
        case .extensionUiRequestSet: "extensionUiRequestSet"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case type, patch, message, messageId, messages, line, logs, tool, tools, todoState, runs, artifact, artifacts
        case changedFiles, queuedSteers, queuedFollowUps, scheduledMessages, steeringMode, followUpMode, activitySummary
        case finalAnswer, request, detail, control
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
        case "logsSet": self = .logsSet(try container.decode([String].self, forKey: .logs))
        case "toolUpsert": self = .toolUpsert(try container.decode(PickyToolActivity.self, forKey: .tool))
        case "toolsSet": self = .toolsSet(try container.decode([PickyToolActivity].self, forKey: .tools))
        case "todoSet":
            if try container.decodeNil(forKey: .todoState) {
                self = .todoSet(nil)
            } else {
                self = .todoSet(try container.decode(PickyTodoState.self, forKey: .todoState))
            }
        case "subagentRunsSet": self = .subagentRunsSet(try container.decode([PickySubagentRun].self, forKey: .runs))
        case "asyncTaskDetailSet": self = .asyncTaskDetailSet(try container.decodeNil(forKey: .detail) ? nil : container.decode(PickyAsyncTaskDetail.self, forKey: .detail))
        case "asyncControlSet": self = .asyncControlSet(try container.decodeNil(forKey: .control) ? nil : container.decode(PickyAsyncControlState.self, forKey: .control))
        case "artifactUpsert": self = .artifactUpsert(try container.decode(PickyArtifact.self, forKey: .artifact))
        case "artifactsSet": self = .artifactsSet(try container.decode([PickyArtifact].self, forKey: .artifacts))
        case "changedFilesSet": self = .changedFilesSet(try container.decode([PickyChangedFile].self, forKey: .changedFiles))
        case "queueSet":
            self = .queueSet(
                queuedSteers: try container.decode([PickyQueueItem].self, forKey: .queuedSteers),
                queuedFollowUps: try container.decode([PickyQueueItem].self, forKey: .queuedFollowUps),
                // Optional so a daemon without delayed-action projection keeps working.
                scheduledMessages: try container.decodeIfPresent([PickyScheduledMessage].self, forKey: .scheduledMessages) ?? [],
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
            if case .asyncTaskDetailSet(let detail?) = mutation,
               !detail.tasks.allSatisfy({ $0.sessionId == sessionId }) {
                throw DecodingError.dataCorruptedError(forKey: .mutations, in: container, debugDescription: "Async task session must match transaction")
            }
            guard case .extensionUiRequestSet(let request?) = mutation, request.sessionId != sessionId else { continue }
            throw DecodingError.dataCorruptedError(forKey: .mutations, in: container, debugDescription: "extension UI request sessionId must match transaction sessionId")
        }
    }
}

struct PickySessionProjectionBootstrapComplete: Decodable, Equatable {
    let epoch: String
    let bootstrapId: String
    let sessionIds: [String]

    private enum CodingKeys: String, CodingKey { case epoch, bootstrapId, sessionIds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        epoch = try container.decode(String.self, forKey: .epoch)
        bootstrapId = try container.decode(String.self, forKey: .bootstrapId)
        sessionIds = try container.decode([String].self, forKey: .sessionIds)
        guard !epoch.isEmpty,
              !bootstrapId.isEmpty,
              sessionIds.allSatisfy({ !$0.isEmpty }),
              Set(sessionIds).count == sessionIds.count
        else {
            throw DecodingError.dataCorruptedError(forKey: .sessionIds, in: container, debugDescription: "Bootstrap completion requires non-empty correlation fields and unique non-empty session IDs")
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
        "agentCycle", "asyncWorkSummary", "asyncTasks", "completionTickets", "asyncControl",
        "id", "title", "status", "cwd", "piSessionFilePath", "createdAt", "updatedAt",
        "lastSummary", "thinkingPreview", "finalAnswer", "logs", "tools", "todoState",
        "subagentRuns", "artifacts", "changedFiles", "messages", "messageJournalAvailable",
        "queuedSteers", "queuedFollowUps", "scheduledMessages", "steeringMode", "followUpMode", "activitySummary",
        "contextUsage", "currentAssistantRun", "pendingExtensionUiRequest", "notifyMainOnCompletion", "notifyMacOSOnCompletion",
        "archived", "archivedAt", "pinned", "fastMode", "fastModeSupported", "runtimeRecovery",
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
              !omittedFields.contains("agentCycle"), !omittedFields.contains("asyncWorkSummary"),
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
            case "sessionProjectionBootstrapComplete":
                return .sessionProjectionBootstrapComplete(try PickySessionProjectionBootstrapComplete(from: decoder))
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

