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
        var endpoint: PickyChildDaemonEndpoint?
        var continuation: CheckedContinuation<PickyChildDaemonEndpoint, Error>?
        var observerTask: Task<Void, Never>?

        init(launcher: PickyAgentDaemonLauncher, continuation: CheckedContinuation<PickyChildDaemonEndpoint, Error>) {
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
    private var children: [String: Child] = [:]
    private var spawnTimeoutTasks: [String: Task<Void, Never>] = [:]

    @Published private(set) var activeChildSessionIds: Set<String> = []

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
                        stdoutLineObserver: { [weak self] line in
                            Task { @MainActor in self?.handleChildStdoutLine(sessionId: sessionId, line: line) }
                        }
                    )
                    let child = Child(launcher: launcher, continuation: continuation)
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

    /// Gracefully terminate a child daemon. Safe to call regardless of whether the child is
    /// currently spawning, running, or already exited; subsequent calls are no-ops.
    func terminateChild(sessionId: String) {
        guard let child = children[sessionId] else { return }
        child.resolve(.failure(CancellationError()))
        child.observerTask?.cancel()
        child.launcher.stop()
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

    /// Terminate every child. Called when the primary daemon shuts down.
    func terminateAllChildren() {
        for sessionId in Array(children.keys) { terminateChild(sessionId: sessionId) }
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
