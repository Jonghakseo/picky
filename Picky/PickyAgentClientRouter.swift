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

/// Routes Picky commands to the right websocket client. Phase 2 vertical-slice intentionally
/// keeps a single primary connection alive at all times; child connections are created on
/// demand and torn down when the Pickle ends or the pool releases the child.
@MainActor
final class PickyAgentClientRouter: PickyAgentClient, PickyManualPickleChildSpawning, PickyChildSessionReleasing {
    private let primaryClient: PickyAgentClient
    private let pool: PickyAgentDaemonPool
    private let clientFactory: PickyAgentClientFactoryProtocol
    private let handoffPickleSessionIdFactory: () -> String
    private var childClients: [String: PickyAgentClient] = [:]
    private var eventTasks: [String: Task<Void, Never>] = [:]
    private var primaryConnectStarted = false
    private var knownChildSessionIds = Set<String>()
    private var bootingChildSessionIds = Set<String>()
    private var retiredChildSessionIds = Set<String>()
    private var sessionCache: [String: PickyAgentSession] = [:]
    /// Commands typed against a freshly spawned Pickle before the child runtime has left
    /// `.queued`. They are drained in order once the child emits its first non-queued
    /// `sessionUpdated`, avoiding early follow-up/steer sends while the Pi process is still
    /// bootstrapping.
    private var pendingChildCommands: [String: [PickyCommandEnvelope]] = [:]
    /// Per-command rejection callbacks keyed by `PickyCommandEnvelope.id`.
    /// Populated by `sendAwaitingError`; invoked by the event forwarder when
    /// the daemon emits a `type="error"` event whose `commandId` matches a
    /// pending registration. Cleared by the timeout race in
    /// `sendAwaitingError` if no error arrives, so this never grows
    /// unboundedly.
    private var pendingErrorHandlers: [String: (PickyErrorEvent) -> Void] = [:]
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
    private func broadcast(_ event: PickyClientEvent) {
        // Latch lifecycle transitions so late subscribers can replay them.
        switch event {
        case .connected, .disconnected:
            lastLifecycleEvent = event
        case .protocolEvent, .recoverableError:
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

    init(
        primaryClient: PickyAgentClient,
        pool: PickyAgentDaemonPool,
        clientFactory: PickyAgentClientFactoryProtocol = DefaultPickyAgentClientFactory(),
        handoffPickleSessionIdFactory: @escaping () -> String = { "session-\(UUID().uuidString)" }
    ) {
        self.primaryClient = primaryClient
        self.pool = pool
        self.clientFactory = clientFactory
        self.handoffPickleSessionIdFactory = handoffPickleSessionIdFactory
        // Drop the cached websocket client (and stop its reconnect loop) the moment the pool
        // notices the underlying child daemon has exited. Without this, the legacy receiveLoop
        // in WebSocketPickyAgentClient would keep reconnecting forever to a dead random port.
        pool.onChildExitAfterReady = { [weak self] sessionId, exitCode in
            guard let self else { return }
            self.stopForwardingEvents(for: self.childEventKey(sessionId))
            if let client = self.childClients.removeValue(forKey: sessionId) {
                client.disconnect()
            }
            self.pendingChildCommands.removeValue(forKey: sessionId)
            self.bootingChildSessionIds.remove(sessionId)
            self.markChildSessionRetired(sessionId)
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
        try await connectedClient(for: command.sessionId).send(command)
    }

    /// Sends `command` through the right (primary or child) client and races
    /// the result against a `timeout` window during which the daemon may emit
    /// a `type="error"` event referencing `command.id`. agentd unicasts those
    /// rejections to the sender connection, so we intercept them inside
    /// `startForwardingEvents` and dispatch to the per-command handler set
    /// up here.
    ///
    /// Three possible outcomes:
    ///   * Daemon emits a matching `type="error"` event → returns the
    ///     `PickyErrorEvent` so the caller can surface a real failure.
    ///   * Underlying `send` throws (transport dead, missing-child-endpoint,
    ///     encoding error…) → rethrows. The caller's existing `catch`
    ///     turns it into a user-visible error. Returning `nil` here would
    ///     mask a transport failure as success — exactly the silent-success
    ///     class of bug this method exists to prevent.
    ///   * No error within `timeout` → returns `nil` (treated as success).
    ///
    /// **Known limitation:** agentd does not emit a positive ack today, so
    /// the "no error within timeout" path is a heuristic. On a heavily
    /// loaded daemon, a true rejection that arrives after `timeout` would
    /// be classified as success. Mitigation paths, in order of effort:
    ///   1. Widen `timeout` per call site for unreliable network paths.
    ///   2. (Recommended structural fix) Teach agentd's command pipeline
    ///      to emit `type="ack" commandId=...` on success, and switch this
    ///      method to a deterministic `ack`/`error` race. That removes the
    ///      heuristic entirely. Tracked as a separate, larger task because
    ///      it requires changing the agentd protocol and the supervisor.
    func sendAwaitingError(_ command: PickyCommandEnvelope, timeout: TimeInterval = 1.0) async throws -> PickyErrorEvent? {
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
                resume(.success(nil))
            }
        }
    }

    func disconnect() {
        for task in eventTasks.values { task.cancel() }
        eventTasks.removeAll()
        primaryConnectStarted = false
        bootingChildSessionIds.removeAll()
        pendingChildCommands.removeAll()
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

    private func enqueueIfChildIsBooting(_ command: PickyCommandEnvelope) -> Bool {
        guard command.type == .followUp || command.type == .steer else { return false }
        guard let sessionId = command.sessionId else { return false }
        let isChildSession = knownChildSessionIds.contains(sessionId) || pool.endpoint(for: sessionId) != nil
        guard isChildSession else { return false }
        let status = sessionCache[sessionId]?.status
        let isBooting = status == .queued || (status == nil && bootingChildSessionIds.contains(sessionId))
        guard isBooting else { return false }
        pendingChildCommands[sessionId, default: []].append(command)
        let statusText = status?.rawValue ?? "not-yet-created"
        pickyAgentRouterLog("queued child command while booting session=\(sessionId) type=\(command.type.rawValue) status=\(statusText)")
        return true
    }

    private func scheduleDrainPendingChildCommandsIfReady(for session: PickyAgentSession) {
        guard session.status != .queued else { return }
        guard pendingChildCommands[session.id]?.isEmpty == false else { return }
        Task { @MainActor [weak self] in
            await self?.drainPendingChildCommands(sessionId: session.id)
        }
    }

    private func drainPendingChildCommands(sessionId: String) async {
        guard let commands = pendingChildCommands.removeValue(forKey: sessionId), !commands.isEmpty else { return }
        pickyAgentRouterLog("draining child commands session=\(sessionId) count=\(commands.count)")
        var sentCount = 0
        do {
            let client = try await connectedClient(for: sessionId)
            for command in commands {
                try await client.send(command)
                sentCount += 1
            }
        } catch {
            let unsent = Array(commands.dropFirst(sentCount))
            pendingChildCommands[sessionId, default: []].insert(contentsOf: unsent, at: 0)
            broadcast(.recoverableError("Failed to send queued Pickle input: \(error.localizedDescription)"))
        }
    }

    /// Spawn a child daemon for `sessionId` rooted at `cwd`, then return the per-child client.
    /// Subsequent calls for the same session id return the cached client without re-spawning.
    func spawnChildClient(sessionId: String, cwd: String, primaryUrl: String? = nil) async throws -> PickyAgentClient {
        knownChildSessionIds.insert(sessionId)
        retiredChildSessionIds.remove(sessionId)
        if let existing = childClients[sessionId] { return existing }
        bootingChildSessionIds.insert(sessionId)
        let endpoint: PickyChildDaemonEndpoint
        do {
            endpoint = try await pool.spawnChild(sessionId: sessionId, cwd: cwd, primaryUrl: primaryUrl)
        } catch {
            bootingChildSessionIds.remove(sessionId)
            throw error
        }
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
                try await childClient.send(PickyCommandEnvelope(
                    type: .createPickleFromHandoff,
                    context: request.context,
                    title: request.title,
                    instructions: request.instructions,
                    cwd: request.cwd
                ))
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
            try await primaryClient.send(PickyCommandEnvelope(
                type: .completePickleHandoff,
                sessionId: sessionId,
                requestId: request.requestId,
                title: request.title,
                cwd: request.cwd,
                errorMessage: errorMessage
            ))
        } catch {
            broadcast(.recoverableError("Failed to complete Pickle handoff: \(error.localizedDescription)"))
        }
    }

    private func waitForSessionUpdated(sessionId: String, timeoutNanoseconds: UInt64) async throws {
        if sessionCache[sessionId] != nil { return }
        let deadline = ContinuousClock.now.advanced(by: .nanoseconds(Int(timeoutNanoseconds)))
        while ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
            if sessionCache[sessionId] != nil { return }
        }
        throw PickyAgentClientRouterError.sessionCreationTimedOut(sessionId: sessionId)
    }

    /// Tear down the per-child client and ask the pool to kill the child daemon. Idempotent.
    func releaseChild(sessionId: String) {
        let wasChildSession = knownChildSessionIds.contains(sessionId) || childClients[sessionId] != nil || pool.endpoint(for: sessionId) != nil
        stopForwardingEvents(for: childEventKey(sessionId))
        if let client = childClients.removeValue(forKey: sessionId) {
            client.disconnect()
        }
        pendingChildCommands.removeValue(forKey: sessionId)
        bootingChildSessionIds.remove(sessionId)
        if wasChildSession {
            markChildSessionRetired(sessionId)
        }
        pool.terminateChild(sessionId: sessionId)
    }

    private func markChildSessionRetired(_ sessionId: String) {
        knownChildSessionIds.remove(sessionId)
        retiredChildSessionIds.insert(sessionId)
    }

    private func handlePickleBridgeRequest(_ request: PickyPickleBridgeRequest, responseClient: PickyAgentClient) async {
        do {
            switch request.operation {
            case .listSessions:
                await completePickleBridge(request, on: responseClient, sessions: childPickleSessions())
            case .steer:
                guard let sessionId = request.sessionId, let text = request.text else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let client = try await connectedClient(for: sessionId)
                try await client.send(PickyCommandEnvelope(type: .steer, sessionId: sessionId, text: text))
                await completePickleBridge(request, on: responseClient, session: sessionCache[sessionId])
            case .abort:
                guard let sessionId = request.sessionId else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                let client = try await connectedClient(for: sessionId)
                try await client.send(PickyCommandEnvelope(type: .abort, sessionId: sessionId))
                await completePickleBridge(request, on: responseClient, session: sessionCache[sessionId])
            case .notifyMainOfPickleCompletion:
                // Forward the child-built completion prompt to the primary daemon, which owns
                // the main Picky agent and can followUp on its behalf. The child cannot do this
                // directly because child daemons have no mainRuntime wired in.
                guard let sessionId = request.sessionId, let prompt = request.prompt else { throw PickyAgentClientRouterError.invalidBridgeRequest }
                try await primaryClient.send(PickyCommandEnvelope(
                    type: .notifyMainOfPickleCompletion,
                    sessionId: sessionId,
                    cwd: request.cwd,
                    prompt: prompt
                ))
                await completePickleBridge(request, on: responseClient, delivered: true)
            }
        } catch {
            await completePickleBridge(request, on: responseClient, errorMessage: error.localizedDescription)
        }
    }

    private func childPickleSessions() -> [PickyAgentSession] {
        sessionCache.values
            .filter { knownChildSessionIds.contains($0.id) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func completePickleBridge(
        _ request: PickyPickleBridgeRequest,
        on responseClient: PickyAgentClient,
        sessions: [PickyAgentSession]? = nil,
        session: PickyAgentSession? = nil,
        delivered: Bool? = nil,
        errorMessage: String? = nil
    ) async {
        do {
            try await responseClient.send(PickyCommandEnvelope(
                type: .completePickleBridgeRequest,
                requestId: request.requestId,
                errorMessage: errorMessage,
                sessions: sessions,
                session: session,
                delivered: delivered
            ))
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
        eventTasks[key] = Task { [weak self] in
            for await event in client.events {
                guard let self else { return }
                if case .connected = event {
                    await self.registerAppCapabilities(on: client)
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
                    self.rememberSessionEvent(envelope.event)
                    // Dispatch `type="error"` rejections to any `sendAwaitingError`
                    // caller blocked on this commandId. The event still falls
                    // through to the regular fanout so subscribers (HUD viewModel)
                    // can also react if they want to.
                    if case .error(let errorEvent) = envelope.event,
                       let commandId = errorEvent.commandId,
                       let handler = self.pendingErrorHandlers[commandId] {
                        handler(errorEvent)
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

    private func registerAppCapabilities(on client: PickyAgentClient) async {
        try? await client.send(PickyCommandEnvelope(
            type: .registerAppCapabilities,
            capabilities: ["pickleHandoff", "pickleBridge", "externalEntry"]
        ))
    }

    private func handleExternalEntryRequest(_ request: PickyExternalEntryRequest) async {
        do {
            guard let provider = externalEntryContextProvider else {
                throw PickyAgentClientRouterError.externalEntryProviderUnavailable
            }
            let context = try await provider(request)
            try await primaryClient.send(PickyCommandEnvelope(
                type: .completeExternalEntryRequest,
                context: context,
                requestId: request.requestId
            ))
        } catch {
            try? await primaryClient.send(PickyCommandEnvelope(
                type: .completeExternalEntryRequest,
                requestId: request.requestId,
                errorMessage: error.localizedDescription
            ))
        }
    }

    private func rememberSessionEvent(_ event: PickyEvent) {
        switch event {
        case .sessionUpdated(let session):
            sessionCache[session.id] = session
            if session.status != .queued { bootingChildSessionIds.remove(session.id) }
            scheduleDrainPendingChildCommandsIfReady(for: session)
        case .sessionSnapshot(let sessions):
            for session in sessions {
                sessionCache[session.id] = session
                if session.status != .queued { bootingChildSessionIds.remove(session.id) }
                scheduleDrainPendingChildCommandsIfReady(for: session)
            }
        default:
            break
        }
    }

    private func stopForwardingEvents(for key: String) {
        eventTasks[key]?.cancel()
        eventTasks[key] = nil
    }
}

enum PickyAgentClientRouterError: LocalizedError, Equatable {
    case missingChildEndpoint(sessionId: String)
    case sessionCreationTimedOut(sessionId: String)
    case invalidBridgeRequest
    case unknownChildSession(sessionId: String)
    case routerUnavailable
    case externalEntryProviderUnavailable

    var errorDescription: String? {
        switch self {
        case .missingChildEndpoint(let sessionId): "Pickle child runtime is unavailable for session \(sessionId)."
        case .sessionCreationTimedOut(let sessionId): "Timed out waiting for Pickle session \(sessionId) to start."
        case .invalidBridgeRequest: "Invalid Pickle bridge request."
        case .unknownChildSession(let sessionId): "Unknown child Pickle session: \(sessionId)."
        case .routerUnavailable: "Picky router is unavailable."
        case .externalEntryProviderUnavailable: "Picky context provider is not ready for external CLI entry."
        }
    }
}

private func pickyAgentRouterLog(_ message: String) {
    PickyLog.notice(.agentClient, prefix: "🔀 Picky agent router —", message: message)
}


