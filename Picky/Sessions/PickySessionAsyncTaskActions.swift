import Foundation

/// UI-initiated task actions. The registry remains the only detail owner;
/// results are accepted only for the exact provider/runtime/root captured here.
@MainActor
enum PickySessionAsyncTaskActions {
    static func stopArchived(sessionID: String, archived: PickySessionCard?,
                             client: any PickyAgentClient) async throws {
        guard archived?.hasAsyncTracking == true, let control = client.asyncTaskControl else {
            throw PickyAsyncControlError.requestConflict
        }
        pickySessionLog("abort session=\(sessionID)")
        _ = try await control.stopAsyncWork(sessionID: sessionID)
    }

    static func cancel(owner: PickyAsyncTaskOwner, taskID: String,
                       client: any PickyAgentClient, store: PickySessionStore?) async throws {
        let control = try control(for: owner, client: client, store: store)
        let context = try await control.asyncControlContext(sessionID: owner.sessionId)
        try verify(owner: owner, taskID: taskID, context: context, store: store, rootOnly: true)
        var command = try context.command(.cancelAsyncTask)
        command.owner = owner
        command.taskId = taskID
        let result = try await control.executeAsyncControl(command)
        guard result.outcome == .settled else {
            throw PickyAsyncControlError.outcome(result.outcome, reason: result.reason)
        }
    }

    static func detail(owner: PickyAsyncTaskOwner, taskID: String,
                       client: any PickyAgentClient, store: PickySessionStore?) async throws -> PickyAsyncTaskDetail {
        let control = try control(for: owner, client: client, store: store)
        let context = try await control.asyncControlContext(sessionID: owner.sessionId)
        try verify(owner: owner, taskID: taskID, context: context, store: store, rootOnly: true)
        var command = try context.command(.asyncTaskDetail)
        command.owner = owner
        command.taskId = taskID
        command.limit = 100 // The provider returns an atomic root family or an explicit unsupported result.
        let result = try await control.executeAsyncControl(command)
        guard result.outcome == .settled else {
            throw PickyAsyncControlError.outcome(result.outcome, reason: result.reason)
        }
        guard let detail = result.detail else { throw PickyAsyncControlError.invalidResponse }
        return detail
    }

    private static func control(for owner: PickyAsyncTaskOwner, client: any PickyAgentClient,
                                store: PickySessionStore?) throws -> any PickyAsyncTaskControlling {
        guard let store, case .loaded(let metadata) = store.metaStore.metadataState,
              metadata.asyncWorkSummary != nil, let control = client.asyncTaskControl else {
            throw PickyAsyncControlError.unsupported
        }
        guard store.sessionID == owner.sessionId else { throw PickyAsyncControlError.requestConflict }
        return control
    }

    private static func verify(owner: PickyAsyncTaskOwner, taskID: String, context: PickyAsyncControlContext,
                               store: PickySessionStore?, rootOnly: Bool) throws {
        guard context.hasCompleteCoverage, context.runtimeInstanceId == owner.runtimeInstanceId,
              case .loaded(let detail)? = store?.asyncTaskStore.detailState,
              detail.tasks.contains(where: {
                  $0.owner == owner && $0.taskId == taskID &&
                      (!rootOnly || ($0.rootTaskId == taskID && $0.parentTaskId == nil))
              }) else { throw PickyAsyncControlError.requestConflict }
    }
}
