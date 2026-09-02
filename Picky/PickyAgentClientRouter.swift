//
//  PickyAgentClientRouter.swift
//  Picky
//
//  Phase 2 of the per-Pickle agentd plan: routes commands to either the primary
//  websocket client or a per-child websocket client keyed by sessionId.
//

import Foundation

/// Factory abstraction so tests can substitute a stub client. In production the router uses
/// `WebSocketPickyAgentClient`, which connects to the URL exposed by the daemon pool entry.
protocol PickyAgentClientFactoryProtocol {
    func makeClient(endpoint: URL, token: String) -> PickyAgentClient
}

struct DefaultPickyAgentClientFactory: PickyAgentClientFactoryProtocol {
    func makeClient(endpoint: URL, token: String) -> PickyAgentClient {
        let port = endpoint.port ?? 17631
        let host = endpoint.host ?? "127.0.0.1"
        return WebSocketPickyAgentClient(
            configuration: WebSocketPickyAgentClient.Configuration(
                host: host,
                port: port,
                token: token
            )
        )
    }
}

@MainActor
protocol PickyManualPickleChildSpawning: AnyObject {
    func spawnManualPickleChildClient(sessionId: String, cwd: String) async throws -> any PickyAgentClient
}

/// Lets non-router collaborators (e.g. `PickySessionListViewModel`) release a child daemon
/// without depending on the concrete router type.
@MainActor
protocol PickyChildSessionReleasing: AnyObject {
    func releaseChild(sessionId: String)
}

/// Lets the projection recovery coordinator escalate a stalled session without
/// depending on the concrete router type.
@MainActor
protocol PickyProjectionOwnerReconnecting: AnyObject {
    func reconnectProjectionOwner(sessionID: String)
}

/// Routes Picky commands to the right websocket client. Phase 2 vertical-slice intentionally
/// keeps a single primary connection alive at all times; child connections are created on
/// demand and torn down when the Pickle ends or the pool releases the child.
@MainActor
final class PickyAgentClientRouter: PickyAgentClient, PickyManualPickleChildSpawning, PickyChildSessionReleasing, PickyProjectionOwnerReconnecting {
    private let primaryClient: PickyAgentClient
    private let pool: PickyAgentDaemonPool
    private let clientFactory: PickyAgentClientFactoryProtocol
    private let handoffPickleSessionIdFactory: () -> String
    private let permanentDeletionAcknowledgementTimeout: TimeInterval
    /// The router may advertise the v2 socket dialect only when its consumer
    /// is wired to the registry-backed projection storage.
    private let supportsSessionProjectionV2: Bool
    private var childClients: [String: PickyAgentClient] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    /// Owned by `PickyAgentClientRouter+CapabilityRegistration.swift`. Not
    /// private only because Swift has no visibility narrower than `internal`
    /// that spans two files.
    enum CapabilityRegistrationState: Equatable {
        case awaitingConnection
        case registering
        case registered
    }
    var capabilityRegistrationStates: [String: CapabilityRegistrationState] = [:]
    var capabilityRegistrationWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    var capabilityRegistrationCommandIDs: [String: String] = [:]
    var capabilityRegistrationRetryCounts: [String: Int] = [:]
    private var lastProjectionOwnerReconnects: [String: Date] = [:]
    private static let projectionOwnerReconnectDebounce: TimeInterval = 30
    var clientEventKeys: [ObjectIdentifier: String] = [:]
    let capabilityRegistrationTimeoutNanoseconds: UInt64
    let capabilityRegistrationRetryBackoffNanoseconds: UInt64
    static let maximumCapabilityRegistrationRetries = 3
    private var primaryConnectStarted = false
    private var knownChildSessionIds = Set<String>()
    private var bootingChildSessionIds = Set<String>()
    private var retiredChildSessionIds = Set<String>()
    /// A child session may be respawned with the same id while an old queued
    /// command drain is still unwinding. Lifecycle state for that drain must
    /// therefore be owned by a monotonically increasing child generation,
    /// rather than the mutable session-level retired set.
    private var childGenerations: [String: Int] = [:]
    private var retiredChildGenerations = Set<ChildGeneration>()
    /// v1 compatibility mirror. v2 bridge reads are supplied by the registry
    /// storage and never apply projection mutations in this router.
    private var sessionCache: [String: PickyAgentSession] = [:]
    private var sessionOwnerKeys: [String: String] = [:]
    /// V2 snapshots do not populate the legacy cache, so maintain their owner
    /// provenance independently for owner-scoped bootstrap reconciliation.
    private var projectionOwnerKeys: [String: String] = [:]
    private var projectionConnectionGenerations: [String: Int] = [:]
    private var projectionBootstrapExpectations: [String: ProjectionBootstrapExpectation] = [:]
    /// Last primary epoch observed on this daemon process. It intentionally
    /// survives a socket reconnect so released-child ownership can distinguish
    /// a reconnect from a daemon restart.
    private var knownPrimaryProjectionEpoch: String?
    /// A released child is transferred to primary ownership, but primary
    /// membership exclusion is not authoritative until a different primary
    /// epoch proves a daemon restart rehydrated the shared store.
    private var retiredChildPrimaryOwnerships: [String: RetiredChildPrimaryOwnership] = [:]
    /// Child membership completion is destructive only after this connection
    /// generation has produced its configured session snapshot.
    private var sessionProducingProjectionConnections = Set<ProjectionConnectionKey>()
    private var acceptedProjectionBootstrapCompletions = Set<ProjectionBootstrapCompletionKey>()
    private var sessionProjectionWaiters: [String: [UUID: CheckedContinuation<Void, Never>]] = [:]
    /// Commands typed against a freshly spawned Pickle before the child runtime has left
    /// `.queued`. They are drained in order once the child emits its first non-queued
    /// `sessionUpdated`, avoiding early follow-up/steer sends while the Pi process is still
    /// bootstrapping.
    private var pendingChildCommands: [String: [PickyCommandEnvelope]] = [:]
    /// Commands removed from `pendingChildCommands` by a currently running
    /// drain. Keeping the not-yet-sent remainder here lets child termination
    /// fail it immediately instead of letting the drain requeue it after the
    /// child has already disappeared.
    private var activeDrainingChildCommands: [String: ChildCommandDrain] = [:]
    /// Per-command resolution callbacks keyed by `PickyCommandEnvelope.id`.
    /// Populated by `sendAwaitingError`; invoked by the event forwarder when
    /// the daemon emits a `type="error"` (rejection, non-nil argument) or
    /// `type="ack"` (success, nil argument) event whose `commandId` matches a
    /// pending registration. Cleared by the timeout race in
    /// `sendAwaitingError` if neither arrives, so this never grows
    /// unboundedly.
    private var pendingErrorHandlers: [String: (PickyErrorEvent?) -> Void] = [:]
    /// Active `events` subscribers, keyed by a per-call UUID. The HUD view
    /// model and `CompanionManager` both subscribe to the same router so
    /// outbound commands and inbound events stay consistent across the
    /// app; that requires the events stream to broadcast every event to
    /// every active subscriber instead of dropping it onto a single
    /// shared continuation (the previous behavior, which silently dropped
    /// the second subscriber on the floor).
    private var subscriberContinuations: [UUID: AsyncStream<PickyClientEvent>.Continuation] = [:]
    /// Last lifecycle event observed on the primary connection. Replayed
    /// to subscribers that attach *after* the daemon has already
    /// connected, so e.g. `CompanionManager` — which subscribes after
    /// the HUD has already kicked off `router.connect()` — still runs its
    /// `.connected` bootstrap (model list / main messages fetch) instead
    /// of staying stuck in a "loading" UI. `.connected` and
    /// `.disconnected` are the only events worth replaying: routine
    /// session/tool events past the subscription point are irrelevant by
    /// definition, and replaying them could double-process work.
    private var lastLifecycleEvent: PickyClientEvent?

    private struct ChildGeneration: Hashable {
        let sessionId: String
        let value: Int
    }

    private struct ProjectionBootstrapExpectation {
        let connectionGeneration: Int
        let bootstrapID: String
        var epoch: String?
        /// A bootstrap that observes more than one epoch cannot prove a
        /// coherent membership cutover. It remains poisoned until reconnect.
        var failed = false
    }

    private struct ProjectionConnectionKey: Hashable {
        let ownerKey: String
        let connectionGeneration: Int
    }

    private struct RetiredChildPrimaryOwnership {
        /// `nil` is intentionally conservative: without a known release epoch,
        /// a primary completion cannot prove the child record was rehydrated.
        let primaryEpochAtRelease: String?
    }

    private struct ProjectionBootstrapCompletionKey: Hashable {
        let ownerKey: String
        let connectionGeneration: Int
        let bootstrapID: String
        let epoch: String
    }

    private struct ChildCommandDrain {
        let generation: ChildGeneration
        var commands: [PickyCommandEnvelope]
    }

    /// Each access to `events` allocates a new subscriber stream, registered
    /// in `subscriberContinuations` for the lifetime of the for-await loop.
    /// `disconnect()` finishes every registered continuation so consumers
    /// terminate cleanly even though `AsyncStream` does not honor task
    /// cancellation on its own.
    var events: AsyncStream<PickyClientEvent> {
        AsyncStream { continuation in
            let id = UUID()
            // The class is `@MainActor`-isolated and `events` is only ever
            // accessed from MainActor, so the AsyncStream init closure runs
            // synchronously on the MainActor and we can register the
            // subscriber immediately. This matters — if registration were
            // deferred via a `Task` the next broadcast could land before
            // the new subscriber is wired up.
            self.subscriberContinuations[id] = continuation
            // Replay the last lifecycle event so that subscribers attaching
            // after the daemon has already connected still observe
            // `.connected` (and trigger their bootstrap handlers).
            if let lastLifecycleEvent = self.lastLifecycleEvent {
                continuation.yield(lastLifecycleEvent)
            }
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.subscriberContinuations[id] = nil
                }
            }
        }
    }

    /// Fan an event out to every active `events` subscriber. Used in place
    /// of the previous single `continuation.yield` so that the HUD view
    /// model and the Picky CompanionManager can both observe the same
    /// stream of daemon events without one of them silently missing
    /// updates.
    func broadcast(_ event: PickyClientEvent) {
        // Latch lifecycle transitions so late subscribers can replay them.
        switch event {
        case .connected, .disconnected:
            lastLifecycleEvent = event
        case .protocolEvent, .sessionProjectionBootstrapCompletion, .recoverableError:
            break
        }
        for continuation in subscriberContinuations.values {
            continuation.yield(event)
        }
    }

    /// Injects a synthetic event into the same fan-out path the daemon uses.
    /// Lives here — not on the underlying transport — so callers don't have
    /// to round-trip through the websocket to surface UI-only events. The
    /// onboarding overlay uses this to drive a scripted Pickle into the real
    /// HUD dock without making any actual LLM calls; tests can also exercise
    /// HUD paths the daemon would normally emit.
    func injectScriptedEvent(_ event: PickyClientEvent) {
        broadcast(event)
    }

    /// Hook the user (or PickySessionViewModel in the wiring follow-up) can subscribe to so it
    /// can mark the session as failed when its child daemon disappears. The router itself
    /// releases the cached websocket client; this closure is for additional UI signalling.
    var onChildClientReleased: ((_ sessionId: String, _ exitCode: Int32?) -> Void)?

    /// Async closure invoked when the daemon forwards an `externalEntryRequested`
    /// event from the CLI. The closure must return a fully-assembled
    /// `PickyContextPacket` (or throw). The router then ships it back to the daemon
    /// via `completeExternalEntryRequest`. Left nil during early app boot — until set,
    /// any external entry is rejected with `externalEntryProviderUnavailable`.
    var externalEntryContextProvider: ((PickyExternalEntryRequest) async throws -> PickyContextPacket)?

    /// Async closure invoked when the daemon forwards a CLI-originated PTT
    /// control request (`picky ptt press|release`). The closure should run the
    /// same app-side press/release path as the global keyboard shortcut.
    var pushToTalkControlHandler: ((PickyPushToTalkControlRequest) async throws -> Void)?

    /// Applies a local CLI settings request through app-owned settings stores.
    /// The router only owns the request/reply transport; policy and persistence
    /// remain in the app composition root.
    var pickySettingsControlHandler: ((PickySettingsRequest) async throws -> JSONValue)?

    /// Provides app-owned dock groups for `picky pickle-group-list` and main-agent queries.
    var dockGroupsProvider: (() async -> [PickyDockGroupPayload])?

    /// Registry-backed CLI read model. This is intentionally a read-only
    /// provider: the router never decodes or applies v2 projection mutations.
    var pickleSessionSummariesProvider: (() -> [PickyAgentSession])?

    /// Applies main-agent group mutations through the app-owned dock layout source of truth.
    var dockGroupsManager: ((PickyDockGroupManagementRequest) async throws -> [PickyDockGroupPayload])?

    /// Finalizes local deletion state after the owning child daemon has acknowledged
    /// durable deletion. The handler must not send another delete command.
    var pickleDeletionCleanupHandler: ((String) async throws -> Void)?

    /// Test-only observation hook for router acceptance. Production completion
    /// application must use the ordered `events` stream below, never this hook.
    var onSessionProjectionBootstrapCompletion: ((_ removedSessionIDs: Set<String>, _ ownerKey: String, _ isPrimary: Bool) -> Void)?
    /// Source-aware v2 snapshot observation for the primary loading watchdog.
    /// Projection application still flows through the public event stream.
    var onSessionProjectionSnapshotReceived: ((_ isPrimary: Bool) -> Void)?

    init(
        primaryClient: PickyAgentClient,
        pool: PickyAgentDaemonPool,
        clientFactory: PickyAgentClientFactoryProtocol = DefaultPickyAgentClientFactory(),
        handoffPickleSessionIdFactory: @escaping () -> String = { "session-\(UUID().uuidString)" },
        permanentDeletionAcknowledgementTimeout: TimeInterval = 5,
        supportsSessionProjectionV2: Bool = false,
        capabilityRegistrationTimeoutNanoseconds: UInt64 = 10_000_000_000,
        capabilityRegistrationRetryBackoffNanoseconds: UInt64 = 1_000_000_000
    ) {
        self.capabilityRegistrationTimeoutNanoseconds = capabilityRegistrationTimeoutNanoseconds
        self.capabilityRegistrationRetryBackoffNanoseconds = capabilityRegistrationRetryBackoffNanoseconds
        self.primaryClient = primaryClient
        self.pool = pool
        self.clientFactory = clientFactory
        self.handoffPickleSessionIdFactory = handoffPickleSessionIdFactory
        self.permanentDeletionAcknowledgementTimeout = permanentDeletionAcknowledgementTimeout
        self.supportsSessionProjectionV2 = supportsSessionProjectionV2
        // Drop the cached websocket client (and stop its reconnect loop) the moment the pool
        // notices the underlying child daemon has exited. Without this, the legacy receiveLoop
        // in WebSocketPickyAgentClient would keep reconnecting forever to a dead random port.
        pool.onChildExitAfterReady = { [weak self] sessionId, exitCode in
            guard let self else { return }
            let ownerKey = self.childEventKey(sessionId)
            self.stopForwardingEvents(for: ownerKey)
            self.invalidateProjectionBootstrapExpectation(ownerKey: ownerKey)
            if let client = self.childClients.removeValue(forKey: sessionId) {
                client.disconnect()
            }
            let generation = self.currentChildGeneration(for: sessionId)
            self.failPendingChildCommands(sessionId: sessionId, generation: generation)
            self.bootingChildSessionIds.remove(sessionId)
            self.markChildSessionRetired(sessionId, generation: generation)
            self.onChildClientReleased?(sessionId, exitCode)
        }
    }

    func connect() async {
        startForwardingEvents(from: primaryClient, key: "primary", forwardsLifecycleEvents: true)
        guard !primaryConnectStarted else { return }
        primaryConnectStarted = true
        await primaryClient.connect()
    }

    func submit(_ submission: PickyAgentSubmission) async throws -> PickyAgentSubmissionReceipt {
        try await primaryClient.submit(submission)
    }

    func send(_ command: PickyCommandEnvelope) async throws {
        if enqueueIfChildIsBooting(command) { return }
        try await sendAfterCapabilityRegistration(command, on: connectedClient(for: command.sessionId))
    }

    /// Primary + every currently cached child client. Children booting in the
    /// queued-command path are intentionally excluded because they don't have
    /// a live websocket yet; once they connect they'll receive a fresh
    /// broadcast on the next Reload click.
    var broadcastTargetCount: Int {
        1 + childClients.count
    }

    /// Fan a sessionless command out to the primary daemon and every active
    /// child daemon in parallel. Returns the count of clients that accepted
    /// `send` without throwing. Throws only when every target failed so the
    /// caller surfaces a real "could not deliver to any daemon" error instead
    /// of a silent success.
    func broadcast(_ command: PickyCommandEnvelope) async throws -> Int {
        var targets: [PickyAgentClient] = [primaryClient]
        targets.append(contentsOf: childClients.values)
        guard !targets.isEmpty else { return 0 }
        let results = await withTaskGroup(of: Result<Void, Error>.self, returning: [Result<Void, Error>].self) { group in
            for client in targets {
                group.addTask {
                    do {
                        try await self.sendAfterCapabilityRegistration(command, on: client)
                        return .success(())
                    } catch {
                        return .failure(error)
                    }
                }
            }
            var collected: [Result<Void, Error>] = []
            for await result in group { collected.append(result) }
            return collected
        }
        var successCount = 0
        var firstError: Error?
        for result in results {
            switch result {
            case .success: successCount += 1
            case .failure(let error): firstError = firstError ?? error
            }
        }
        if successCount == 0, let firstError {
            throw firstError
        }
        return successCount
    }

    /// Sends `command` through the right (primary or child) client and races
    /// the daemon's per-command `type="ack"` / `type="error"` events
    /// referencing `command.id` against a `timeout` fallback. agentd unicasts
    /// both to the sender connection, so we intercept them inside
    /// `startForwardingEvents` and dispatch to the per-command handler set
    /// up here.
    ///
    /// Four possible outcomes:
    ///   * Daemon emits a matching `type="ack"` event → returns `nil`
    ///     (confirmed success) as soon as the handler resolved — on
    ///     localhost this is near-immediate, well before `timeout`.
    ///   * Daemon emits a matching `type="error"` event → returns the
    ///     `PickyErrorEvent` so the caller can surface a real failure.
    ///   * Underlying `send` throws (transport dead, missing-child-endpoint,
    ///     encoding error…) → rethrows. The caller's existing `catch`
    ///     turns it into a user-visible error. Returning `nil` here would
    ///     mask a transport failure as success — exactly the silent-success
    ///     class of bug this method exists to prevent.
    ///   * Neither within `timeout` → returns `nil` (treated as success), unless
    ///     `requireAcknowledgement` is true. Strict callers, such as permanent
    ///     deletion, must never finalize local state without a positive ack.
    ///     The heuristic fallback only remains for older, non-destructive
    ///     commands during daemon version skew.
    func sendAwaitingError(
        _ command: PickyCommandEnvelope,
        timeout: TimeInterval = 1.0,
        requireAcknowledgement: Bool = false
    ) async throws -> PickyErrorEvent? {
        let commandId = command.id
        // The handler MUST be installed before `send` is dispatched. agentd
        // unicasts `type="error"` rejections on the same socket during
        // command handling, so on a hot localhost connection the rejection
        // event can be forwarded through the event broker while `send` is
        // still on the call stack. Registering after `send` returns would
        // race that path: a fast rejection would be dropped on the floor
        // and `sendAwaitingError` would silently time out as if the
        // submission succeeded — the exact bug it was added to fix.
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<PickyErrorEvent?, Error>) in
            // `resumed` guards the race between the error-event handler,
            // the send-failure path, and the timeout task. The router is
            // `@MainActor`-isolated so they can't actually run concurrently;
            // the flag just prevents a second arrival from double-resuming
            // the continuation, which would crash.
            var resumed = false
            let resume: (Result<PickyErrorEvent?, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                self.pendingErrorHandlers[commandId] = nil
                continuation.resume(with: result)
            }
            pendingErrorHandlers[commandId] = { resume(.success($0)) }
            Task { @MainActor in
                do {
                    try await self.send(command)
                } catch {
                    // Transport-level send failure — propagate it so the
                    // caller's `catch` block can surface a real error.
                    // Earlier versions resumed with `nil` here, which
                    // callers interpret as success and would re-create
                    // the silent-success bug for any websocket failure.
                    resume(.failure(error))
                    return
                }
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                if requireAcknowledgement {
                    resume(.failure(PickyAgentClientRouterError.commandAcknowledgementTimedOut(commandId: commandId)))
                } else {
                    resume(.success(nil))
                }
            }
        }
    }

    func disconnect() {
        projectionBootstrapExpectations.removeAll()
        knownPrimaryProjectionEpoch = nil
        retiredChildPrimaryOwnerships.removeAll()
        sessionProducingProjectionConnections.removeAll()
        acceptedProjectionBootstrapCompletions.removeAll()
        for task in eventTasks.values { task.cancel() }
        for key in eventTasks.keys { discardCapabilityRegistration(ownerKey: key) }
        eventTasks.removeAll()
        clientEventKeys.removeAll()
        primaryConnectStarted = false
        bootingChildSessionIds.removeAll()
        pendingChildCommands.removeAll()
        activeDrainingChildCommands.removeAll()
        for client in childClients.values { client.disconnect() }
        childClients.removeAll()
        primaryClient.disconnect()
        // Terminate every active subscriber stream so for-await loops
        // exit cleanly. AsyncStream does not honor task cancellation, so
        // forgetting this leaks consumer tasks (and hangs tests).
        for continuation in subscriberContinuations.values { continuation.finish() }
        subscriberContinuations.removeAll()
    }

    /// Returns the client responsible for a session id. If no child has been spawned for the
    /// id (or the id is nil — e.g. main-agent chat), traffic falls back to the primary client
    /// so the Phase 2 vertical slice can ship alongside the legacy single-daemon path.
    func client(for sessionId: String?) -> PickyAgentClient {
        guard let sessionId, let endpoint = pool.endpoint(for: sessionId) else {
            return primaryClient
        }
        if let cached = childClients[sessionId] { return cached }
        let client = clientFactory.makeClient(endpoint: endpoint.url, token: endpoint.token)
        childClients[sessionId] = client
        return client
    }

    /// Like `client(for:)`, but also connects and forwards events when the child endpoint already
    /// exists but this router has no cached websocket (for example after HUD stop/start or a
    /// transient reconnect). Without this, session commands would build a fresh child client and
    /// immediately fail because the websocket task had never been resumed.
    private func connectedClient(for sessionId: String?) async throws -> PickyAgentClient {
        guard let sessionId else { return primaryClient }
        guard let endpoint = pool.endpoint(for: sessionId) else {
            if retiredChildSessionIds.contains(sessionId), let cwd = cachedCwdForRetiredChild(sessionId) {
                return try await spawnChildClient(sessionId: sessionId, cwd: cwd)
            }
            if knownChildSessionIds.contains(sessionId) || retiredChildSessionIds.contains(sessionId) {
                throw PickyAgentClientRouterError.missingChildEndpoint(sessionId: sessionId)
            }
            return primaryClient
        }
        if let cached = childClients[sessionId] { return cached }
        let client = clientFactory.makeClient(endpoint: endpoint.url, token: endpoint.token)
        childClients[sessionId] = client
        startForwardingEvents(from: client, key: childEventKey(sessionId), forwardsLifecycleEvents: false)
        await client.connect()
        return client
    }

    private func cachedCwdForRetiredChild(_ sessionId: String) -> String? {
        guard let cwd = pickleSessionSummary(id: sessionId)?.cwd?.trimmingCharacters(in: .whitespacesAndNewlines), !cwd.isEmpty else { return nil }
        return cwd
    }

    private func enqueueIfChildIsBooting(_ command: PickyCommandEnvelope) -> Bool {
        guard command.type == .followUp || command.type == .steer else { return false }
        guard let sessionId = command.sessionId else { return false }
        let isChildSession = knownChildSessionIds.contains(sessionId) || pool.endpoint(for: sessionId) != nil
        guard isChildSession else { return false }
        let status = pickleSessionSummary(id: sessionId)?.status
        let isBooting = bootingChildSessionIds.contains(sessionId) || status == .queued
        guard isBooting else { return false }
        pendingChildCommands[sessionId, default: []].append(command)
        let statusText = status?.rawValue ?? "not-yet-created"
        pickyAgentRouterLog("queued child command while booting session=\(sessionId) type=\(command.type.rawValue) status=\(statusText)")
        return true
    }

    private func scheduleDrainPendingChildCommandsIfReady(for session: PickyAgentSession) {
        guard session.status != .queued else { return }
        guard pendingChildCommands[session.id]?.isEmpty == false else { return }
        guard isChildEndpointReadyOrNotBooting(sessionId: session.id) else { return }
        Task { @MainActor [weak self] in
            await self?.drainPendingChildCommands(sessionId: session.id)
        }
    }

    private func isChildEndpointReadyOrNotBooting(sessionId: String) -> Bool {
        !bootingChildSessionIds.contains(sessionId) || pool.endpoint(for: sessionId) != nil || childClients[sessionId] != nil
    }

    private func drainPendingChildCommands(sessionId: String) async {
        guard let commands = pendingChildCommands.removeValue(forKey: sessionId), !commands.isEmpty else { return }
        let generation = currentChildGeneration(for: sessionId)
        activeDrainingChildCommands[sessionId] = ChildCommandDrain(generation: generation, commands: commands)
        pickyAgentRouterLog("draining child commands session=\(sessionId) count=\(commands.count)")
        var sentCount = 0
        var commandIsInFlight = false
        do {
            let client = try await connectedClient(for: sessionId)
            for command in commands {
                // Remove the command from the exit-failable remainder only
                // while it is actively being sent. A child exit during this
                // suspension fails the later commands immediately; this
                // command's send result remains authoritative.
                updateActiveDrain(sessionId: sessionId, generation: generation, commands: Array(commands.dropFirst(sentCount + 1)))
                commandIsInFlight = true
                try await sendAfterCapabilityRegistration(command, on: client)
                commandIsInFlight = false
                sentCount += 1

                // A release may have happened while `send` was suspended.
                // Check this drain's immutable generation: a same-id respawn
                // must not make the old drain look transient again.
                if isRetired(generation) || currentChildGeneration(for: sessionId) != generation {
                    clearActiveDrain(sessionId: sessionId, generation: generation)
                    return
                }
            }
            clearActiveDrain(sessionId: sessionId, generation: generation)
        } catch {
            let unsent = Array(commands.dropFirst(sentCount))
            clearActiveDrain(sessionId: sessionId, generation: generation)
            if isRetired(generation) || currentChildGeneration(for: sessionId) != generation {
                // The exit callback has already failed the active remainder.
                // Only an in-flight command was excluded from that remainder,
                // so report it here without double-notifying commands that
                // were still active when the child exited.
                if commandIsInFlight, let failedCommand = unsent.first {
                    failChildCommands([failedCommand])
                }
            } else {
                // A live child can still recover from a transient transport
                // failure, so preserve the original retry queue behavior.
                pendingChildCommands[sessionId, default: []].insert(contentsOf: unsent, at: 0)
                broadcast(.recoverableError("Failed to send queued Pickle input: \(error.localizedDescription)"))
            }
        }
    }

    /// Spawn a child daemon for `sessionId` rooted at `cwd`, then return the per-child client.
    /// Subsequent calls for the same session id return the cached client without re-spawning.
    func spawnChildClient(sessionId: String, cwd: String, primaryUrl: String? = nil) async throws -> PickyAgentClient {
        knownChildSessionIds.insert(sessionId)
        if let existing = childClients[sessionId] { return existing }
        advanceChildGeneration(for: sessionId)
        retiredChildSessionIds.remove(sessionId)
        bootingChildSessionIds.insert(sessionId)
        let endpoint: PickyChildDaemonEndpoint
        do {
            endpoint = try await pool.spawnChild(sessionId: sessionId, cwd: cwd, primaryUrl: primaryUrl)
        } catch {
            bootingChildSessionIds.remove(sessionId)
            throw error
        }
        // A same-ID respawn returns ownership only after the pool has
        // successfully recreated the child. Its current-generation snapshot
        // is still required before completion reconciliation becomes
        // destructive.
        projectionOwnerKeys[sessionId] = childEventKey(sessionId)
        retiredChildPrimaryOwnerships[sessionId] = nil
        let client = clientFactory.makeClient(endpoint: endpoint.url, token: endpoint.token)
        childClients[sessionId] = client
        startForwardingEvents(from: client, key: childEventKey(sessionId), forwardsLifecycleEvents: false)
        await client.connect()
        return client
    }

    func spawnManualPickleChildClient(sessionId: String, cwd: String) async throws -> any PickyAgentClient {
        try await spawnChildClient(sessionId: sessionId, cwd: cwd)
    }

    private func handlePickleHandoffRequest(_ request: PickyPickleHandoffRequest) async {
        let sessionId = handoffPickleSessionIdFactory()
        do {
            let childClient = try await spawnChildClient(sessionId: sessionId, cwd: request.cwd)
            let sessionCreated = Task { @MainActor [weak self] in
                guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
                try await self.waitForSessionUpdated(sessionId: sessionId, timeoutNanoseconds: 5_000_000_000)
            }
            do {
                try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                    type: .createPickleFromHandoff,
                    context: request.context,
                    title: request.title,
                    instructions: request.instructions,
                    cwd: request.cwd
                ), on: childClient)
                try await sessionCreated.value
                await completePickleHandoff(request, sessionId: sessionId)
            } catch {
                sessionCreated.cancel()
                throw error
            }
        } catch {
            releaseChild(sessionId: sessionId)
            await completePickleHandoff(request, errorMessage: error.localizedDescription)
        }
    }

    private func completePickleHandoff(_ request: PickyPickleHandoffRequest, sessionId: String? = nil, errorMessage: String? = nil) async {
        do {
            try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePickleHandoff,
                sessionId: sessionId,
                requestId: request.requestId,
                title: request.title,
                cwd: request.cwd,
                errorMessage: errorMessage
            ), on: primaryClient)
        } catch {
            broadcast(.recoverableError("Failed to complete Pickle handoff: \(error.localizedDescription)"))
        }
    }

    private func waitForSessionUpdated(sessionId: String, timeoutNanoseconds: UInt64) async throws {
        guard pickleSessionSummary(id: sessionId) == nil else { return }
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { [weak self] in
                guard let self else { throw PickyAgentClientRouterError.routerUnavailable }
                await self.waitForProjectionSession(sessionId: sessionId)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: timeoutNanoseconds)
                throw PickyAgentClientRouterError.sessionCreationTimedOut(sessionId: sessionId)
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw PickyAgentClientRouterError.sessionCreationTimedOut(sessionId: sessionId)
            }
        }
    }

    /// Tear down the per-child client and ask the pool to kill the child daemon. Idempotent.
    func releaseChild(sessionId: String) {
        let wasChildSession = knownChildSessionIds.contains(sessionId) || childClients[sessionId] != nil || pool.endpoint(for: sessionId) != nil
        let ownerKey = childEventKey(sessionId)
        stopForwardingEvents(for: ownerKey)
        invalidateProjectionBootstrapExpectation(ownerKey: ownerKey)
        if let client = childClients.removeValue(forKey: sessionId) {
            client.disconnect()
        }
        let generation = currentChildGeneration(for: sessionId)
        failPendingChildCommands(sessionId: sessionId, generation: generation)
        bootingChildSessionIds.remove(sessionId)
        if wasChildSession {
            markChildSessionRetired(sessionId, generation: generation)
        }
        pool.terminateChild(sessionId: sessionId)
    }

    private func currentChildGeneration(for sessionId: String) -> ChildGeneration {
        ChildGeneration(sessionId: sessionId, value: childGenerations[sessionId, default: 0])
    }

    private func advanceChildGeneration(for sessionId: String) {
        childGenerations[sessionId, default: 0] += 1
    }

    private func isRetired(_ generation: ChildGeneration) -> Bool {
        retiredChildGenerations.contains(generation)
    }

    private func updateActiveDrain(sessionId: String, generation: ChildGeneration, commands: [PickyCommandEnvelope]) {
        guard activeDrainingChildCommands[sessionId]?.generation == generation else { return }
        activeDrainingChildCommands[sessionId]?.commands = commands
    }

    private func clearActiveDrain(sessionId: String, generation: ChildGeneration) {
        guard activeDrainingChildCommands[sessionId]?.generation == generation else { return }
        activeDrainingChildCommands[sessionId] = nil
    }

    private func markChildSessionRetired(_ sessionId: String, generation: ChildGeneration) {
        knownChildSessionIds.remove(sessionId)
        retiredChildSessionIds.insert(sessionId)
        retiredChildGenerations.insert(generation)
        // The primary supervisor hydrates scoped child session metadata only
        // after a daemon restart. Transfer ownership now, but retain the
        // current primary epoch so a same-process socket reconnect cannot
        // falsely prune this still-live child record.
        let childOwnerKey = childEventKey(sessionId)
        if projectionOwnerKeys[sessionId] == childOwnerKey {
            projectionOwnerKeys[sessionId] = "primary"
            retiredChildPrimaryOwnerships[sessionId] = RetiredChildPrimaryOwnership(
                primaryEpochAtRelease: knownPrimaryProjectionEpoch
            )
        }
    }

    private func failPendingChildCommands(sessionId: String, generation: ChildGeneration) {
        // Active commands were removed from the pending queue before the
        // drain awaited its first send. They remain ordered ahead of commands
        // that may still be pending, and must be failed through the same
        // command-specific path when the child exits. Never remove an active
        // drain owned by a same-id child that was spawned after this one.
        let activeCommands: [PickyCommandEnvelope]
        if activeDrainingChildCommands[sessionId]?.generation == generation {
            activeCommands = activeDrainingChildCommands.removeValue(forKey: sessionId)?.commands ?? []
        } else {
            activeCommands = []
        }
        let pendingCommands = pendingChildCommands.removeValue(forKey: sessionId) ?? []
        failChildCommands(activeCommands + pendingCommands)
    }

    private func failChildCommands(_ commands: [PickyCommandEnvelope]) {
        for command in commands {
            let error = PickyErrorEvent(
                code: "child_unavailable",
                message: "Pickle child runtime exited before queued input could be delivered.",
                commandId: command.id
            )
            dispatchPendingErrorHandler(error)
            broadcast(.protocolEvent(PickyEventEnvelope(
                id: UUID().uuidString,
                protocolVersion: pickyAgentProtocolVersion,
                timestamp: Date(),
                event: .error(error)
            )))
        }
    }

    private func handlePickleBridgeRequest(_ request: PickyPickleBridgeRequest, responseClient: PickyAgentClient) async {
        do {
            switch request.operation {
            case .listSessions:
                let groups = await dockGroupsProvider?() ?? []
                await completePickleBridge(request, on: responseClient, sessions: cachedPickleSessionSummaries(), groups: groups)
            case .steer, .followUp:
                guard let sessionId = request.sessionId, let text = request.text else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let client = try await connectedClient(for: sessionId)
                let commandType: PickyCommandType = request.operation == .steer ? .steer : .followUp
                try await sendAfterCapabilityRegistration(PickyCommandEnvelope(type: commandType, sessionId: sessionId, text: text), on: client)
                await completePickleBridge(request, on: responseClient, session: pickleSessionSummary(id: sessionId))
            case .abort:
                guard let sessionId = request.sessionId else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let client = try await connectedClient(for: sessionId)
                try await sendAfterCapabilityRegistration(PickyCommandEnvelope(type: .abort, sessionId: sessionId), on: client)
                await completePickleBridge(request, on: responseClient, session: pickleSessionSummary(id: sessionId))
            case .setArchived:
                guard let sessionId = request.sessionId, let archived = request.archived else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let client = try await connectedClient(for: sessionId)
                try await sendAfterCapabilityRegistration(PickyCommandEnvelope(type: .setSessionArchived, sessionId: sessionId, archived: archived), on: client)
                await completePickleBridge(request, on: responseClient, session: pickleSessionSummary(id: sessionId), delivered: true)
            case .delete:
                guard let sessionId = request.sessionId,
                      let finalizeDeletion = pickleDeletionCleanupHandler else {
                    throw PickyAgentClientRouterError.invalidBridgeRequest
                }
                let rejection = try await sendAwaitingError(
                    PickyCommandEnvelope(type: .deleteSession, sessionId: sessionId),
                    timeout: permanentDeletionAcknowledgementTimeout,
                    requireAcknowledgement: true
                )
                if let rejection {
                    throw PickyAgentClientRouterError.bridgeCommandRejected(rejection.message)
                }
                try await finalizeDeletion(sessionId)
                sessionCache[sessionId] = nil
                sessionOwnerKeys[sessionId] = nil
                releaseChild(sessionId: sessionId)
                await completePickleBridge(request, on: responseClient, sessions: cachedPickleSessionSummaries(), delivered: true)
            case .manageGroups:
                guard let action = request.groupAction,
                      let manager = dockGroupsManager else {
                    throw PickyAgentClientRouterError.invalidBridgeRequest
                }
                let groups = try await manager(PickyDockGroupManagementRequest(
                    action: action,
                    groupId: request.groupId,
                    name: request.name,
                    sessionIds: request.sessionIds ?? []
                ))
                await completePickleBridge(request, on: responseClient, groups: groups)
            case .notifyMainOfPickleCompletion:
                // Forward the child-built completion prompt to the primary daemon, which owns
                // the main Picky agent and can followUp on its behalf. The child cannot do this
                // directly because child daemons have no mainRuntime wired in.
                guard let sessionId = request.sessionId, let prompt = request.prompt else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                    type: .notifyMainOfPickleCompletion,
                    sessionId: sessionId,
                    cwd: request.cwd,
                    prompt: prompt
                ), on: primaryClient)
                await completePickleBridge(request, on: responseClient, delivered: true)
            }
        } catch {
            await completePickleBridge(request, on: responseClient, errorMessage: error.localizedDescription)
        }
    }

    /// Bridge list operations expose session summaries, not message journals.
    /// The cache only receives full lifecycle payloads plus granular journal
    /// events, so it cannot safely claim journal authority between hydrations.
    private func cachedPickleSessionSummaries() -> [PickyAgentSession] {
        let sessions = pickleSessionSummariesProvider?() ?? Array(sessionCache.values)
        return sessions
            .sorted { $0.updatedAt > $1.updatedAt }
            .map { session in
                var summary = session
                summary.messages = []
                summary.messageJournalAvailable = false
                return summary
            }
    }

    private func pickleSessionSummary(id: String) -> PickyAgentSession? {
        if let provider = pickleSessionSummariesProvider {
            return provider().first { $0.id == id }
        }
        return sessionCache[id]
    }

    /// Called after the registry has committed a projection publication. Only
    /// session identity crosses this boundary, so v2 state application stays
    /// entirely inside `PickyRegistrySessionProjectionStorage`.
    func sessionProjectionStorageDidChange() {
        resumeSessionProjectionWaiters()
        reconcileBootingChildSessions()
    }

    /// The v1 dialect cleared child boot state from `rememberSession`. A v2
    /// socket never receives those events, so the registry publication is the
    /// only signal that a freshly spawned Pickle is ready for its queued input.
    private func reconcileBootingChildSessions() {
        for sessionId in Set(pendingChildCommands.keys).union(bootingChildSessionIds) {
            guard let session = pickleSessionSummary(id: sessionId) else { continue }
            if session.status != .queued, isChildEndpointReadyOrNotBooting(sessionId: sessionId) {
                bootingChildSessionIds.remove(sessionId)
            }
            scheduleDrainPendingChildCommandsIfReady(for: session)
        }
    }

    private func resumeSessionProjectionWaiters() {
        for sessionId in Array(sessionProjectionWaiters.keys) where pickleSessionSummary(id: sessionId) != nil {
            let waiters = sessionProjectionWaiters.removeValue(forKey: sessionId).map { Array($0.values) } ?? []
            for waiter in waiters { waiter.resume() }
        }
    }

    private func waitForProjectionSession(sessionId: String) async {
        let waiterID = UUID()
        await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                if self.pickleSessionSummary(id: sessionId) != nil {
                    continuation.resume()
                    return
                }
                self.sessionProjectionWaiters[sessionId, default: [:]][waiterID] = continuation
            }
        }, onCancel: { [weak self] in
            Task { @MainActor [weak self] in
                self?.cancelSessionProjectionWaiter(sessionId: sessionId, waiterID: waiterID)
            }
        })
    }

    private func cancelSessionProjectionWaiter(sessionId: String, waiterID: UUID) {
        let waiter = sessionProjectionWaiters[sessionId]?.removeValue(forKey: waiterID)
        if sessionProjectionWaiters[sessionId]?.isEmpty == true {
            sessionProjectionWaiters[sessionId] = nil
        }
        waiter?.resume()
    }

    private func completePickleBridge(
        _ request: PickyPickleBridgeRequest,
        on responseClient: PickyAgentClient,
        sessions: [PickyAgentSession]? = nil,
        groups: [PickyDockGroupPayload]? = nil,
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        errorMessage: String? = nil
    ) async {
        do {
            try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePickleBridgeRequest,
                requestId: request.requestId,
                errorMessage: errorMessage,
                sessions: sessions,
                groups: groups,
                session: session,
                delivered: delivered
            ), on: responseClient)
        } catch {
            broadcast(.recoverableError("Failed to complete Pickle bridge request: \(error.localizedDescription)"))
        }
    }

    /// Tear down every child. The primary client survives.
    func releaseAllChildren() {
        for sessionId in Array(childClients.keys) { releaseChild(sessionId: sessionId) }
    }

    private func childEventKey(_ sessionId: String) -> String { "child:\(sessionId)" }

    private func startForwardingEvents(from client: PickyAgentClient, key: String, forwardsLifecycleEvents: Bool) {
        guard eventTasks[key] == nil else { return }
        clientEventKeys[ObjectIdentifier(client)] = key
        capabilityRegistrationStates[key] = .awaitingConnection
        eventTasks[key] = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                // `AsyncStream` ignores task cancellation, so a superseded
                // connection's loop stays parked on its buffered events and
                // wakes up later. Without this it would register capabilities
                // on a dead client and mark the shared owner key `.registered`,
                // letting the live connection skip its own registration.
                guard !Task.isCancelled, self.clientEventKeys[ObjectIdentifier(client)] == key else { return }
                switch event {
                case .connected:
                    self.capabilityRegistrationStates[key] = .registering
                    await self.registerAppCapabilities(on: client, ownerKey: key)
                case .disconnected:
                    self.invalidateProjectionBootstrapExpectation(ownerKey: key)
                    self.capabilityRegistrationStates[key] = .awaitingConnection
                    self.capabilityRegistrationCommandIDs[key] = nil
                case .protocolEvent, .sessionProjectionBootstrapCompletion, .recoverableError:
                    break
                }
                if !forwardsLifecycleEvents {
                    switch event {
                    case .connected, .disconnected:
                        continue
                    default:
                        break
                    }
                }
                if case .protocolEvent(let envelope) = event {
                    switch self.handleSessionProjectionBootstrapEvent(envelope.event, ownerKey: key) {
                    case .consume:
                        continue
                    case .forwardAcceptedCompletion(let completion):
                        if case .sessionProjectionBootstrapCompletion(let removedSessionIDs, let isPrimary) = completion {
                            self.onSessionProjectionBootstrapCompletion?(removedSessionIDs, key, isPrimary)
                        }
                        self.broadcast(completion)
                        continue
                    case .forwardOriginal:
                        break
                    }
                    self.rememberSessionEvent(envelope.event, ownerKey: key)
                    // Dispatch `type="error"` rejections and `type="ack"`
                    // confirmations to any `sendAwaitingError` caller blocked on
                    // this commandId. The event still falls through to the
                    // regular fanout so subscribers (HUD viewModel) can also
                    // react if they want to.
                    if case .error(let errorEvent) = envelope.event {
                        self.handleCapabilityRegistrationFailure(errorEvent, on: client, ownerKey: key)
                        self.dispatchPendingErrorHandler(errorEvent)
                    }
                    if case .ack(let ackEvent) = envelope.event {
                        self.dispatchPendingAckHandler(ackEvent)
                    }
                    if key == "primary" {
                        switch envelope.event {
                        case .pickleHandoffRequested(let request):
                            Task { @MainActor [weak self] in
                                await self?.handlePickleHandoffRequest(request)
                            }
                            continue
                        case .externalEntryRequested(let request):
                            Task { @MainActor [weak self] in
                                await self?.handleExternalEntryRequest(request)
                            }
                            continue
                        case .pushToTalkControlRequested(let request):
                            Task { @MainActor [weak self] in
                                await self?.handlePushToTalkControlRequest(request)
                            }
                            continue
                        case .pickySettingsRequested(let request):
                            Task { @MainActor [weak self] in
                                await self?.handlePickySettingsRequest(request)
                            }
                            continue
                        case .dockGroupsRequested(let requestId):
                            Task { @MainActor [weak self] in
                                await self?.handleDockGroupsRequest(requestId: requestId)
                            }
                            continue
                        default:
                            break
                        }
                    }
                    if case .pickleBridgeRequested(let request) = envelope.event {
                        Task { @MainActor [weak self, client] in
                            await self?.handlePickleBridgeRequest(request, responseClient: client)
                        }
                        continue
                    }
                }
                self.broadcast(event)
            }
        }
    }

    private func dispatchPendingErrorHandler(_ error: PickyErrorEvent) {
        guard let commandId = error.commandId,
              let handler = pendingErrorHandlers[commandId] else { return }
        handler(error)
    }

    /// Resolves a pending `sendAwaitingError` as confirmed success (nil error)
    /// the moment the daemon acknowledges the command, instead of waiting out
    /// the heuristic timeout.
    private func dispatchPendingAckHandler(_ ack: PickyAckEvent) {
        guard let handler = pendingErrorHandlers[ack.commandId] else { return }
        handler(nil)
    }

    func registerAppCapabilities(on client: PickyAgentClient, ownerKey: String) async {
        var capabilities = ["pickleHandoff", "pickleBridge", "externalEntry", "pushToTalkControl", "settingsControl"]
        if supportsSessionProjectionV2 {
            capabilities.append("sessionProjectionV2")
        }
        let command = PickyCommandEnvelope(
            type: .registerAppCapabilities,
            capabilities: capabilities
        )
        if supportsSessionProjectionV2 {
            let generation = (projectionConnectionGenerations[ownerKey] ?? 0) + 1
            projectionConnectionGenerations[ownerKey] = generation
            projectionBootstrapExpectations[ownerKey] = ProjectionBootstrapExpectation(
                connectionGeneration: generation,
                bootstrapID: command.id,
                epoch: nil
            )
            sessionProducingProjectionConnections = sessionProducingProjectionConnections.filter { $0.ownerKey != ownerKey }
            acceptedProjectionBootstrapCompletions = acceptedProjectionBootstrapCompletions.filter { $0.ownerKey != ownerKey }
        }
        capabilityRegistrationCommandIDs[ownerKey] = command.id
        do {
            // This is intentionally the sole bypass of the connection gate.
            // Returning from WebSocket send preserves frame order, so queued
            // commands can only follow this registration frame.
            try await client.send(command)
            completeCapabilityRegistration(ownerKey: ownerKey)
        } catch {
            // A transport failure is already the client's own reconnect trigger,
            // so re-arm the gate and let the next `.connected` re-register
            // rather than racing the transport with a second reconnect loop.
            pickyAgentRouterLog("capability registration send failed owner=\(ownerKey) error=\(error.localizedDescription)")
            capabilityRegistrationStates[ownerKey] = .awaitingConnection
            capabilityRegistrationCommandIDs[ownerKey] = nil
        }
    }

    private func handleExternalEntryRequest(_ request: PickyExternalEntryRequest) async {
        do {
            guard let provider = externalEntryContextProvider else {
                throw PickyAgentClientRouterError.externalEntryProviderUnavailable
            }
            let context = try await provider(request)
            try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completeExternalEntryRequest,
                context: context,
                requestId: request.requestId
            ), on: primaryClient)
        } catch {
            try? await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completeExternalEntryRequest,
                requestId: request.requestId,
                errorMessage: error.localizedDescription
            ), on: primaryClient)
        }
    }

    private func handleDockGroupsRequest(requestId: String) async {
        let groups = await dockGroupsProvider?() ?? []
        try? await sendAfterCapabilityRegistration(PickyCommandEnvelope(
            type: .completeDockGroupsRequest,
            requestId: requestId,
            groups: groups
        ), on: primaryClient)
    }

    private func handlePushToTalkControlRequest(_ request: PickyPushToTalkControlRequest) async {
        do {
            guard let handler = pushToTalkControlHandler else {
                throw PickyAgentClientRouterError.pushToTalkControlHandlerUnavailable
            }
            try await handler(request)
            try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePushToTalkControlRequest,
                requestId: request.requestId
            ), on: primaryClient)
        } catch {
            try? await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePushToTalkControlRequest,
                requestId: request.requestId,
                errorMessage: error.localizedDescription
            ), on: primaryClient)
        }
    }

    private func handlePickySettingsRequest(_ request: PickySettingsRequest) async {
        do {
            guard let handler = pickySettingsControlHandler else {
                throw PickyAgentClientRouterError.pickySettingsControlHandlerUnavailable
            }
            let result = try await handler(request)
            try await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePickySettingsRequest,
                requestId: request.requestId,
                result: result
            ), on: primaryClient)
        } catch {
            let exposureError = error as? PickySettingsCLIExposureError
            try? await sendAfterCapabilityRegistration(PickyCommandEnvelope(
                type: .completePickySettingsRequest,
                requestId: request.requestId,
                errorMessage: exposureError?.message ?? error.localizedDescription,
                errorCode: exposureError?.code
            ), on: primaryClient)
        }
    }

    private enum ProjectionBootstrapEventDisposition {
        case forwardOriginal
        case consume
        case forwardAcceptedCompletion(PickyClientEvent)
    }

    /// Validates source/correlation synchronously, then forwards an accepted
    /// completion through the same subscriber stream that carries snapshots.
    /// This preserves daemon frame order at the ViewModel application seam.
    private func handleSessionProjectionBootstrapEvent(
        _ event: PickyEvent,
        ownerKey: String
    ) -> ProjectionBootstrapEventDisposition {
        switch event {
        case .sessionProjectionSnapshot(let snapshot):
            if rememberProjectionSnapshotOwnership(snapshot, ownerKey: ownerKey) {
                onSessionProjectionSnapshotReceived?(ownerKey == "primary")
            }
            return .forwardOriginal
        case .sessionProjectionBootstrapComplete(let completion):
            guard let expectation = projectionBootstrapExpectations[ownerKey],
                  expectation.connectionGeneration == projectionConnectionGenerations[ownerKey],
                  expectation.bootstrapID == completion.bootstrapId,
                  !expectation.failed
            else {
                logDiscardedProjectionBootstrapCompletion(ownerKey: ownerKey, reason: "stale or bootstrapId mismatch")
                return .consume
            }
            guard expectation.epoch == nil || expectation.epoch == completion.epoch else {
                logDiscardedProjectionBootstrapCompletion(ownerKey: ownerKey, reason: "epoch mismatch")
                return .consume
            }
            let key = ProjectionBootstrapCompletionKey(
                ownerKey: ownerKey,
                connectionGeneration: expectation.connectionGeneration,
                bootstrapID: completion.bootstrapId,
                epoch: completion.epoch
            )
            guard acceptedProjectionBootstrapCompletions.insert(key).inserted else {
                logDiscardedProjectionBootstrapCompletion(ownerKey: ownerKey, reason: "duplicate")
                return .consume
            }
            guard completionMayReconcileMembership(ownerKey: ownerKey) else {
                // A booting child may complete an empty index before its first
                // scoped snapshot. Consume it for correlation, never prune.
                return .consume
            }
            if ownerKey == "primary" {
                knownPrimaryProjectionEpoch = completion.epoch
            }
            let membership = Set(completion.sessionIds)
            let ownedIDs = Set(sessionOwnerKeys.compactMap { $0.value == ownerKey ? $0.key : nil })
                .union(projectionOwnerKeys.compactMap { $0.value == ownerKey ? $0.key : nil })
            let removedSessionIDs = ownedIDs.subtracting(membership)
                .subtracting(retiredChildIDsAwaitingPrimaryEpochChange(completion: completion, ownerKey: ownerKey))
            if ownerKey == "primary" {
                retirePrimaryEpochGuardsSatisfied(by: completion.epoch)
            }
            return .forwardAcceptedCompletion(.sessionProjectionBootstrapCompletion(
                removedSessionIDs: removedSessionIDs,
                isPrimary: ownerKey == "primary"
            ))
        default:
            return .forwardOriginal
        }
    }

    @discardableResult
    private func rememberProjectionSnapshotOwnership(_ snapshot: PickySessionProjectionSnapshot, ownerKey: String) -> Bool {
        guard var expectation = projectionBootstrapExpectations[ownerKey],
              expectation.connectionGeneration == projectionConnectionGenerations[ownerKey]
        else { return false }
        if let expectedEpoch = expectation.epoch, expectedEpoch != snapshot.epoch {
            expectation.failed = true
            projectionBootstrapExpectations[ownerKey] = expectation
            logDiscardedProjectionBootstrapCompletion(ownerKey: ownerKey, reason: "snapshot epoch mismatch")
            return false
        }
        expectation.epoch = snapshot.epoch
        projectionBootstrapExpectations[ownerKey] = expectation
        if ownerKey == "primary" {
            knownPrimaryProjectionEpoch = snapshot.epoch
        }
        // Owners are assigned by the source connection, never inferred from an
        // ID that a child happens to report. Do not silently transfer one.
        guard projectionOwnerKeys[snapshot.sessionId] == nil || projectionOwnerKeys[snapshot.sessionId] == ownerKey else { return false }
        projectionOwnerKeys[snapshot.sessionId] = ownerKey
        if ownerKey.hasPrefix("child:"), ownerKey == childEventKey(snapshot.sessionId) {
            sessionProducingProjectionConnections.insert(ProjectionConnectionKey(
                ownerKey: ownerKey,
                connectionGeneration: expectation.connectionGeneration
            ))
            bootingChildSessionIds.remove(snapshot.sessionId)
        }
        return true
    }

    private func retiredChildIDsAwaitingPrimaryEpochChange(
        completion: PickySessionProjectionBootstrapComplete,
        ownerKey: String
    ) -> Set<String> {
        guard ownerKey == "primary" else { return [] }
        return Set(retiredChildPrimaryOwnerships.compactMap { sessionID, ownership in
            guard let releaseEpoch = ownership.primaryEpochAtRelease,
                  releaseEpoch != completion.epoch else {
                return sessionID
            }
            return nil
        })
    }

    private func retirePrimaryEpochGuardsSatisfied(by completionEpoch: String) {
        retiredChildPrimaryOwnerships = retiredChildPrimaryOwnerships.filter {
            $0.value.primaryEpochAtRelease == completionEpoch
        }
    }

    private func completionMayReconcileMembership(ownerKey: String) -> Bool {
        guard ownerKey != "primary" else { return true }
        guard let sessionID = ownerKey.split(separator: ":", maxSplits: 1).last.map(String.init),
              childClients[sessionID] != nil,
              !retiredChildSessionIds.contains(sessionID),
              let expectation = projectionBootstrapExpectations[ownerKey]
        else { return false }
        return sessionProducingProjectionConnections.contains(ProjectionConnectionKey(
            ownerKey: ownerKey,
            connectionGeneration: expectation.connectionGeneration
        ))
    }

    private func invalidateProjectionBootstrapExpectation(ownerKey: String) {
        projectionBootstrapExpectations[ownerKey] = nil
        sessionProducingProjectionConnections = sessionProducingProjectionConnections.filter { $0.ownerKey != ownerKey }
        acceptedProjectionBootstrapCompletions = acceptedProjectionBootstrapCompletions.filter { $0.ownerKey != ownerKey }
    }

    private func logDiscardedProjectionBootstrapCompletion(ownerKey: String, reason: String) {
        PickyLog.notice(.agentClient, prefix: "🔌 Picky agent client —", message: "discarded projection bootstrap completion owner=\(ownerKey) reason=\(reason)")
    }

    private func rememberSessionEvent(_ event: PickyEvent, ownerKey: String) {
        switch event {
        case .sessionUpdated(let session):
            rememberSession(session, ownerKey: ownerKey)
        case .sessionMetaUpdated(var session):
            // A thin update cannot hydrate a session that this router has not
            // seen in a full snapshot. Preserve the cached journal otherwise.
            guard let existing = sessionCache[session.id] else { return }
            session.messages = existing.messages
            session.logs = existing.logs
            session.tools = existing.tools
            rememberSession(session, ownerKey: ownerKey)
        case .sessionSnapshot(let snapshot):
            let snapshotSessionIDs = Set(snapshot.sessions.map(\.id))
            if snapshot.isComplete {
                let removedSessionIDs = sessionOwnerKeys.compactMap { sessionID, sessionOwnerKey in
                    sessionOwnerKey == ownerKey && !snapshotSessionIDs.contains(sessionID) ? sessionID : nil
                }
                for sessionID in removedSessionIDs {
                    sessionCache[sessionID] = nil
                    sessionOwnerKeys[sessionID] = nil
                }
            }
            for session in snapshot.sessions { rememberSession(session, ownerKey: ownerKey) }
        default:
            break
        }
    }

    private func rememberSession(_ session: PickyAgentSession, ownerKey: String) {
        sessionCache[session.id] = session
        sessionOwnerKeys[session.id] = ownerKey
        resumeSessionProjectionWaiters()
        if session.status != .queued, isChildEndpointReadyOrNotBooting(sessionId: session.id) {
            bootingChildSessionIds.remove(session.id)
        }
        scheduleDrainPendingChildCommandsIfReady(for: session)
    }

    /// Drops and re-establishes the connection that owns `sessionID`'s
    /// projection. Its bootstrap snapshots re-seed every cursor on that
    /// connection, which is the only repair that does not depend on the daemon
    /// answering a per-session recovery request.
    ///
    /// Debounced per connection: one stalled session must not let a burst of
    /// sibling stalls tear the same socket down repeatedly.
    func reconnectProjectionOwner(sessionID: String) {
        let ownerKey = projectionOwnerKeys[sessionID] ?? "primary"
        let client: PickyAgentClient? = ownerKey == "primary" ? primaryClient : childClients[sessionID]
        guard let client else { return }
        let now = Date()
        if let last = lastProjectionOwnerReconnects[ownerKey], now.timeIntervalSince(last) < Self.projectionOwnerReconnectDebounce {
            pickyAgentRouterLog("projection owner reconnect debounced owner=\(ownerKey) session=\(sessionID)")
            return
        }
        lastProjectionOwnerReconnects[ownerKey] = now
        pickyAgentRouterLog("projection owner reconnect owner=\(ownerKey) session=\(sessionID)")
        client.disconnect()
        Task { @MainActor in await client.connect() }
    }

    private func stopForwardingEvents(for key: String) {
        eventTasks[key]?.cancel()
        eventTasks[key] = nil
        clientEventKeys = clientEventKeys.filter { $0.value != key }
        discardCapabilityRegistration(ownerKey: key)
    }
}

enum PickyAgentClientRouterError: LocalizedError, Equatable {
    case missingChildEndpoint(sessionId: String)
    case sessionCreationTimedOut(sessionId: String)
    case invalidBridgeRequest
    case bridgeCommandRejected(String)
    case commandAcknowledgementTimedOut(commandId: String)
    case unknownChildSession(sessionId: String)
    case routerUnavailable
    case externalEntryProviderUnavailable
    case pushToTalkControlHandlerUnavailable
    case pickySettingsControlHandlerUnavailable
    case capabilityRegistrationUnavailable(ownerKey: String)

    var errorDescription: String? {
        switch self {
        case .missingChildEndpoint(let sessionId): "Pickle child runtime is unavailable for session \(sessionId)."
        case .sessionCreationTimedOut(let sessionId): "Timed out waiting for Pickle session \(sessionId) to start."
        case .invalidBridgeRequest: "Invalid Pickle bridge request."
        case .bridgeCommandRejected(let message): message
        case .commandAcknowledgementTimedOut(let commandId): "Timed out waiting for child Pickle command acknowledgement: \(commandId)."
        case .unknownChildSession(let sessionId): "Unknown child Pickle session: \(sessionId)."
        case .routerUnavailable: "Picky router is unavailable."
        case .externalEntryProviderUnavailable: "Picky context provider is not ready for external CLI entry."
        case .pushToTalkControlHandlerUnavailable: "Picky push-to-talk control handler is not ready for external CLI input."
        case .pickySettingsControlHandlerUnavailable: "Picky settings control handler is not ready for external CLI input."
        case .capabilityRegistrationUnavailable(let ownerKey): "Picky agent connection \(ownerKey) did not register its capabilities in time."
        }
    }
}

func pickyAgentRouterLog(_ message: String) {
    PickyLog.notice(.agentClient, prefix: "🔀 Picky agent router —", message: message)
}


