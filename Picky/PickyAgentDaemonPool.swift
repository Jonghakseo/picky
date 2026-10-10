//
//  PickyAgentDaemonPool.swift
//  Picky
//
//  Phase 2 of the per-Pickle agentd plan: the primary daemon stays at a fixed
//  endpoint while individual Pickle sessions can spawn their own child daemon
//  bound to the session's workspace cwd. This file owns the lifecycle of those
//  child processes (not their websocket clients — see PickyAgentClientRouter).
//

import Combine
import Foundation

/// Endpoint returned by `spawnChild` once the child daemon's stdout has emitted
/// the `picky-agentd listening on 127.0.0.1:<port>` ready line. The websocket
/// client is constructed by the caller (router) using this endpoint plus the
/// shared token.
struct PickyChildDaemonEndpoint: Equatable {
    let sessionId: String
    let host: String
    let port: Int
    let token: String

    var url: URL {
        var components = URLComponents()
        components.scheme = "ws"
        components.host = host
        components.port = port
        components.path = "/"
        return components.url!
    }
}

/// Errors returned by the pool. All errors are surfaced to the caller so the HUD can decide
/// whether to retry or fall back to the primary code path; the pool itself does not retry.
enum PickyAgentDaemonPoolError: LocalizedError, Equatable {
    case spawnTimedOut(sessionId: String, seconds: TimeInterval)
    case childExitedBeforeReady(sessionId: String, exitCode: Int32)
    case childFailedPreflight(sessionId: String, message: String)
    case duplicateSessionId(String)

    var errorDescription: String? {
        switch self {
        case .spawnTimedOut(let sessionId, let seconds):
            return "Child Pickle daemon \(sessionId) did not become ready within \(Int(seconds))s"
        case .childExitedBeforeReady(let sessionId, let exitCode):
            return "Child Pickle daemon \(sessionId) exited with code \(exitCode) before becoming ready"
        case .childFailedPreflight(let sessionId, let message):
            return "Child Pickle daemon \(sessionId) failed preflight: \(message)"
        case .duplicateSessionId(let sessionId):
            return "Child Pickle daemon \(sessionId) is already running"
        }
    }
}

/// Factory abstraction so tests can substitute their own launcher/runner pair without spinning
/// up real Foundation `Process` instances.
protocol PickyAgentDaemonLauncherMaking: AnyObject {
    @MainActor
    func makeLauncher(
        configuration: PickyAgentDaemonConfiguration,
        stdoutLineObserver: @escaping (String) -> Void
    ) -> PickyAgentDaemonLauncher
}

@MainActor
final class DefaultPickyAgentDaemonLauncherFactory: PickyAgentDaemonLauncherMaking {
    func makeLauncher(
        configuration: PickyAgentDaemonConfiguration,
        stdoutLineObserver: @escaping (String) -> Void
    ) -> PickyAgentDaemonLauncher {
        PickyAgentDaemonLauncher(
            configuration: configuration,
            stdoutLineObserver: stdoutLineObserver
        )
    }
}

/// Authenticated owner and current local intent supplied by the router.
struct PickyChildReleaseContext: Equatable {
    var requestId: String
    var daemonInstanceId: String
    var runtimeInstanceId: String
    var archiveIntentId: String
    var workRevision: Int
    var controlGeneration: Int

    fileprivate var isComplete: Bool {
        [requestId, daemonInstanceId, runtimeInstanceId, archiveIntentId]
            .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            && workRevision >= 0 && controlGeneration >= 0
    }
}

/// Opaque local capture made before requesting owner approval. Never PID authority.
struct PickyChildReleaseCapture {
    let sessionId: String
    let childGeneration: Int
    fileprivate let childIdentity: ObjectIdentifier
    fileprivate let processGeneration: Int
    fileprivate let context: PickyChildReleaseContext
}

@MainActor
final class PickyAgentDaemonPool: ObservableObject {
    struct Configuration {
        var token: String
        var appSupportRoot: URL
        var spawnTimeout: TimeInterval = 30
        var environment: [String: String] = ProcessInfo.processInfo.environment
        var bundleResourceURL: URL? = Bundle.main.resourceURL
        var settingsProvider: () -> PickySettings = { PickySettings.defaults() }
    }

    private final class Child {
        let launcher: PickyAgentDaemonLauncher
        let generation: Int
        var endpoint: PickyChildDaemonEndpoint?
        var continuation: CheckedContinuation<PickyChildDaemonEndpoint, Error>?
        var observerTask: Task<Void, Never>?

        init(
            launcher: PickyAgentDaemonLauncher, generation: Int,
            continuation: CheckedContinuation<PickyChildDaemonEndpoint, Error>
        ) {
            self.generation = generation
            self.launcher = launcher
            self.continuation = continuation
        }

        /// Resume the spawn continuation exactly once. Subsequent calls are no-ops so the same
        /// child can't double-fail or double-succeed.
        func resolve(_ result: Result<PickyChildDaemonEndpoint, Error>) {
            guard let pending = continuation else { return }
            continuation = nil
            switch result {
            case .success(let endpoint):
                self.endpoint = endpoint
                pending.resume(returning: endpoint)
            case .failure(let error):
                pending.resume(throwing: error)
            }
        }
    }

    private let factory: PickyAgentDaemonLauncherMaking
    private let configuration: Configuration
    private var nextChildGeneration = 0
    private var children: [String: Child] = [:]
    /// Launchers whose child was asked to stop but whose Node process has not
    /// confirmed exit yet. Dropping the `Child` record is not proof of exit: a
    /// terminating Pickle daemon keeps writing its session file until the
    /// process is really gone, so anything that rewrites that file waits here.
    private var retiringChildren: [String: [PickyAgentDaemonLauncher]] = [:]
    private var spawnTimeoutTasks: [String: Task<Void, Never>] = [:]

    @Published private(set) var activeChildSessionIds: Set<String> = []

    /// Bumped every time a child's endpoint becomes known. `activeChildSessionIds`
    /// changes at spawn start, when `endpoint(for:)` is still nil, so an observer
    /// that needs the address (the remote daemon topology) has nothing to react
    /// to without this.
    @Published private(set) var childEndpointRevision = 0

    /// Closure invoked when an already-ready child daemon exits unexpectedly. Phase 2 disables
    /// the launcher's auto-restart for child role, so a post-ready crash invalidates the cached
    /// endpoint immediately. The router subscribes to this hook so it can disconnect the cached
    /// websocket client instead of letting `WebSocketPickyAgentClient.receiveLoop` reconnect
    /// forever to a dead random port. `exitCode` is `nil` when the child stopped gracefully
    /// (e.g. via `terminateChild`).
    var onChildExitAfterReady: ((_ sessionId: String, _ exitCode: Int32?) -> Void)?

    init(
        configuration: Configuration,
        factory: PickyAgentDaemonLauncherMaking? = nil
    ) {
        self.configuration = configuration
        self.factory = factory ?? DefaultPickyAgentDaemonLauncherFactory()
    }

    /// Spawns a new child daemon for the given Pickle session and waits until its stdout
    /// announces a bound port. The returned endpoint is what the router uses to build a
    /// per-child websocket client.
    func spawnChild(sessionId: String, cwd: String, primaryUrl: String? = nil) async throws -> PickyChildDaemonEndpoint {
        if children[sessionId] != nil { throw PickyAgentDaemonPoolError.duplicateSessionId(sessionId) }

        let settings = configuration.settingsProvider().normalizedPaths()
        let childConfig = PickyAgentDaemonConfiguration.child(
            sessionId: sessionId,
            sessionCwd: cwd,
            primaryUrl: primaryUrl,
            token: configuration.token,
            appSupportRoot: configuration.appSupportRoot,
            pickleAgentThinkingLevel: settings.pickleAgentThinkingLevel,
            pickleAgentModelPattern: settings.pickleAgentModelPattern,
            piBinaryPath: settings.piBinaryPath,
            piCodingAgentDir: settings.piCodingAgentDir,
            environment: configuration.environment,
            bundleResourceURL: configuration.bundleResourceURL
        )

        // withTaskCancellationHandler so a `Task { try await pool.spawnChild(...) }` cancelled
        // by the caller still tears down the half-booted child instead of letting it linger
        // until the spawnTimeout fires (and blocking the next spawn with duplicateSessionId).
        return try await withTaskCancellationHandler(
            operation: {
                try await withCheckedThrowingContinuation { [weak self] (continuation: CheckedContinuation<PickyChildDaemonEndpoint, Error>) in
                    guard let self else { continuation.resume(throwing: CancellationError()); return }
                    let launcher = self.factory.makeLauncher(
                        configuration: childConfig,
                        // The launcher already batches child output onto the main actor, so
                        // lines arrive here on the main actor and need no per-line hop.
                        stdoutLineObserver: { [weak self] line in
                            self?.handleChildStdoutLine(sessionId: sessionId, line: line)
                        }
                    )
                    self.nextChildGeneration += 1
                    let child = Child(
                        launcher: launcher, generation: self.nextChildGeneration, continuation: continuation
                    )
                    self.children[sessionId] = child
                    self.activeChildSessionIds.insert(sessionId)

                    // Drive the full launcher lifecycle. Before endpoint resolves we use state
                    // transitions to fail the spawn promise. After endpoint resolves we keep
                    // listening so a post-ready crash invalidates the cached endpoint and
                    // notifies the router (Phase 2 disables auto-restart for child role so
                    // crashes are terminal).
                    child.observerTask = Task { @MainActor [weak self] in
                        for await state in launcher.$state.values {
                            guard let self else { return }
                            guard let current = self.children[sessionId], current === child else { return }
                            if current.endpoint == nil {
                                switch state {
                                case .failedToStart(let message):
                                    self.failPendingSpawn(sessionId: sessionId, error: .childFailedPreflight(sessionId: sessionId, message: message))
                                case .crashed(let exitCode):
                                    self.failPendingSpawn(sessionId: sessionId, error: .childExitedBeforeReady(sessionId: sessionId, exitCode: exitCode))
                                default:
                                    continue
                                }
                            } else {
                                switch state {
                                case .crashed(let exitCode):
                                    self.handlePostReadyChildExit(sessionId: sessionId, exitCode: exitCode)
                                    return
                                case .stopped:
                                    self.handlePostReadyChildExit(sessionId: sessionId, exitCode: nil)
                                    return
                                default:
                                    continue
                                }
                            }
                        }
                    }

                    launcher.start()
                    self.scheduleSpawnTimeout(sessionId: sessionId, timeout: self.configuration.spawnTimeout)
                }
            },
            onCancel: { [weak self] in
                Task { @MainActor in self?.terminateChild(sessionId: sessionId) }
            }
        )
    }

    func captureRelease(sessionId: String, context: PickyChildReleaseContext) -> PickyChildReleaseCapture? {
        guard context.isComplete, let child = children[sessionId], child.endpoint != nil,
              let processGeneration = child.launcher.runningProcessGeneration else { return nil }
        return PickyChildReleaseCapture(
            sessionId: sessionId, childGeneration: child.generation,
            childIdentity: ObjectIdentifier(child), processGeneration: processGeneration, context: context
        )
    }

    /// Router authenticates/correlates the response and supplies current owner,
    /// intent and prepared revisions after the await. Tokens are not self-authenticating.
    /// No suspension or session lookup occurs between final validation and stop.
    @discardableResult
    func terminateChild(
        capture: PickyChildReleaseCapture, result: PickyAsyncTaskCommandResult,
        currentContext: PickyChildReleaseContext
    ) -> Bool {
        guard currentContext.isComplete,
              currentContext.requestId == capture.context.requestId,
              result.type == "asyncTaskCommandResult", result.outcome == .settled,
              result.requestId == capture.context.requestId,
              result.sessionId == capture.sessionId,
              result.daemonInstanceId == currentContext.daemonInstanceId,
              result.runtimeInstanceId == currentContext.runtimeInstanceId,
              result.workRevision == currentContext.workRevision,
              result.controlGeneration == currentContext.controlGeneration,
              !result.operationId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let approval = result.releaseApproval,
              currentContext.daemonInstanceId == capture.context.daemonInstanceId,
              currentContext.runtimeInstanceId == capture.context.runtimeInstanceId,
              currentContext.archiveIntentId == capture.context.archiveIntentId,
              currentContext.workRevision >= capture.context.workRevision,
              currentContext.controlGeneration >= capture.context.controlGeneration,
              approval.operationId == result.operationId,
              !approval.releaseToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              approval.sessionId == capture.sessionId,
              approval.daemonInstanceId == currentContext.daemonInstanceId,
              approval.runtimeInstanceId == currentContext.runtimeInstanceId,
              approval.archiveIntentId == currentContext.archiveIntentId,
              approval.workRevision == currentContext.workRevision,
              approval.controlGeneration == currentContext.controlGeneration,
              approval.childGeneration == capture.childGeneration,
              let child = children[capture.sessionId],
              ObjectIdentifier(child) == capture.childIdentity,
              child.generation == capture.childGeneration,
              child.launcher.runningProcessGeneration == capture.processGeneration else { return false }
        guard child.launcher.stop(ifProcessGeneration: capture.processGeneration) else { return false }
        trackRetiringLauncher(sessionId: capture.sessionId, launcher: child.launcher)
        child.resolve(.failure(CancellationError()))
        child.observerTask?.cancel()
        spawnTimeoutTasks[capture.sessionId]?.cancel()
        spawnTimeoutTasks.removeValue(forKey: capture.sessionId)
        children.removeValue(forKey: capture.sessionId)
        activeChildSessionIds.remove(capture.sessionId)
        return true
    }

    /// Gracefully terminate a child daemon. Safe to call regardless of whether the child is
    /// currently spawning, running, or already exited; subsequent calls are no-ops.
    func terminateChild(sessionId: String, waitForExit: Bool = false) {
        guard let child = children[sessionId] else { return }
        child.resolve(.failure(CancellationError()))
        child.observerTask?.cancel()
        if waitForExit {
            child.launcher.stopAndWaitForExit()
        } else {
            child.launcher.stop()
        }
        trackRetiringLauncher(sessionId: sessionId, launcher: child.launcher)
        spawnTimeoutTasks[sessionId]?.cancel()
        spawnTimeoutTasks.removeValue(forKey: sessionId)
        children.removeValue(forKey: sessionId)
        activeChildSessionIds.remove(sessionId)
    }

    /// Look up a previously resolved endpoint without spawning. Useful for routers that need
    /// to know whether a child exists before forwarding a command.
    func endpoint(for sessionId: String) -> PickyChildDaemonEndpoint? {
        children[sessionId]?.endpoint
    }

    /// True while any Node process for this session is still alive, including a
    /// child that was told to stop and has not exited yet.
    func hasLiveChildProcess(sessionId: String) -> Bool {
        pruneRetiringLaunchers(sessionId: sessionId)
        if children[sessionId] != nil { return true }
        return retiringChildren[sessionId] != nil
    }

    /// Waits up to `timeout` for every launcher of this session to report a real
    /// process exit. Returns false when one is still alive at the deadline, so
    /// the caller can refuse to write rather than assume the daemon is gone.
    func awaitChildProcessExit(sessionId: String, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(max(timeout, 0))
        while hasLiveChildProcess(sessionId: sessionId) {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return true
    }

    private func trackRetiringLauncher(sessionId: String, launcher: PickyAgentDaemonLauncher) {
        pruneRetiringLaunchers(sessionId: sessionId)
        guard launcher.hasLiveProcess else { return }
        retiringChildren[sessionId, default: []].append(launcher)
    }

    private func pruneRetiringLaunchers(sessionId: String) {
        guard let retiring = retiringChildren[sessionId] else { return }
        let stillRunning = retiring.filter { $0.hasLiveProcess }
        retiringChildren[sessionId] = stillRunning.isEmpty ? nil : stillRunning
    }

    /// Terminate every child. Called when the primary daemon shuts down.
    /// `waitForExit` blocks until each Node process is gone; only app quit and
    /// update relaunch need that guarantee.
    func terminateAllChildren(waitForExit: Bool = false) {
        for sessionId in Array(children.keys) {
            terminateChild(sessionId: sessionId, waitForExit: waitForExit)
        }
    }

    // MARK: - Internal

    /// Parses the `picky-agentd listening on 127.0.0.1:<port>` line that both primary and
    /// child emit once their websocket server is bound.
    static func parseBoundPort(from line: String) -> Int? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = "picky-agentd listening on "
        guard trimmed.hasPrefix(prefix) else { return nil }
        let endpoint = trimmed.dropFirst(prefix.count)
        guard let colonIndex = endpoint.lastIndex(of: ":") else { return nil }
        let portPart = endpoint[endpoint.index(after: colonIndex)...]
        return Int(portPart)
    }

    private func handleChildStdoutLine(sessionId: String, line: String) {
        guard let child = children[sessionId], child.endpoint == nil else { return }
        guard let port = Self.parseBoundPort(from: line) else { return }
        let endpoint = PickyChildDaemonEndpoint(
            sessionId: sessionId,
            host: "127.0.0.1",
            port: port,
            token: configuration.token
        )
        spawnTimeoutTasks[sessionId]?.cancel()
        spawnTimeoutTasks.removeValue(forKey: sessionId)
        child.resolve(.success(endpoint))
        childEndpointRevision &+= 1
    }

    private func scheduleSpawnTimeout(sessionId: String, timeout: TimeInterval) {
        spawnTimeoutTasks[sessionId]?.cancel()
        let nanos = UInt64(max(timeout, 0) * 1_000_000_000)
        spawnTimeoutTasks[sessionId] = Task { [weak self] in
            try? await Task.sleep(nanoseconds: nanos)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                self?.failPendingSpawn(sessionId: sessionId, error: .spawnTimedOut(sessionId: sessionId, seconds: timeout))
            }
        }
    }

    private func failPendingSpawn(sessionId: String, error: PickyAgentDaemonPoolError) {
        guard let child = children[sessionId], child.endpoint == nil else { return }
        child.resolve(.failure(error))
        child.observerTask?.cancel()
        child.launcher.stop()
        trackRetiringLauncher(sessionId: sessionId, launcher: child.launcher)
        spawnTimeoutTasks[sessionId]?.cancel()
        spawnTimeoutTasks.removeValue(forKey: sessionId)
        children.removeValue(forKey: sessionId)
        activeChildSessionIds.remove(sessionId)
    }

    private func handlePostReadyChildExit(sessionId: String, exitCode: Int32?) {
        guard let child = children[sessionId] else { return }
        child.observerTask?.cancel()
        spawnTimeoutTasks[sessionId]?.cancel()
        spawnTimeoutTasks.removeValue(forKey: sessionId)
        children.removeValue(forKey: sessionId)
        activeChildSessionIds.remove(sessionId)
        onChildExitAfterReady?(sessionId, exitCode)
    }
}
