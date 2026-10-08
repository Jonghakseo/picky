//
//  PickyCliSessionCoordinator.swift
//  Picky
//
//  Owns everything the `picky` CLI asks the app to do with a Pickle session:
//  answering `pickleBridgeRequested`, confirming which runtime session a CLI
//  invocation belongs to, and routing a display-name change to the daemon that
//  owns the session.
//
//  It is deliberately not part of `PickyAgentClientRouter`. The router owns
//  transport, child lifecycle, and projection ownership; this owns the CLI
//  session contract and reaches the router only through `PickyCliSessionHost`.
//

import Foundation

/// What the owning daemon actually persisted for a rename, as it reported it.
/// `revision` is absent when the owner does not publish one.
struct PickyRenameCommit: Equatable {
    let session: PickyAgentSession
    let revision: Int?
}

/// Single rename path shared by the CLI bridge and the app's own title editing,
/// so a Pickle's display name is always written by its owning daemon and never
/// by a steered `/name` message.
@MainActor
protocol PickyPickleTitleRenaming: AnyObject {
    /// Returns the session the owning daemon committed. Throws when the owner
    /// is unavailable, rejects the rename, or the commit cannot be confirmed
    /// in the app's own projection.
    @discardableResult
    func renamePickleTitle(sessionId: String, title: String, callerContext: PickyCliCallerContext?) async throws -> PickyAgentSession?
}

enum PickyCliSessionError: LocalizedError, Equatable {
    case invalidPickleTitle(reason: String)
    case renameCallerMismatch(sessionId: String)
    case renameOwnerUnavailable(sessionId: String)
    case renameOutcomeUnconfirmed(sessionId: String)
    case cliCallerNotProjected(sessionId: String)
    case sessionOperationBusy(sessionId: String, operation: String)
    case dockGroupsUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPickleTitle(let reason): reason
        case .renameCallerMismatch(let sessionId): "The calling Pickle does not match session \(sessionId)."
        case .renameOwnerUnavailable(let sessionId):
            "Pickle \(sessionId) is starting or stopping its runtime. Try the rename again in a moment."
        case .renameOutcomeUnconfirmed(let sessionId):
            "The rename result is unconfirmed for Pickle \(sessionId). Check its name before retrying. If session actions remain blocked, reopen Picky."
        case .cliCallerNotProjected(let sessionId): "Picky does not have a Pickle for session \(sessionId) yet."
        case .sessionOperationBusy(let sessionId, let operation):
            "Pickle \(sessionId) is busy with another operation (\(operation)). Try again in a moment."
        case .dockGroupsUnavailable: "Picky cannot read Pickle groups right now."
        }
    }
}

/// The transport, ownership, and projection facts this coordinator needs. The
/// router supplies them; nothing here reaches back into child lifecycle state
/// directly.
@MainActor
protocol PickyCliSessionHost: AnyObject {
    var primaryClient: PickyAgentClient { get }
    var pool: PickyAgentDaemonPool { get }
    var sessionOperationGate: PickySessionExclusiveOperationGate { get }
    var asyncOwnerControl: PickyAsyncOwnerControlCoordinator { get }
    var permanentDeletionAcknowledgementTimeout: TimeInterval { get }
    var dockGroupsProvider: (() async -> [PickyDockGroupPayload])? { get }
    var dockGroupsManager: ((PickyDockGroupManagementRequest) async throws -> [PickyDockGroupPayload])? { get }
    var pickleDeletionCleanupHandler: ((String) async throws -> Void)? { get }
    var completionNotificationCoordinator: PickyCompletionNotificationCoordinator? { get }

    func pickleSessionSummary(id: String) -> PickyAgentSession?
    func cachedPickleSessionSummaries() -> [PickyAgentSession]
    /// The live child websocket for a session, or nil when no child daemon is
    /// currently running it. Never spawns.
    func liveChildClient(for sessionId: String) -> PickyAgentClient?
    /// True when a child daemon owns this session's scope, running or not.
    func isChildOwnedSession(_ sessionId: String) -> Bool
    /// Throws unless the session currently has no child daemon in any state.
    func requireNoChildRuntime(sessionId: String) throws
    func releaseChild(sessionId: String)
    func send(_ command: PickyCommandEnvelope) async throws
    func sendAwaitingError(
        _ command: PickyCommandEnvelope,
        timeout: TimeInterval,
        requireAcknowledgement: Bool,
        on targetClient: PickyAgentClient?
    ) async throws -> PickyErrorEvent?
    func sendAfterCapabilityRegistration(_ command: PickyCommandEnvelope, on client: PickyAgentClient) async throws
    func completePickleBridge(
        _ request: PickyPickleBridgeRequest,
        on responseClient: PickyAgentClient,
        sessions: [PickyAgentSession]?,
        groups: [PickyDockGroupPayload]?,
        session: PickyAgentSession?,
        delivered: Bool?,
        errorMessage: String?
    ) async
}

@MainActor
final class PickyCliSessionCoordinator: PickyPickleTitleRenaming {
    weak var host: PickyCliSessionHost?

    /// Latest projection revision the app has applied for a session. A rename
    /// is confirmed against this ordering, so a second rename arriving first
    /// still settles the earlier one instead of waiting for text that will
    /// never be shown.
    var projectedSessionRevisionProvider: ((String) -> Int?)?

    /// Inner budgets for CLI identity and rename. Their sum stays below the
    /// daemon's bridge request timeout so the app answers before the CLI gives
    /// up and the caller never sees a bare transport timeout.
    var callerValidationTimeout: TimeInterval = 3
    var renameAcknowledgementTimeout: TimeInterval = 4
    var childExitConfirmationTimeout: TimeInterval = 3
    var renameProjectionTimeout: TimeInterval = 3

    /// Correlated owner replies for in-flight rename commands.
    private var pendingRenameCommitHandlers: [String: (PickyRenameCommit) -> Void] = [:]
    /// Waiters parked until the app's own projection catches up with a rename
    /// the owner already committed.
    private var renameWaiters: [String: [UUID: (target: PickyRenameCommit, continuation: CheckedContinuation<Void, Never>)]] = [:]
    /// Renames the owner never answered, keyed by session. Their gate stays
    /// closed, so spawn and delete keep being refused, until the owner finally
    /// answers that exact command. Nothing else may unlock it: a reconnect or a
    /// fresh bootstrap can happen while the same daemon is still writing.
    private var unsettledRenames: [String: String] = [:]

    // MARK: - Bridge requests

    func handleBridgeRequest(_ request: PickyPickleBridgeRequest, responseClient: PickyAgentClient) async {
        do {
            guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
            switch request.operation {
            case .listSessions:
                let groups = await host.dockGroupsProvider?() ?? []
                await complete(request, on: responseClient, sessions: host.cachedPickleSessionSummaries(), groups: groups)
            case .resolveCaller:
                guard let callerContext = request.callerContext else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let session = try await resolveCliCaller(callerContext)
                // Group membership is part of the identity answer, so a missing
                // provider is a failure rather than "this Pickle has no group".
                guard let dockGroupsProvider = host.dockGroupsProvider else { throw PickyCliSessionError.dockGroupsUnavailable }
                let groups = await dockGroupsProvider()
                await complete(request, on: responseClient, groups: groups, session: session, delivered: true)
            case .rename:
                guard let sessionId = request.sessionId, let title = request.title else {
                    throw PickyAgentClientRouterError.invalidBridgeRequest
                }
                let session = try await renamePickleTitle(sessionId: sessionId, title: title, callerContext: request.callerContext)
                let groups = await host.dockGroupsProvider?() ?? []
                await complete(request, on: responseClient, groups: groups, session: session, delivered: true)
            case .steer, .followUp:
                guard let sessionId = request.sessionId, let text = request.text else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let commandType: PickyCommandType = request.operation == .steer ? .steer : .followUp
                try await host.send(PickyCommandEnvelope(type: commandType, sessionId: sessionId, text: text))
                await complete(request, on: responseClient, session: host.pickleSessionSummary(id: sessionId))
            case .abort:
                guard let sessionId = request.sessionId else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                try await host.asyncOwnerControl.bridgeAbort(sessionID: sessionId, tracked: host.pickleSessionSummary(id: sessionId)?.hasAsyncTracking == true)
                await complete(request, on: responseClient, session: host.pickleSessionSummary(id: sessionId))
            case .setArchived:
                guard let sessionId = request.sessionId, let archived = request.archived else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                try await host.asyncOwnerControl.bridgeArchive(sessionID: sessionId, archived: archived, mode: request.archiveMode,
                    tracked: host.pickleSessionSummary(id: sessionId)?.hasAsyncTracking == true)
                await complete(request, on: responseClient, session: host.pickleSessionSummary(id: sessionId), delivered: true)
            case .delete:
                guard let sessionId = request.sessionId,
                      let finalizeDeletion = host.pickleDeletionCleanupHandler else {
                    throw PickyAgentClientRouterError.invalidBridgeRequest
                }
                // Deletion must not interleave with a spawn or a rename write
                // for the same session, through acknowledgement and cleanup.
                try await host.sessionOperationGate.run(.delete, sessionID: sessionId) {
                    try await host.asyncOwnerControl.deleteSession(sessionID: sessionId, timeout: host.permanentDeletionAcknowledgementTimeout)
                    try await finalizeDeletion(sessionId)
                    host.releaseChild(sessionId: sessionId)
                }
                await complete(request, on: responseClient, sessions: host.cachedPickleSessionSummaries(), delivered: true)
            case .manageGroups:
                guard let action = request.groupAction,
                      let manager = host.dockGroupsManager else {
                    throw PickyAgentClientRouterError.invalidBridgeRequest
                }
                let groups = try await manager(PickyDockGroupManagementRequest(
                    action: action,
                    groupId: request.groupId,
                    name: request.name,
                    sessionIds: request.sessionIds ?? [],
                    archiveMode: request.archiveMode
                ))
                await complete(request, on: responseClient, groups: groups)
            case .notifyMainOfPickleCompletion:
                // New children provide a durable completion envelope. The app
                // chooses destination before any primary-agent prompt is sent.
                let projectedSession = request.sessionId.flatMap { host.pickleSessionSummary(id: $0) }
                if let envelope = request.completionEnvelope(projectedSession: projectedSession),
                   let coordinator = host.completionNotificationCoordinator {
                    _ = try await coordinator.route(envelope)
                    await complete(request, on: responseClient, delivered: true)
                    return
                }
                // Retain a narrow transport fallback for router clients that
                // predate the app-owned coordinator. Installed apps always
                // configure it during launch.
                guard let sessionId = request.sessionId, let prompt = request.prompt else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                try await host.sendAfterCapabilityRegistration(PickyCommandEnvelope(
                    type: .notifyMainOfPickleCompletion,
                    sessionId: sessionId,
                    cwd: request.cwd,
                    prompt: prompt
                ), on: host.primaryClient)
                await complete(request, on: responseClient, delivered: true)
            }
        } catch {
            await complete(request, on: responseClient, errorMessage: error.localizedDescription)
        }
    }

    private func complete(
        _ request: PickyPickleBridgeRequest,
        on responseClient: PickyAgentClient,
        sessions: [PickyAgentSession]? = nil,
        groups: [PickyDockGroupPayload]? = nil,
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        errorMessage: String? = nil
    ) async {
        await host?.completePickleBridge(
            request,
            on: responseClient,
            sessions: sessions,
            groups: groups,
            session: session,
            delivered: delivered,
            errorMessage: errorMessage
        )
    }

    // MARK: - Owner replies

    /// Correlated owner traffic. A reply that arrives after its caller gave up
    /// still settles that session's held gate, which is the only definitive
    /// answer the app will get.
    func observe(_ event: PickyEvent) {
        switch event {
        case .error(let error):
            if let commandId = error.commandId { settleRename(commandId: commandId) }
        case .ack(let ack):
            settleRename(commandId: ack.commandId)
        case .pickleSessionUpdated(let commandId, let session, let revision):
            settleRename(commandId: commandId)
            pendingRenameCommitHandlers[commandId]?(PickyRenameCommit(session: session, revision: revision))
        default:
            break
        }
    }

    /// Called after the registry committed a projection publication.
    func projectionDidChange() {
        for sessionId in Array(renameWaiters.keys) {
            let matched = renameWaiters[sessionId]?.filter {
                hasProjectedRename(sessionId: sessionId, commit: $0.value.target)
            } ?? [:]
            guard !matched.isEmpty else { continue }
            for waiterID in matched.keys { renameWaiters[sessionId]?.removeValue(forKey: waiterID) }
            if renameWaiters[sessionId]?.isEmpty == true { renameWaiters[sessionId] = nil }
            for waiter in matched.values { waiter.continuation.resume() }
        }
    }

    // MARK: - CLI identity

    /// Confirms the calling runtime session with the daemon that owns it and
    /// returns the Pickle the app already projects for it. Read-only: it never
    /// spawns a child, resumes a runtime, or infers identity from cwd or paths.
    /// The main agent has no Pickle record, so it resolves to `nil`.
    private func resolveCliCaller(_ callerContext: PickyCliCallerContext) async throws -> PickyAgentSession? {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        let sessionId = callerContext.sessionId
        let command = PickyCommandEnvelope(type: .validateCliCaller, callerContext: callerContext)
        if sessionId == PickyCliCallerContext.mainAgentSessionID {
            try await requireOwnerAcknowledgement(command, timeout: callerValidationTimeout, on: host.primaryClient)
            return nil
        }
        // Only the owning daemon holds the binding, so a misrouted validation
        // is rejected rather than mistaken for another session's identity.
        let owner = try ownerClientForLiveSession(sessionId)
        guard host.pickleSessionSummary(id: sessionId) != nil else {
            throw PickyCliSessionError.cliCallerNotProjected(sessionId: sessionId)
        }
        try await requireOwnerAcknowledgement(command, timeout: callerValidationTimeout, on: owner)
        // Re-read after validation: the Pickle may have been renamed, archived,
        // or deleted while the owner answered, and the reply must describe what
        // Picky shows now rather than the pre-ack snapshot.
        guard let current = host.pickleSessionSummary(id: sessionId) else {
            throw PickyCliSessionError.cliCallerNotProjected(sessionId: sessionId)
        }
        return cliSessionSummary(current)
    }

    // MARK: - Rename

    /// Writes a Pickle's display name through its owning daemon and returns the
    /// session exactly as that owner committed it.
    ///
    /// Three routes, one per owner: a live child commits through its own
    /// connection, a Pickle the primary daemon hosts commits through the
    /// primary, and a Pickle whose child is gone is rewritten as stored
    /// metadata. Everything the primary writes runs under the per-session gate,
    /// because a child spawn or a delete would otherwise overlap that commit.
    /// No route ever starts a runtime.
    ///
    /// There is deliberately no "same name" shortcut. Confirming the current
    /// name is what records it as user-chosen, and only the owner can decide
    /// that nothing needs to be written.
    @discardableResult
    func renamePickleTitle(sessionId: String, title: String, callerContext: PickyCliCallerContext?) async throws -> PickyAgentSession? {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        let normalized: String
        switch PickyPickleRenamePolicy.normalizedTitle(title) {
        case .success(let value): normalized = value
        case .failure(let rejection): throw PickyCliSessionError.invalidPickleTitle(reason: rejection.message)
        }
        if let callerContext, callerContext.sessionId != sessionId {
            throw PickyCliSessionError.renameCallerMismatch(sessionId: sessionId)
        }

        let commit: PickyRenameCommit
        if let liveChild = host.liveChildClient(for: sessionId) {
            commit = try await commitRenameThroughOwner(
                PickyCommandEnvelope(type: .renameSession, sessionId: sessionId, title: normalized, callerContext: callerContext),
                on: liveChild
            )
        } else if callerContext != nil {
            // `--self` always comes from a live runtime. The primary daemon
            // hosts every Pickle that never got its own child (CLI, handoff,
            // pinned), so only a child-scoped session with no live child is
            // genuinely ownerless here.
            guard !host.isChildOwnedSession(sessionId) else {
                throw PickyCliSessionError.renameOwnerUnavailable(sessionId: sessionId)
            }
            commit = try await commitRenameThroughPrimary(
                PickyCommandEnvelope(type: .renameSession, sessionId: sessionId, title: normalized, callerContext: callerContext),
                sessionId: sessionId
            )
        } else {
            let type: PickyCommandType = host.isChildOwnedSession(sessionId) ? .renameStoredPickle : .renameSession
            commit = try await commitRenameThroughPrimary(
                PickyCommandEnvelope(type: type, sessionId: sessionId, title: normalized),
                sessionId: sessionId
            )
        }

        try await waitForProjectedRename(sessionId: sessionId, commit: commit)
        return cliSessionSummary(commit.session)
    }

    /// `/name` typed into a Pickle conversation. It is Picky metadata, so it is
    /// turned into a rename here instead of being routed as input: a steer or
    /// follow-up would respawn a stopped Pickle's daemon just to change a
    /// label. Returns false for anything that must follow the normal path.
    @discardableResult
    func applyTypedRenameIfNeeded(_ command: PickyCommandEnvelope) async throws -> Bool {
        guard let sessionId = command.sessionId,
              let requested = Self.typedRenameArgument(in: command),
              host?.pickleSessionSummary(id: sessionId) != nil else { return false }
        try await renamePickleTitle(sessionId: sessionId, title: requested, callerContext: nil)
        return true
    }

    /// The argument of a `/name` command, or nil when this is not one. Mirrors
    /// the daemon's `^\s*\/name(\s|$)`, so the two ends agree on what counts as
    /// a rename rather than conversation text.
    static func typedRenameArgument(in command: PickyCommandEnvelope) -> String? {
        guard command.type == .steer || command.type == .followUp, let text = command.text else { return nil }
        let isWhitespace: (Character) -> Bool = { character in
            character.unicodeScalars.allSatisfy { scalar in
                scalar.properties.generalCategory == .spaceSeparator
                    || (0x09...0x0D).contains(scalar.value)
                    || [0x2028, 0x2029, 0xFEFF].contains(scalar.value)
            }
        }
        let leading = text.drop(while: isWhitespace)
        guard leading.hasPrefix("/name") else { return nil }
        let rest = leading.dropFirst("/name".count)
        guard rest.isEmpty || rest.first.map(isWhitespace) == true else { return nil }
        return String(rest.drop { $0 == " " || $0 == "\t" })
    }

    /// Sends an owner-local rename and returns the owner's own committed
    /// result. The daemon unicasts `pickleSessionUpdated` before its ack, so
    /// the reply describes what was persisted instead of whatever the app
    /// happened to have cached.
    private func commitRenameThroughOwner(
        _ command: PickyCommandEnvelope,
        on client: PickyAgentClient
    ) async throws -> PickyRenameCommit {
        var committed: PickyRenameCommit?
        pendingRenameCommitHandlers[command.id] = { committed = $0 }
        defer { pendingRenameCommitHandlers.removeValue(forKey: command.id) }
        do {
            try await requireOwnerAcknowledgement(command, timeout: renameAcknowledgementTimeout, on: client)
        } catch {
            if Self.isDefinitiveRejection(error) { throw error }
            throw PickyCliSessionError.renameOutcomeUnconfirmed(sessionId: command.sessionId ?? "")
        }
        guard let committed else {
            throw PickyCliSessionError.renameOutcomeUnconfirmed(sessionId: command.sessionId ?? "")
        }
        return committed
    }

    /// Every rename the primary daemon performs, live or stored. The gate
    /// excludes a concurrent spawn or delete, the last child's Node process
    /// must have actually exited before the write, and child absence is
    /// re-checked afterwards so a child that appeared during the round trip is
    /// reported instead of being written around.
    ///
    /// Once the command is dispatched, only a correlated rejection releases the
    /// gate. Anything else, including a dropped socket, leaves the write
    /// possibly in flight, so the session stays closed until the owner answers
    /// that command.
    private func commitRenameThroughPrimary(
        _ command: PickyCommandEnvelope,
        sessionId: String
    ) async throws -> PickyRenameCommit {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        guard host.pickleSessionSummary(id: sessionId) != nil else {
            throw PickyCliSessionError.cliCallerNotProjected(sessionId: sessionId)
        }
        try host.sessionOperationGate.begin(.offlineRename, sessionID: sessionId)
        var dispatched = false
        var ownerAnswered = false
        do {
            try await confirmChildRuntimeStopped(sessionId: sessionId)
            dispatched = true
            let commit = try await commitRenameThroughOwner(command, on: host.primaryClient)
            ownerAnswered = true
            host.sessionOperationGate.end(.offlineRename, sessionID: sessionId)
            try host.requireNoChildRuntime(sessionId: sessionId)
            return commit
        } catch {
            if dispatched, !ownerAnswered, !Self.isDefinitiveRejection(error) {
                unsettledRenames[sessionId] = command.id
                pickyAgentRouterLog("rename unresolved session=\(sessionId) command=\(command.id) gate=held")
            } else {
                host.sessionOperationGate.end(.offlineRename, sessionID: sessionId)
            }
            throw error
        }
    }

    /// A rejection the owner sent for this exact command is the only definitive
    /// "nothing was written" after dispatch.
    private static func isDefinitiveRejection(_ error: Error) -> Bool {
        if case .bridgeCommandRejected = error as? PickyAgentClientRouterError { return true }
        return false
    }

    private func settleRename(commandId: String) {
        guard let sessionId = unsettledRenames.first(where: { $0.value == commandId })?.key else { return }
        unsettledRenames.removeValue(forKey: sessionId)
        host?.sessionOperationGate.end(.offlineRename, sessionID: sessionId)
        pickyAgentRouterLog("rename settled session=\(sessionId) command=\(commandId) gate=released")
    }

    /// Resolves the connection that can answer for a live session without
    /// spawning anything. A child that is mid-spawn or mid-teardown has no
    /// stable owner, so the caller gets an explicit retryable failure.
    private func ownerClientForLiveSession(_ sessionId: String) throws -> PickyAgentClient {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        if let liveChild = host.liveChildClient(for: sessionId) { return liveChild }
        try host.requireNoChildRuntime(sessionId: sessionId)
        return host.primaryClient
    }

    /// Stronger than `requireNoChildRuntime`: it also waits for the last child
    /// daemon's Node process to really exit. Releasing a child drops its
    /// bookkeeping immediately, but the process keeps writing its session file
    /// until it is gone, so an absent endpoint is not proof that the primary is
    /// the only writer.
    private func confirmChildRuntimeStopped(sessionId: String) async throws {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        try host.requireNoChildRuntime(sessionId: sessionId)
        guard await host.pool.awaitChildProcessExit(sessionId: sessionId, timeout: childExitConfirmationTimeout) else {
            throw PickyCliSessionError.renameOwnerUnavailable(sessionId: sessionId)
        }
        try host.requireNoChildRuntime(sessionId: sessionId)
    }

    /// Sends an owner-local command and requires a positive acknowledgement.
    /// A timeout is never treated as success here: these commands decide
    /// identity and durable state.
    private func requireOwnerAcknowledgement(
        _ command: PickyCommandEnvelope,
        timeout: TimeInterval,
        on client: PickyAgentClient
    ) async throws {
        guard let host else { throw PickyAgentClientRouterError.routerUnavailable }
        if let rejection = try await host.sendAwaitingError(command, timeout: timeout, requireAcknowledgement: true, on: client) {
            throw PickyAgentClientRouterError.bridgeCommandRejected(rejection.message)
        }
    }

    /// Blocks until the app's projection reaches the revision the owner
    /// committed. A commit the app cannot observe is reported as unconfirmed:
    /// the write may be durable, but Picky must not claim a rename it is not
    /// showing.
    private func waitForProjectedRename(sessionId: String, commit: PickyRenameCommit) async throws {
        if hasProjectedRename(sessionId: sessionId, commit: commit) { return }
        let waiterID = UUID()
        let timeoutNanoseconds = UInt64(max(renameProjectionTimeout, 0) * 1_000_000_000)
        await withCheckedContinuation { continuation in
            renameWaiters[sessionId, default: [:]][waiterID] = (commit, continuation)
            // The waiter is removed before it is resumed, so whichever arrives
            // first wins and the loser is a no-op.
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                self?.cancelRenameWaiter(sessionId: sessionId, waiterID: waiterID)
            }
        }
        guard hasProjectedRename(sessionId: sessionId, commit: commit) else {
            throw PickyCliSessionError.renameOutcomeUnconfirmed(sessionId: sessionId)
        }
    }

    /// Ordering, not text: a later rename that already superseded this one
    /// still proves the commit reached the app, while the same title at an
    /// older revision proves nothing.
    private func hasProjectedRename(sessionId: String, commit: PickyRenameCommit) -> Bool {
        guard let committedRevision = commit.revision,
              let projectedRevision = projectedSessionRevisionProvider?(sessionId) else { return false }
        return projectedRevision >= committedRevision
    }

    private func cancelRenameWaiter(sessionId: String, waiterID: UUID) {
        let waiter = renameWaiters[sessionId]?.removeValue(forKey: waiterID)
        if renameWaiters[sessionId]?.isEmpty == true { renameWaiters[sessionId] = nil }
        waiter?.continuation.resume()
    }

    /// CLI replies carry session metadata, never the message journal.
    private func cliSessionSummary(_ session: PickyAgentSession) -> PickyAgentSession {
        var summary = session
        summary.messages = []
        summary.messageJournalAvailable = false
        return summary
    }
}
