import Foundation

@MainActor
final class PickyAsyncSessionControlState {
    struct Release {
        let command: PickyAsyncTaskCommand
        let capture: PickyChildReleaseCapture
        let intentGeneration: Int
    }
    var commands: [String: PickyAsyncTaskCommand] = [:]
    var restoring = Set<String>()
    var restores: [String: PickyCommandEnvelope] = [:]
    var stopOwners: [String: PickyAsyncControlContext] = [:]
    var stops: [String: PickyCommandEnvelope] = [:]
    var stopSources: [String: ObjectIdentifier] = [:]
    var releases: [String: Release] = [:]
    var deletions: [String: Int] = [:]
    var intentGenerations: [String: Int] = [:]
    var archiveIntents: [String: String] = [:]
    var archiveModes: [String: PickyAsyncTaskCommand.ArchiveMode] = [:]
    var archiveChoices: [String: PickyAsyncControlContext] = [:]
}

@MainActor
final class PickyAsyncOwnerControlCoordinator: PickyAsyncTaskControlling {
    private weak var router: PickyAgentClientRouter?
    private let asyncControlTransport: PickyAsyncControlTransport
    private let asyncControlState = PickyAsyncSessionControlState()
    private var projectionWaiters: [UUID: AsyncStream<Void>.Continuation] = [:]

    func projectionDidChange() {
        for waiter in projectionWaiters.values { waiter.yield(()) }
    }

    init(router: PickyAgentClientRouter, transport: PickyAsyncControlTransport) {
        self.router = router
        self.asyncControlTransport = transport
    }

    func blocksInput(sessionID: String) -> Bool {
        asyncControlState.restoring.contains(sessionID) || asyncControlState.releases[sessionID] != nil
            || asyncControlState.deletions[sessionID] != nil
    }

    func beginDeletion(sessionID: String) {
        asyncControlState.deletions[sessionID, default: 0] += 1
        asyncControlState.intentGenerations[sessionID, default: 0] += 1
        asyncControlState.releases[sessionID] = nil
    }

    func endDeletion(sessionID: String) {
        let remaining = asyncControlState.deletions[sessionID, default: 0] - 1
        asyncControlState.deletions[sessionID] = remaining > 0 ? remaining : nil
    }

    func asyncControlContext(sessionID: String) async throws -> PickyAsyncControlContext {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let target = try await router.connectedClient(for: sessionID)
        return try await context(sessionID: sessionID, on: target)
    }

    private func context(sessionID: String, on target: any PickyAgentClient) async throws -> PickyAsyncControlContext {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let envelope = PickyCommandEnvelope(type: .getAsyncControlContext, sessionId: sessionID)
        let reply = try await asyncControlTransport.request(envelope, source: target) {
            try await router.sendAfterCapabilityRegistration(envelope, on: target)
        }
        guard case .context(let context) = reply else { throw PickyAsyncControlError.invalidResponse }
        return context
    }

    func executeAsyncControl(_ command: PickyAsyncTaskCommand) async throws -> PickyAsyncTaskCommandResult {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let target = try await router.connectedClient(for: command.sessionId)
        let envelope = PickyCommandEnvelope(id: command.requestId, type: .asyncTaskCommand,
                                          sessionId: command.sessionId, command: command)
        let reply = try await asyncControlTransport.request(envelope, source: target) {
            try await router.sendAfterCapabilityRegistration(envelope, on: target)
        }
        guard case .result(let result) = reply else { throw PickyAsyncControlError.invalidResponse }
        return result
    }

    func stopAsyncWork(sessionID: String) async throws -> PickyAsyncTaskCommandResult {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let target = try await router.connectedClient(for: sessionID)
        let current = try await context(sessionID: sessionID, on: target)
        guard router.client(for: sessionID) === target else { throw PickyAsyncControlError.requestConflict }
        let retained = asyncControlState.stopOwners[sessionID]
        let sameOwner = asyncControlState.stopSources[sessionID] == ObjectIdentifier(target)
            && retained?.daemonInstanceId == current.daemonInstanceId
            && retained?.runtimeInstanceId == current.runtimeInstanceId
        // Only the current stop slot advances. The transport keeps the old
        // envelope and any late settlement under its original source/owner.
        let owner = sameOwner ? retained ?? current : current
        let envelope = sameOwner ? asyncControlState.stops[sessionID] ?? PickyCommandEnvelope(type: .abort, sessionId: sessionID)
            : PickyCommandEnvelope(type: .abort, sessionId: sessionID)
        asyncControlState.stopOwners[sessionID] = owner
        asyncControlState.stopSources[sessionID] = ObjectIdentifier(target)
        asyncControlState.stops[sessionID] = envelope
        let reply = try await asyncControlTransport.request(envelope, source: target, expectedOwner: owner) {
            try await router.sendAfterCapabilityRegistration(envelope, on: target)
        }
        guard case .result(let result) = reply else { throw PickyAsyncControlError.invalidResponse }
        if asyncControlState.stops[sessionID] == envelope {
            asyncControlState.stops[sessionID] = nil
            asyncControlState.stopOwners[sessionID] = nil
            asyncControlState.stopSources[sessionID] = nil
        }
        try requireAsyncSettlement(result)
        return result
    }

    func archiveAsyncSession(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?) async throws {
        _ = try await archiveSession(sessionID: sessionID, mode: mode)
    }

    private func archiveSession(sessionID: String, mode: PickyAsyncTaskCommand.ArchiveMode?) async throws -> PickyAsyncTaskCommandResult {
        let generation = asyncControlState.intentGenerations[sessionID, default: 0]
        let intent = asyncControlState.archiveIntents[sessionID] ?? UUID().uuidString
        asyncControlState.archiveIntents[sessionID] = intent
        let executeKey = "archive-execute:\(sessionID)"
        if let pending = asyncControlState.commands[executeKey] {
            guard mode == nil || pending.mode == mode else { throw PickyAsyncControlError.requestConflict }
            let result = try await performRetained(pending, key: executeKey)
            asyncControlState.archiveModes[sessionID] = nil
            return result
        }
        let prepareKey = "archive-prepare:\(sessionID)"
        defer {
            if asyncControlState.commands[prepareKey] == nil && asyncControlState.commands[executeKey] == nil {
                asyncControlState.archiveModes[sessionID] = nil
            }
        }
        var prepare: PickyAsyncTaskCommand
        let archiveMode: PickyAsyncTaskCommand.ArchiveMode
        if let pending = asyncControlState.commands[prepareKey] {
            guard let retainedMode = asyncControlState.archiveModes[sessionID],
                  mode == nil || mode == retainedMode else { throw PickyAsyncControlError.requestConflict }
            prepare = pending
            archiveMode = retainedMode
        } else {
            // A user choice must execute against the revision originally shown to
            // the user. A changed owner/revision is rejected by the daemon, not
            // silently recaptured while the dialog is open.
            let context: PickyAsyncControlContext
            if mode != nil, let choice = asyncControlState.archiveChoices.removeValue(forKey: sessionID) {
                context = choice
            } else {
                context = try await asyncControlContext(sessionID: sessionID)
            }
            guard generation == asyncControlState.intentGenerations[sessionID, default: 0] else {
                throw CancellationError()
            }
            if let mode { archiveMode = mode } else {
                guard context.hasCompleteCoverage else { throw PickyAsyncControlError.unsupported }
                guard context.requiresArchiveChoice == false else {
                    asyncControlState.archiveChoices[sessionID] = context
                    throw PickyAsyncControlError.archiveChoiceRequired
                }
                archiveMode = .continue
            }
            prepare = try context.command(.prepareSessionArchive)
            prepare.requireQuiescence = mode == nil ? true : nil
            asyncControlState.archiveModes[sessionID] = archiveMode
        }
        var preparedCommand = prepare
        if preparedCommand.archiveIntentId == nil { preparedCommand.archiveIntentId = intent }
        let prepared = try await performRetained(preparedCommand, key: prepareKey)
        guard generation == asyncControlState.intentGenerations[sessionID, default: 0],
              let preparationID = prepared.preparationId else { throw PickyAsyncControlError.invalidResponse }
        var execute = preparedCommand
        execute.type = .executeSessionArchive
        execute.requestId = UUID().uuidString
        execute.workRevision = prepared.workRevision
        execute.controlGeneration = prepared.controlGeneration
        execute.preparationId = preparationID
        execute.mode = archiveMode
        return try await performRetained(execute, key: executeKey)
    }

    /// Called synchronously at the user's undo action, before any suspended work.
    func invalidateAsyncArchiveIntent(sessionID: String) {
        asyncControlState.restoring.insert(sessionID)
        asyncControlState.intentGenerations[sessionID, default: 0] += 1
        asyncControlState.archiveIntents[sessionID] = nil
        asyncControlState.archiveChoices[sessionID] = nil
    }

    func restoreAsyncSession(sessionID: String) async throws {
        _ = try await restoreSession(sessionID: sessionID)
    }

    private func restoreSession(sessionID: String) async throws -> (PickyAsyncControlContext, String) {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        // A lost prepare reply may have committed. Resolve that exact operation
        // before querying/cancelling its token; never reopen on transport success.
        if let execute = asyncControlState.commands["archive-execute:\(sessionID)"] {
            _ = try await executeAsyncControl(execute)
            asyncControlState.commands["archive-execute:\(sessionID)"] = nil
        }
        if let release = asyncControlState.releases[sessionID] {
            _ = try await executeAsyncControl(release.command)
        }
        let context = try await asyncControlContext(sessionID: sessionID)
        let key = "release-cancel:\(sessionID)"
        if let pending = asyncControlState.commands[key] {
            _ = try await performRetained(pending, key: key)
        } else if let approval = context.releasePrepared {
            var cancel = try context.command(.cancelRuntimeRelease)
            cancel.releaseToken = approval.releaseToken
            _ = try await performRetained(cancel, key: key)
        }
        asyncControlState.releases[sessionID] = nil
        let target = try await router.connectedClient(for: sessionID)
        let envelope = asyncControlState.restores[sessionID] ?? PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archived: false)
        asyncControlState.restores[sessionID] = envelope
        if let rejection = try await router.sendAwaitingError(envelope, requireAcknowledgement: true, on: target) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(rejection.message)
        }
        asyncControlState.restores[sessionID] = nil
        asyncControlState.restoring.remove(sessionID)
        return (context, envelope.id)
    }

    func releaseArchivedAsyncSession(sessionID: String) async throws -> Bool {
        guard !asyncControlState.restoring.contains(sessionID), asyncControlState.deletions[sessionID] == nil else { return false }
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let generation = asyncControlState.intentGenerations[sessionID, default: 0]
        let release: PickyAsyncSessionControlState.Release
        if let pending = asyncControlState.releases[sessionID] { release = pending }
        else {
            let context = try await asyncControlContext(sessionID: sessionID)
            guard context.hasCompleteCoverage, let intent = context.archiveIntentId,
                  generation == asyncControlState.intentGenerations[sessionID, default: 0] else {
                throw PickyAsyncControlError.unsupported
            }
            var command = try context.command(.prepareRuntimeRelease)
            command.archiveIntentId = intent
            let local = PickyChildReleaseContext(requestId: command.requestId,
                daemonInstanceId: command.daemonInstanceId, runtimeInstanceId: command.runtimeInstanceId,
                archiveIntentId: intent, workRevision: command.workRevision, controlGeneration: command.controlGeneration)
            guard let capture = router.pool.captureRelease(sessionId: sessionID, context: local) else { return false }
            command.childGeneration = capture.childGeneration
            release = .init(command: command, capture: capture, intentGeneration: generation)
            asyncControlState.releases[sessionID] = release
        }
        let result = try await executeAsyncControl(release.command)
        if result.outcome != .settled {
            asyncControlState.releases[sessionID] = nil
            try requireAsyncSettlement(result)
        }
        let current = try await asyncControlContext(sessionID: sessionID)
        guard asyncControlState.deletions[sessionID] == nil,
              release.intentGeneration == asyncControlState.intentGenerations[sessionID, default: 0],
              current.hasCompleteCoverage, let intent = current.archiveIntentId,
              let runtime = current.runtimeInstanceId,
              current.releasePrepared == result.releaseApproval else { return false }
        let local = PickyChildReleaseContext(requestId: release.command.requestId,
            daemonInstanceId: current.daemonInstanceId, runtimeInstanceId: runtime,
            archiveIntentId: intent, workRevision: current.workRevision, controlGeneration: current.controlGeneration)
        // No suspension between final intent validation and generation-fenced stop.
        guard router.pool.terminateChild(capture: release.capture, result: result, currentContext: local) else { return false }
        asyncControlState.releases[sessionID] = nil
        router.releaseChild(sessionId: sessionID)
        return true
    }

    func bridgeAbort(sessionID: String, tracked: Bool) async throws {
        if tracked { _ = try await stopAsyncWork(sessionID: sessionID); return }
        try await legacyCommand(PickyCommandEnvelope(type: .abort, sessionId: sessionID))
    }

    func bridgeArchive(sessionID: String, archived: Bool, mode: PickyAsyncTaskCommand.ArchiveMode?, tracked: Bool) async throws {
        if tracked {
            guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
            let source = try await router.connectedClient(for: sessionID)
            let owner: (daemon: String, runtime: String?, request: String)
            if archived {
                let result = try await archiveSession(sessionID: sessionID, mode: mode)
                owner = (result.daemonInstanceId, result.runtimeInstanceId, result.requestId)
            } else {
                invalidateAsyncArchiveIntent(sessionID: sessionID)
                let (context, requestID) = try await restoreSession(sessionID: sessionID)
                owner = (context.daemonInstanceId, context.runtimeInstanceId, requestID)
            }
            try await waitForArchiveProjection(sessionID: sessionID, archived: archived, source: source, requestID: owner.request)
            let current = try await context(sessionID: sessionID, on: source)
            guard router.client(for: sessionID) === source,
                  current.daemonInstanceId == owner.daemon, current.runtimeInstanceId == owner.runtime else {
                throw PickyAsyncControlError.outcome(.stale, reason: "archive_projection_owner_changed")
            }
            guard router.pickleSessionSummary(id: sessionID)?.archived == archived else {
                throw PickyAsyncControlError.outcome(.stale, reason: "archive_projection_changed")
            }
        } else {
            try await legacyCommand(PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionID, archiveMode: mode, archived: archived))
        }
    }

    /// Owner settlement and registry publication have independent consumers.
    /// Wait for the real publication; never manufacture an archived summary.
    private func waitForArchiveProjection(sessionID: String, archived: Bool, source: any PickyAgentClient, requestID: String) async throws {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let waiterID = UUID()
        let (updates, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        projectionWaiters[waiterID] = continuation
        continuation.yield(())
        defer { projectionWaiters.removeValue(forKey: waiterID)?.finish() }
        let timeout = asyncControlTransport.timeoutNanoseconds
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in
                for await _ in updates {
                    guard router.client(for: sessionID) === source else {
                        throw PickyAsyncControlError.outcome(.stale, reason: "archive_projection_owner_changed")
                    }
                    if router.pickleSessionSummary(id: sessionID)?.archived == archived { return }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeout)
                throw PickyAsyncControlError.pending(requestId: requestID)
            }
            defer { group.cancelAll() }
            _ = try await group.next()
        }
    }

    func sendDeletion(_ command: PickyCommandEnvelope, timeout: TimeInterval) async throws -> PickyErrorEvent? {
        guard let router, let sessionID = command.sessionId else {
            throw PickyAgentClientRouterError.invalidBridgeRequest
        }
        beginDeletion(sessionID: sessionID)
        defer { endDeletion(sessionID: sessionID) }
        // Capture the connected owner without respawning an already retired child.
        let owner = try await router.connectedClient(for: sessionID, allowRespawn: false)
        let generation = router.childGenerationValue(for: sessionID)
        let rejection = try await router.sendAwaitingError(command, timeout: timeout,
            requireAcknowledgement: true, on: owner)
        guard router.client(for: sessionID) === owner, router.childGenerationValue(for: sessionID) == generation else {
            throw PickyAgentClientRouterError.bridgeCommandRejected("Pickle owner changed during deletion.")
        }
        return rejection
    }

    func deleteSession(sessionID: String, timeout: TimeInterval) async throws {
        if let error = try await sendDeletion(PickyCommandEnvelope(type: .deleteSession, sessionId: sessionID),
            timeout: timeout) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(error.message)
        }
    }

    private func legacyCommand(_ command: PickyCommandEnvelope, timeout: TimeInterval = 5) async throws {
        guard let router else { throw PickyAgentClientRouterError.routerUnavailable }
        let client = try await router.connectedClient(for: command.sessionId)
        if let error = try await router.sendAwaitingError(command, timeout: timeout, requireAcknowledgement: true, on: client) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(error.message)
        }
    }

    private func performRetained(_ command: PickyAsyncTaskCommand, key: String) async throws -> PickyAsyncTaskCommandResult {
        let retained = asyncControlState.commands[key] ?? command
        asyncControlState.commands[key] = retained
        let result = try await executeAsyncControl(retained)
        asyncControlState.commands[key] = nil
        try requireAsyncSettlement(result)
        return result
    }

    private func requireAsyncSettlement(_ result: PickyAsyncTaskCommandResult) throws {
        guard result.outcome == .settled else { throw PickyAsyncControlError.outcome(result.outcome, reason: result.reason) }
    }
}
