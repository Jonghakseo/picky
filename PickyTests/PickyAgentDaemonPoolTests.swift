//
//  PickyAgentDaemonPoolTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class StubProcessRunner: PickyProcessRunning {
    var terminationHandler: ((Int32) -> Void)?
    private(set) var launchCount = 0
    private(set) var lastConfiguration: PickyAgentDaemonConfiguration?
    private(set) var didTerminate = false
    var launchError: Error?
    private var stdout: ((Data) -> Void)?
    private var stderr: ((Data) -> Void)?

    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        if let launchError { throw launchError }
        launchCount += 1
        lastConfiguration = configuration
        self.stdout = stdout
        self.stderr = stderr
    }

    func terminate() { didTerminate = true }
    func emitStdout(_ text: String) { stdout?(Data(text.utf8)) }
    func crash(code: Int32) { terminationHandler?(code) }
}

@MainActor
private final class StubLauncherFactory: PickyAgentDaemonLauncherMaking {
    private(set) var madeLaunchers: [(sessionId: String, launcher: PickyAgentDaemonLauncher, runner: StubProcessRunner)] = []
    private let agentdRoot: URL

    init(agentdRoot: URL) { self.agentdRoot = agentdRoot }

    func makeLauncher(
        configuration: PickyAgentDaemonConfiguration,
        stdoutLineObserver: @escaping (String) -> Void
    ) -> PickyAgentDaemonLauncher {
        let runner = StubProcessRunner()
        // Route the configuration's working directory through our stub agentd package so the
        // launcher's preflight passes.
        var rerouted = configuration
        rerouted.workingDirectory = agentdRoot
        let launcher = PickyAgentDaemonLauncher(
            configuration: rerouted,
            runner: runner,
            executableChecker: AlwaysExistsChecker(),
            stdoutLineObserver: stdoutLineObserver
        )
        let sessionId: String
        if case .child(let id, _, _) = configuration.role { sessionId = id } else { sessionId = "primary" }
        madeLaunchers.append((sessionId, launcher, runner))
        return launcher
    }

    func runner(for sessionId: String) -> StubProcessRunner? {
        madeLaunchers.first(where: { $0.sessionId == sessionId })?.runner
    }

    /// Polls until the launcher for `sessionId` has been created. Used instead of fixed sleeps
    /// to keep these tests deterministic across CI runs of different shapes.
    func waitForRunner(sessionId: String, timeoutMs: Int = 2_000) async throws -> StubProcessRunner {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let runner = runner(for: sessionId), runner.launchCount > 0 { return runner }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw RunnerWaitTimeout(sessionId: sessionId)
    }
}

private struct RunnerWaitTimeout: Error { let sessionId: String }

private struct AlwaysExistsChecker: PickyExecutableChecking {
    func executableExists(named name: String, environment: [String: String]) -> Bool { true }
    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String? {
        name == "node" ? "v22.19.0" : nil
    }
}

private func makeStubAgentdPackage(at url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "{}".write(to: url.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    let dist = url.appendingPathComponent("dist", isDirectory: true)
    try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
    try "console.log('stub');\n".write(to: dist.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
}

private func tempRoot() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("picky-pool-\(UUID().uuidString)", isDirectory: true)
}

@MainActor
struct PickyAgentDaemonPoolTests {
    @Test func parsesBoundPortFromStdoutReadyLine() {
        #expect(PickyAgentDaemonPool.parseBoundPort(from: "picky-agentd listening on 127.0.0.1:58942") == 58942)
        #expect(PickyAgentDaemonPool.parseBoundPort(from: "  picky-agentd listening on 127.0.0.1:1\n") == 1)
        #expect(PickyAgentDaemonPool.parseBoundPort(from: "noise") == nil)
        #expect(PickyAgentDaemonPool.parseBoundPort(from: "picky-agentd listening on 127.0.0.1:abc") == nil)
        #expect(PickyAgentDaemonPool.parseBoundPort(from: "picky-agentd listening on 127.0.0.1") == nil)
    }

    @Test func childConfigurationEnvIsScrubbedAndSetsChildMode() throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let config = PickyAgentDaemonConfiguration.child(
            sessionId: "pickle-abc",
            sessionCwd: "/tmp/workspace",
            primaryUrl: "ws://127.0.0.1:17631",
            token: "tok",
            appSupportRoot: root,
            pickleAgentThinkingLevel: .high,
            pickleAgentModelPattern: "anthropic/claude-sonnet-4-5",
            environment: [
                "PICKY_AGENTD_PORT": "17631",
                "PICKY_DEFAULT_CWD": "/should/be/dropped",
                "PICKY_MAIN_AGENT_CWD": "/should/be/dropped",
                "PICKY_MAIN_AGENT_THINKING_LEVEL": "high",
                "PICKY_AGENTD_ROOT": agentd.path,
                "PATH": "/usr/bin",
            ],
            bundleResourceURL: nil
        )
        let env = config.environment
        #expect(env["PICKY_AGENTD_MODE"] == "child")
        #expect(env["PICKY_AGENTD_SESSION_ID"] == "pickle-abc")
        #expect(env["PICKY_AGENTD_SESSION_CWD"] == "/tmp/workspace")
        #expect(env["PICKY_AGENTD_PRIMARY_URL"] == "ws://127.0.0.1:17631")
        #expect(env["PICKY_AGENTD_PORT"] == nil)
        #expect(env["PICKY_DEFAULT_CWD"] == nil)
        #expect(env["PICKY_MAIN_AGENT_CWD"] == nil)
        #expect(env["PICKY_MAIN_AGENT_THINKING_LEVEL"] == nil)
        #expect(env["PICKY_PICKLE_THINKING_LEVEL"] == "high")
        #expect(env["PICKY_PICKLE_MODEL"] == "anthropic/claude-sonnet-4-5")
    }

    @Test func childConfigurationScrubsLeakedPickleDefaultsWhenAutomatic() throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let config = PickyAgentDaemonConfiguration.child(
            sessionId: "pickle-auto",
            sessionCwd: "/tmp/workspace",
            primaryUrl: nil,
            token: "tok",
            appSupportRoot: root,
            environment: [
                "PICKY_PICKLE_THINKING_LEVEL": "xhigh",
                "PICKY_PICKLE_MODEL": "leaked/model",
                "PICKY_AGENTD_ROOT": agentd.path,
                "PATH": "/usr/bin",
            ],
            bundleResourceURL: nil
        )
        let env = config.environment
        #expect(env["PICKY_PICKLE_THINKING_LEVEL"] == nil)
        #expect(env["PICKY_PICKLE_MODEL"] == nil)
    }

    @Test func primaryConfigurationScrubsLeakedChildEnv() throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        // development() intentionally leaves baseEnvironment nil so production launchers
        // re-read ProcessInfo.processInfo.environment on every launch. To prove the scrub
        // independently of the host process env, override baseEnvironment on the resulting
        // configuration with the same injected dictionary we pass to the factory.
        let injectedEnv: [String: String] = [
            "PICKY_AGENTD_MODE": "child",
            "PICKY_AGENTD_SESSION_ID": "leaked",
            "PICKY_AGENTD_SESSION_CWD": "/leaked",
            "PICKY_AGENTD_PRIMARY_URL": "ws://leaked",
            "PICKY_AGENTD_ROOT": agentd.path,
            "PATH": "/usr/bin",
        ]
        var config = PickyAgentDaemonConfiguration.development(
            port: 17631,
            token: "tok",
            appSupportRoot: root,
            defaultCwd: "/Users/test",
            environment: injectedEnv,
            bundleResourceURL: nil
        )
        config.baseEnvironment = injectedEnv
        let env = config.environment
        #expect(env["PICKY_AGENTD_MODE"] == "primary")
        #expect(env["PICKY_AGENTD_SESSION_ID"] == nil)
        #expect(env["PICKY_AGENTD_SESSION_CWD"] == nil)
        #expect(env["PICKY_AGENTD_PRIMARY_URL"] == nil)
        #expect(env["PICKY_AGENTD_PORT"] == "17631")
    }

    @Test func spawnChildResolvesWhenStdoutAnnouncesBoundPort() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "shared-token",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil,
                settingsProvider: {
                    var settings = PickySettings.defaults()
                    settings.pickleAgentModelPattern = "openai/gpt-5.5"
                    settings.pickleAgentThinkingLevel = .xhigh
                    return settings
                }
            ),
            factory: factory
        )

        let spawnTask = Task { try await pool.spawnChild(sessionId: "pickle-1", cwd: "/tmp/ws", primaryUrl: nil) }
        let runner = try await factory.waitForRunner(sessionId: "pickle-1")
        runner.emitStdout("picky-agentd listening on 127.0.0.1:54321\n")

        let childEnv = try #require(runner.lastConfiguration?.environment)
        #expect(childEnv["PICKY_PICKLE_MODEL"] == "openai/gpt-5.5")
        #expect(childEnv["PICKY_PICKLE_THINKING_LEVEL"] == "xhigh")

        let endpoint = try await spawnTask.value
        #expect(endpoint.sessionId == "pickle-1")
        #expect(endpoint.port == 54321)
        #expect(endpoint.token == "shared-token")
        #expect(endpoint.url.absoluteString == "ws://127.0.0.1:54321/")
        #expect(pool.activeChildSessionIds.contains("pickle-1"))
    }

    @Test func spawnChildFailsWhenChildExitsBeforeReady() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: factory
        )
        let spawnTask = Task { try await pool.spawnChild(sessionId: "pickle-2", cwd: "/tmp/ws") }
        let runner = try await factory.waitForRunner(sessionId: "pickle-2")
        runner.crash(code: 7)

        do {
            _ = try await spawnTask.value
            #expect(Bool(false), "spawn should have failed")
        } catch let error as PickyAgentDaemonPoolError {
            #expect(error == .childExitedBeforeReady(sessionId: "pickle-2", exitCode: 7))
        }
        #expect(!pool.activeChildSessionIds.contains("pickle-2"))
    }

    @Test func spawnChildRejectsDuplicateSessionId() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: factory
        )
        let firstSpawn = Task { try await pool.spawnChild(sessionId: "pickle-3", cwd: "/tmp/ws") }
        let runner = try await factory.waitForRunner(sessionId: "pickle-3")
        runner.emitStdout("picky-agentd listening on 127.0.0.1:11111\n")
        _ = try await firstSpawn.value

        do {
            _ = try await pool.spawnChild(sessionId: "pickle-3", cwd: "/tmp/ws-other")
            #expect(Bool(false), "second spawn should have rejected duplicate")
        } catch let error as PickyAgentDaemonPoolError {
            #expect(error == .duplicateSessionId("pickle-3"))
        }
    }

    @Test func terminateChildCancelsPendingSpawn() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: factory
        )
        let spawnTask = Task { try await pool.spawnChild(sessionId: "pickle-4", cwd: "/tmp/ws") }
        _ = try await factory.waitForRunner(sessionId: "pickle-4")
        pool.terminateChild(sessionId: "pickle-4")
        do {
            _ = try await spawnTask.value
            #expect(Bool(false), "spawn should have been cancelled")
        } catch is CancellationError {
            // expected
        }
        #expect(pool.endpoint(for: "pickle-4") == nil)
    }

    @Test func postReadyCrashInvalidatesEndpointAndNotifiesObserver() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: factory
        )
        var exited: [(String, Int32?)] = []
        pool.onChildExitAfterReady = { sessionId, code in exited.append((sessionId, code)) }

        let spawnTask = Task { try await pool.spawnChild(sessionId: "pickle-post", cwd: "/tmp/ws") }
        let runner = try await factory.waitForRunner(sessionId: "pickle-post")
        runner.emitStdout("picky-agentd listening on 127.0.0.1:33333\n")
        _ = try await spawnTask.value
        #expect(pool.endpoint(for: "pickle-post") != nil)

        runner.crash(code: 11)
        // Allow the observer Task to react.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(pool.endpoint(for: "pickle-post") == nil)
        #expect(!pool.activeChildSessionIds.contains("pickle-post"))
        #expect(exited.count == 1)
        #expect(exited.first?.0 == "pickle-post")
        #expect(exited.first?.1 == 11)
    }

    @Test func childRoleSuppressesAutoRestartAfterCrash() async throws {
        let root = tempRoot()
        let agentd = root.appendingPathComponent("agentd", isDirectory: true)
        try makeStubAgentdPackage(at: agentd)
        let factory = StubLauncherFactory(agentdRoot: agentd)
        let pool = PickyAgentDaemonPool(
            configuration: PickyAgentDaemonPool.Configuration(
                token: "tok",
                appSupportRoot: root,
                spawnTimeout: 5,
                environment: ["PICKY_AGENTD_ROOT": agentd.path, "PATH": "/usr/bin"],
                bundleResourceURL: nil
            ),
            factory: factory
        )
        let spawnTask = Task { try await pool.spawnChild(sessionId: "pickle-restart", cwd: "/tmp/ws") }
        let runner = try await factory.waitForRunner(sessionId: "pickle-restart")
        runner.emitStdout("picky-agentd listening on 127.0.0.1:22222\n")
        _ = try await spawnTask.value

        // Simulate the child dying after it reported ready. Because child role disables the
        // launcher's auto-restart loop, the runner must not be launched a second time.
        runner.crash(code: 9)
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(runner.launchCount == 1)
    }
}
