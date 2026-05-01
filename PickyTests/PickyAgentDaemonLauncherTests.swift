//
//  PickyAgentDaemonLauncherTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

private final class FakeProcessRunner: PickyProcessRunning {
    var terminationHandler: ((Int32) -> Void)?
    private(set) var launchedConfiguration: PickyAgentDaemonConfiguration?
    private(set) var didTerminate = false
    var launchError: Error?
    private var stdout: ((Data) -> Void)?
    private var stderr: ((Data) -> Void)?

    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        if let launchError { throw launchError }
        launchedConfiguration = configuration
        self.stdout = stdout
        self.stderr = stderr
    }

    func terminate() { didTerminate = true }
    func emitStdout(_ text: String) { stdout?(Data(text.utf8)) }
    func emitStderr(_ text: String) { stderr?(Data(text.utf8)) }
    func crash(code: Int32) { terminationHandler?(code) }
}

private struct LaunchFailure: Error {}

@MainActor
struct PickyAgentDaemonLauncherTests {
    @Test func buildsDaemonEnvironmentAndCapturesLogs() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19002,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/Users/test/project",
            runtime: "mock",
            workingDirectory: temp.appendingPathComponent("agentd"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()
        runner.emitStdout("ready\n")
        runner.emitStderr("warn\n")

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration?.environment["PICKY_AGENTD_PORT"] == "19002")
        #expect(runner.launchedConfiguration?.environment["PICKY_AGENTD_TOKEN"] == "token-123")
        #expect(runner.launchedConfiguration?.environment["PICKY_AGENTD_RUNTIME"] == "mock")
        #expect(try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log")).contains("ready"))
        #expect(try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stderr.log")).contains("warn"))
    }

    @Test func restartsWithBackoffAfterCrash() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19003,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()
        runner.crash(code: 9)
        try await Task.sleep(nanoseconds: 20_000_000)

        #expect(launcher.state == .restarting(attempt: 1, delay: 1))
    }

    @Test func stopTerminatesWithoutRestart() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let runner = FakeProcessRunner()
        let launcher = PickyAgentDaemonLauncher(
            configuration: .development(port: 19004, token: "token", appSupportRoot: temp, defaultCwd: "/tmp"),
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs")
        )

        launcher.start()
        launcher.stop()
        runner.crash(code: 15)

        #expect(runner.didTerminate)
        #expect(launcher.state == .stopped)
    }
}
