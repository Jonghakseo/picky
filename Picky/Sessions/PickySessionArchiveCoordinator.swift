import Foundation
import Combine

extension PickySessionListViewModel.SessionCard {
    var hasAsyncTracking: Bool {
        asyncWorkSummary != nil || asyncControl != nil || asyncTasks != nil || completionTickets != nil || agentCycle != nil
    }
}

/// Owns archive requests and undo timers, not session membership or task data.
@MainActor
final class PickySessionArchiveCoordinator: ObservableObject {
    enum State: Equatable {
        case choosingMode
        case pending
        case failed(PickyAsyncControlError)
        case transportFailed(String)
    }
    @Published private(set) var states: [String: State] = [:]
    private(set) var intents: [String: Bool] = [:]
    private var commandIntents: [String: (sessionID: String, archived: Bool)] = [:]
    private var commits: [String: Task<Void, Never>] = [:]
    private var releasing = Set<String>()
    private var generations: [String: Int] = [:]

    func setMembership(_ sessionID: String, archived: Bool, store: any PickySessionArchiveStoring) {
        if archived {
            store.archivedSessionIDs.insert(sessionID)
            store.manuallyArchivedSessionIDs.insert(sessionID)
        } else {
            store.archivedSessionIDs.remove(sessionID)
            store.manuallyArchivedSessionIDs.remove(sessionID)
        }
    }

    func sendLegacyIntent(sessionID: String, archived: Bool, client: any PickyAgentClient,
                          onFailure: @escaping @MainActor (String) -> Void) {
        let command = PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: archived)
        intents[sessionID] = archived
        commandIntents[command.id] = (sessionID, archived)
        Task { @MainActor in
            do { try await client.send(command) }
            catch { onFailure(command.id) }
        }
    }

    func clearIntent(sessionID: String) {
        intents[sessionID] = nil
        commandIntents = commandIntents.filter { $0.value.sessionID != sessionID }
    }

    func failedIntent(commandID: String?) -> (sessionID: String, archived: Bool)? {
        guard let commandID, let intent = commandIntents.removeValue(forKey: commandID),
              intents[intent.sessionID] == intent.archived else { return nil }
        clearIntent(sessionID: intent.sessionID)
        return intent
    }

    func scheduleCommit(sessionID: String, delay: UInt64, commit: @escaping @MainActor () -> Void) {
        cancelCommit(sessionID: sessionID)
        commits[sessionID] = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            guard let self, !Task.isCancelled else { return }
            self.commits[sessionID] = nil
            commit()
        }
    }
    func cancelCommit(sessionID: String) { commits.removeValue(forKey: sessionID)?.cancel() }
    func hasCommit(sessionID: String) -> Bool { commits[sessionID] != nil }

    func archive(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?, client: any PickyAgentClient) async throws {
        guard let control = client.asyncTaskControl else { throw PickyAsyncControlError.unsupported }
        let generation = generations[sessionID, default: 0]
        states[sessionID] = .pending
        do {
            try await control.archiveAsyncSession(sessionID: sessionID, mode: mode)
            guard generation == generations[sessionID, default: 0] else { throw CancellationError() }
            states[sessionID] = nil
        } catch { record(error, sessionID: sessionID); throw error }
    }

    func invalidateIntent(sessionID: String, client: any PickyAgentClient, tracked: Bool) {
        generations[sessionID, default: 0] += 1
        cancelCommit(sessionID: sessionID)
        if tracked { client.asyncTaskControl?.invalidateAsyncArchiveIntent(sessionID: sessionID) }
    }

    func restore(sessionID: String, client: any PickyAgentClient) async throws {
        guard let control = client.asyncTaskControl else { throw PickyAsyncControlError.unsupported }
        states[sessionID] = .pending
        do {
            try await control.restoreAsyncSession(sessionID: sessionID)
            states[sessionID] = nil
        } catch { record(error, sessionID: sessionID); throw error }
    }

    func release(sessionID: String, client: any PickyAgentClient, retry: Bool = false,
                 onReleased: @escaping @MainActor () -> Void) {
        if retry { states[sessionID] = nil }
        guard states[sessionID] == nil, releasing.insert(sessionID).inserted else { return }
        Task { @MainActor in
            defer { self.releasing.remove(sessionID) }
            do {
                guard let control = client.asyncTaskControl else { throw PickyAsyncControlError.unsupported }
                if try await control.releaseArchivedAsyncSession(sessionID: sessionID) { onReleased() }
            } catch { self.record(error, sessionID: sessionID) }
        }
    }

    func requestDelete(sessionID: String, client: any PickyAgentClient,
                       canDelete: @escaping @MainActor () -> Bool,
                       onConfirmed: @escaping @MainActor () -> Void,
                       onFailure: @escaping @MainActor (Error) -> Void) {
        guard canDelete() else { return }
        Task { @MainActor in
            guard canDelete() else { return }
            do {
                try await delete(sessionID: sessionID, client: client)
                if canDelete() { onConfirmed() }
            } catch { onFailure(error) }
        }
    }

    func confirmArchive(sessionID: String, tracked: Bool, mode: PickyAsyncTaskCommand.ArchiveMode?,
                        client: any PickyAgentClient) async throws {
        if tracked { try await archive(sessionID: sessionID, mode: mode, client: client) } else if let error = try await client.sendAwaitingError(PickyCommandEnvelope(type: .setSessionArchived,
            sessionId: sessionID, archived: true), timeout: 5, requireAcknowledgement: true) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(error.message)
        }
    }

    func delete(sessionID: String, client: any PickyAgentClient) async throws {
        if let rejection = try await client.sendAwaitingError(PickyCommandEnvelope(type: .deleteSession,
            sessionId: sessionID), timeout: 5, requireAcknowledgement: true) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(rejection.message)
        }
    }

    func record(_ error: Error, sessionID: String) {
        if let error = error as? PickyAsyncControlError {
            states[sessionID] = error == .archiveChoiceRequired ? .choosingMode : .failed(error)
        }
        else { states[sessionID] = .transportFailed(error.localizedDescription) }
    }
}
