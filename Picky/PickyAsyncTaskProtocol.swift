import Foundation

// Closed lifecycle enums intentionally reject future values instead of reporting success.
enum PickyExecutionState: String, Codable { case queued, running, cancelling, succeeded, failed, cancelled, interrupted }
enum PickyExecutionPresence: String, Codable { case active, settled, unknown }
enum PickyCompletionState: String, Codable { case pending, submitted, observed, processing, handled, suppressed, failed, unknown }
enum PickyRegistrationState: String, Codable { case reserved, approved, starting, spawned, abandoned }
enum PickyAdmissionState: String, Codable { case open, closing, closed }
enum PickyAsyncOperationOutcome: String, Codable { case accepted, settled, rejected, unsupported, stale, blocked_delivery, blocked_cleanup }

struct PickyAgentCycle: Codable, Equatable {
    enum Phase: String, Codable { case idle, responding, compacting, settled }
    enum Outcome: String, Codable { case completed, failed, cancelled }
    var cycleId: String
    var runtimeInstanceId: String
    var phase: Phase
    var outcome: Outcome?
    var controlGeneration: Int
}

struct PickyAsyncWorkSummary: Codable, Equatable {
    struct Episode: Codable, Equatable {
        var id: String
        var settled: Bool
        var finalizedCycleId: String?
        var outcome: PickyAgentCycle.Outcome?
    }

    var episode: Episode? = nil
    enum Tracking: String, Codable { case ready, reconciling, unsupported }
    var tracking: Tracking
    var activeRootCount: Int
    var pendingCompletionCount: Int
    var uncertainExecutionCount: Int
    var attentionCount: Int
    var workRevision: Int
    var canReleaseRuntime: Bool
}

extension PickyAsyncWorkSummary.Episode {
    private enum CodingKeys: String, CodingKey { case id, settled, finalizedCycleId, outcome }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        settled = try container.decode(Bool.self, forKey: .settled)
        finalizedCycleId = try container.decodeIfPresent(String.self, forKey: .finalizedCycleId)
        outcome = try container.decodeIfPresent(PickyAgentCycle.Outcome.self, forKey: .outcome)
        guard (1...256).contains(id.utf16.count),
              finalizedCycleId.map({ (1...256).contains($0.utf16.count) }) ?? true,
              !settled || (finalizedCycleId != nil && outcome != nil) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid async work episode"))
        }
    }
}

struct PickyAsyncTaskOwner: Codable, Equatable, Hashable {
    var sessionId: String
    var piSessionId: String
    var runtimeInstanceId: String
    var providerId: String
    var providerInstanceId: String
}

struct PickyAsyncTask: Codable, Equatable {
    var sessionId: String
    var piSessionId: String
    var runtimeInstanceId: String
    var providerId: String
    var providerInstanceId: String
    var taskId: String
    var rootTaskId: String
    var parentTaskId: String?
    var invocationId: String?
    /// Open discriminator preserves a future provider's kind and JSON details.
    var kind: String
    var title: String
    var progress: String?
    var execution: PickyExecutionState
    var presence: PickyExecutionPresence
    var registration: PickyRegistrationState
    var grantId: String?
    var providerRevision: Int
    var controlGeneration: Int
    var createdAt: Date
    var updatedAt: Date
    var details: [String: JSONValue]?

    var owner: PickyAsyncTaskOwner {
        .init(sessionId: sessionId, piSessionId: piSessionId, runtimeInstanceId: runtimeInstanceId, providerId: providerId, providerInstanceId: providerInstanceId)
    }
}

struct PickyCompletionTicket: Codable, Equatable {
    enum Target: String, Codable { case model, human }
    var sessionId: String
    var piSessionId: String
    var runtimeInstanceId: String
    var providerId: String
    var providerInstanceId: String
    var completionId: String
    var rootTaskId: String
    var target: Target
    var state: PickyCompletionState
    var controlGeneration: Int
    var deliveryId: String?
    var cycleId: String?
    var failureReason: String?

    var owner: PickyAsyncTaskOwner {
        .init(sessionId: sessionId, piSessionId: piSessionId, runtimeInstanceId: runtimeInstanceId, providerId: providerId, providerInstanceId: providerInstanceId)
    }
}

struct PickyAsyncTaskDetail: Codable, Equatable {
    var tasks: [PickyAsyncTask]
    var tickets: [PickyCompletionTicket]

    init(tasks: [PickyAsyncTask], tickets: [PickyCompletionTicket]) {
        self.tasks = tasks
        self.tickets = tickets
    }

    private enum CodingKeys: String, CodingKey { case tasks, tickets }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try container.decode([PickyAsyncTask].self, forKey: .tasks)
        tickets = try container.decode([PickyCompletionTicket].self, forKey: .tickets)
        try validate(codingPath: decoder.codingPath)
    }

    func validate(codingPath: [CodingKey] = []) throws {
        struct Identity: Hashable { let owner: PickyAsyncTaskOwner; let id: String }
        var identities = Set<Identity>()
        for task in tasks {
            guard identities.insert(.init(owner: task.owner, id: task.taskId)).inserted,
                  !task.taskId.isEmpty, !task.title.isEmpty, task.title.utf16.count <= 500,
                  (task.progress?.utf16.count ?? 0) <= 4_096,
                  task.providerRevision >= 0, task.controlGeneration >= 0,
                  (try task.details.map { try JSONEncoder().encode($0).count } ?? 0) <= 16_384 else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid or duplicate async task"))
            }
        }
        let roots = Set(tasks.filter { $0.taskId == $0.rootTaskId }.map { Identity(owner: $0.owner, id: $0.taskId) })
        for task in tasks {
            guard roots.contains(.init(owner: task.owner, id: task.rootTaskId)),
                  task.parentTaskId.map({ identities.contains(.init(owner: task.owner, id: $0)) }) ?? true else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Task owner/root/parent mismatch"))
            }
        }
        var completions = Set<Identity>()
        for ticket in tickets {
            guard completions.insert(.init(owner: ticket.owner, id: ticket.completionId)).inserted,
                  roots.contains(.init(owner: ticket.owner, id: ticket.rootTaskId)),
                  ![PickyCompletionState.processing, .handled].contains(ticket.state) || ticket.cycleId != nil else {
                throw DecodingError.dataCorrupted(.init(codingPath: codingPath, debugDescription: "Invalid completion identity or cycle"))
            }
        }
    }
}

struct PickyReleaseApproval: Codable, Equatable {
    var operationId: String
    var releaseToken: String
    var sessionId: String
    var daemonInstanceId: String
    var runtimeInstanceId: String
    var childGeneration: Int
    var archiveIntentId: String
    var workRevision: Int
    var controlGeneration: Int
}

struct PickyAsyncControlOperation: Codable, Equatable {
    var requestId: String
    var operationId: String
    var outcome: PickyAsyncOperationOutcome
    var controlGeneration: Int
    var reason: String?
}

struct PickyAsyncControlState: Codable, Equatable {
    var controlGeneration: Int
    var admissionState: PickyAdmissionState
    var operations: [PickyAsyncControlOperation]
    var releasePrepared: PickyReleaseApproval?
}

/// Owner-scoped commands retain their original request identity across retries.
struct PickyAsyncTaskCommand: Codable, Equatable {
    enum Kind: String, Codable {
        case asyncTaskDetail, cancelAsyncTask, prepareSessionArchive, executeSessionArchive
        case prepareRuntimeRelease, cancelRuntimeRelease
    }
    enum ArchiveMode: String, Codable { case `continue`, stopThenArchive }
    var type: Kind
    var requestId: String
    var sessionId: String
    var daemonInstanceId: String
    var runtimeInstanceId: String
    var workRevision: Int
    var controlGeneration: Int
    var owner: PickyAsyncTaskOwner?
    var taskId: String?
    var cursor: String?
    var limit: Int?
    var archiveIntentId: String?
    var mode: ArchiveMode?
    var preparationId: String?
    var childGeneration: Int?
    var releaseToken: String?
}

struct PickyAsyncTaskCommandResult: Codable, Equatable {
    var type: String
    var requestId: String
    var sessionId: String
    var daemonInstanceId: String
    var runtimeInstanceId: String
    var workRevision: Int
    var controlGeneration: Int
    var operationId: String
    var outcome: PickyAsyncOperationOutcome
    var reason: String?
    var preparationId: String?
    var releaseApproval: PickyReleaseApproval?
    var detail: PickyAsyncTaskDetail?
    var nextCursor: String?
}

struct PickyAsyncTaskResultEvent: Decodable {
    let result: PickyAsyncTaskCommandResult
}

struct PickyAsyncControlContext: Codable, Equatable {
    var requestId: String
    var sessionId: String
    var daemonInstanceId: String
    var runtimeInstanceId: String?
    var workRevision: Int
    var controlGeneration: Int
    var admissionState: PickyAdmissionState
    var tracking: PickyAsyncWorkSummary.Tracking
    var expectedProviders: [String]
    var readyProviders: [String]
    var requiresArchiveChoice: Bool?
    var archiveIntentId: String? = nil
    var releasePrepared: PickyReleaseApproval? = nil

    var hasCompleteCoverage: Bool {
        tracking == .ready && Set(expectedProviders).isSubset(of: Set(readyProviders))
    }

    func command(_ kind: PickyAsyncTaskCommand.Kind, requestId: String = UUID().uuidString) throws -> PickyAsyncTaskCommand {
        guard let runtimeInstanceId, !runtimeInstanceId.isEmpty else {
            throw PickyAsyncControlError.missingRuntime
        }
        return PickyAsyncTaskCommand(type: kind, requestId: requestId, sessionId: sessionId,
            daemonInstanceId: daemonInstanceId, runtimeInstanceId: runtimeInstanceId,
            workRevision: workRevision, controlGeneration: controlGeneration)
    }
}
