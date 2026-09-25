import Foundation

/// These values are presentation-neutral. W6 renders choices and unknown outcomes.
enum PickyAsyncControlError: LocalizedError, Equatable {
    case missingRuntime
    case unsupported
    case archiveChoiceRequired
    case pending(requestId: String)
    case requestConflict
    case invalidResponse
    case outcome(PickyAsyncOperationOutcome, reason: String?)

    // The presentation layer localizes typed states. CLI errors retain the
    // owner reason or a stable diagnostic code rather than generic NSError text.
    var errorDescription: String? {
        switch self {
        case .outcome(let outcome, let reason): reason ?? outcome.rawValue
        case .archiveChoiceRequired: "archive_mode_required (continue | stopThenArchive)"
        case .missingRuntime: "async_runtime_unavailable"
        case .unsupported: "async_control_unsupported"
        case .pending(let requestId): "async_control_pending requestId=\(requestId)"
        case .requestConflict: "async_request_identity_conflict"
        case .invalidResponse: "async_control_invalid_response"
        }
    }
}

@MainActor
protocol PickyAsyncTaskControlling: AnyObject {
    func asyncControlContext(sessionID: String) async throws -> PickyAsyncControlContext
    func executeAsyncControl(_ command: PickyAsyncTaskCommand) async throws -> PickyAsyncTaskCommandResult
    func stopAsyncWork(sessionID: String) async throws -> PickyAsyncTaskCommandResult
    func archiveAsyncSession(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?) async throws
    func restoreAsyncSession(sessionID: String) async throws
    func invalidateAsyncArchiveIntent(sessionID: String)
    func releaseArchivedAsyncSession(sessionID: String) async throws -> Bool
}

/// Correlates owner replies, not envelope acknowledgements. Timed-out envelopes and
/// late results remain available under the original identity for explicit retry.
@MainActor
final class PickyAsyncControlTransport {
    enum Reply: Equatable {
        case context(PickyAsyncControlContext)
        case result(PickyAsyncTaskCommandResult)
    }

    private struct Request {
        let envelope: PickyCommandEnvelope
        let source: ObjectIdentifier
        let expectedOwner: PickyAsyncControlContext?
        var reply: Result<Reply, Error>?
        var waiters: [UUID: CheckedContinuation<Reply, Error>] = [:]
        var timers: [UUID: Task<Void, Never>] = [:]
    }
    private var requests: [String: Request] = [:]
    var timeoutNanoseconds: UInt64 = 30_000_000_000

    func request(_ envelope: PickyCommandEnvelope, source: any PickyAgentClient,
                 expectedOwner: PickyAsyncControlContext? = nil, send: @escaping @MainActor () async throws -> Void) async throws -> Reply {
        if let existing = requests[envelope.id] {
            guard existing.envelope == envelope, existing.source == ObjectIdentifier(source), existing.expectedOwner == expectedOwner else {
                throw PickyAsyncControlError.requestConflict
            }
            if let reply = existing.reply { return try reply.get() }
        } else {
            requests[envelope.id] = Request(envelope: envelope, source: ObjectIdentifier(source), expectedOwner: expectedOwner)
        }
        let waiterID = UUID()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                requests[envelope.id]?.waiters[waiterID] = continuation
                requests[envelope.id]?.timers[waiterID] = Task { @MainActor in
                    do { try await Task.sleep(nanoseconds: self.timeoutNanoseconds) }
                    catch { return }
                    self.expire(envelope.id, waiterID: waiterID,
                                error: PickyAsyncControlError.pending(requestId: envelope.id))
                }
                Task { @MainActor in
                    do { try await send() }
                    catch { self.expire(envelope.id, waiterID: waiterID, error: error) }
                }
            }
        }, onCancel: {
            Task { @MainActor in self.expire(envelope.id, waiterID: waiterID, error: CancellationError()) }
        })
    }

    func receive(_ event: PickyEvent, source: any PickyAgentClient) {
        let id: String
        let reply: Result<Reply, Error>
        switch event {
        case .asyncControlContext(let context):
            id = context.requestId
            guard let request = requests[id], request.envelope.type == .getAsyncControlContext,
                  request.envelope.sessionId == context.sessionId else { return }
            reply = .success(.context(context))
        case .asyncTaskCommandResult(let result):
            guard let match = requests.first(where: {
                $0.value.source == ObjectIdentifier(source) &&
                ($0.value.envelope.command?.requestId == result.requestId ||
                 ($0.value.envelope.type == .abort && $0.key == result.requestId))
            }) else { return }
            id = match.key
            let request = match.value
            guard request.envelope.sessionId == result.sessionId else { return }
            if let command = request.envelope.command {
                guard result.daemonInstanceId == command.daemonInstanceId,
                      result.runtimeInstanceId == command.runtimeInstanceId else { return }
            } else if request.envelope.type != .abort { return }
            if let owner = request.expectedOwner {
                guard result.daemonInstanceId == owner.daemonInstanceId,
                      result.runtimeInstanceId == owner.runtimeInstanceId else { return }
            }
            reply = .success(.result(result))
        case .error(let error):
            guard let commandID = error.commandId else { return }
            id = commandID
            reply = .failure(PickyAgentClientRouterError.bridgeCommandRejected(error.message))
        default: return
        }
        guard var request = requests[id], request.source == ObjectIdentifier(source) else { return }
        // Accepted is progress, never a terminal reply. Keep waiting for settlement.
        if case .success(.result(let result)) = reply, result.outcome == .accepted { return }
        guard request.reply == nil else { return }
        request.reply = reply
        let waiters = request.waiters.values
        request.waiters.removeAll()
        for timer in request.timers.values { timer.cancel() }
        request.timers.removeAll()
        requests[id] = request
        for waiter in waiters { waiter.resume(with: reply) }
    }

    private func expire(_ id: String, waiterID: UUID, error: Error) {
        requests[id]?.timers.removeValue(forKey: waiterID)?.cancel()
        requests[id]?.waiters.removeValue(forKey: waiterID)?.resume(throwing: error)
    }
}
