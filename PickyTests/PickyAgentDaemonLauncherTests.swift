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

private struct FakeExecutableChecker: PickyExecutableChecking {
    var exists: Bool

    func executableExists(named name: String, environment: [String: String]) -> Bool { exists }
}

@MainActor
struct PickyAgentDaemonLauncherTests {
    @Test func buildsDaemonEnvironmentAndCapturesLogs() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19002,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/Users/test/project",
            runtime: "mock",
            workingDirectory: agentd,
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
        #expect(runner.launchedConfiguration?.environment["PICKY_MAIN_AGENT_THINKING_LEVEL"] == "medium")
        #expect(runner.launchedConfiguration?.environment["PICKY_AGENTD_RUNTIME"] == "mock")
        #expect(try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log")).contains("ready"))
        #expect(try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stderr.log")).contains("warn"))
    }

    @Test func restartsWithBackoffAfterCrash() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
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
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd, source: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration.development(
            port: 19004,
            token: "token",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs")
        )

        launcher.start()
        launcher.stop()
        runner.crash(code: 15)

        #expect(runner.didTerminate)
        #expect(launcher.state == .stopped)
    }

    @Test func externalSourceOverrideUsesPnpmExecForDevelopment() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd, source: true, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )

        #expect(configuration.workingDirectory == agentd)
        #expect(configuration.arguments == ["pnpm", "--dir", agentd.path, "exec", "tsx", "src/index.ts"])
        #expect(configuration.requiredExecutableName == "pnpm")
        #expect(configuration.requiredAgentdEntryPoint == "src/index.ts")
    }

    @Test func externalCompiledOverrideUsesNodeRuntime() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )

        #expect(configuration.workingDirectory == agentd)
        #expect(configuration.arguments == ["node", agentd.appendingPathComponent("dist/index.js").path])
        #expect(configuration.requiredExecutableName == "node")
        #expect(configuration.requiredAgentdEntryPoint == "dist/index.js")
    }

    @Test func bundledCompiledAgentdUsesNodeWithoutPnpm() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundled = resources.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: bundled, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: [:],
            bundleResourceURL: resources
        )

        #expect(configuration.workingDirectory == bundled)
        #expect(configuration.arguments == ["node", bundled.appendingPathComponent("dist/index.js").path])
        #expect(configuration.requiredExecutableName == "node")
        #expect(configuration.requiredAgentdEntryPoint == "dist/index.js")
    }

    @Test func invalidOverrideDoesNotFallbackToBundledAgentd() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        try makeAgentdPackage(at: resources.appendingPathComponent("agentd", isDirectory: true), compiled: true)
        let invalidOverride = temp.appendingPathComponent("invalid-agentd", isDirectory: true)
        try FileManager.default.createDirectory(at: invalidOverride, withIntermediateDirectories: true)

        let location = PickyAgentdRootResolver.resolveRuntimeLocation(
            environment: ["PICKY_AGENTD_ROOT": invalidOverride.path],
            bundleResourceURL: resources
        )

        #expect(location == .missingExternal(invalidOverride))
    }

    @Test func missingBundledAgentdFailsFriendlyWithoutSourceTreeFallback() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: [:],
            bundleResourceURL: resources
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("Bundled picky-agentd was not found"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func missingAgentdPackageFailsFriendlyWithoutRestartLoop() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19005,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp.appendingPathComponent("missing-agentd"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("picky-agentd was not found"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func missingAgentdEntryPointFailsFriendlyWithoutRestartLoop() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19007,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", agentd.appendingPathComponent("dist/index.js").path],
            requiredExecutableName: "node",
            requiredAgentdEntryPoint: "dist/index.js"
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("entry point was not found"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func daemonEnvironmentAugmentsFinderStylePathForNodeAndPnpm() throws {
        let environment = PickyAgentDaemonConfiguration.augmentedExecutablePATH(from: [
            "HOME": "/Users/example",
            "PATH": "/usr/bin:/bin"
        ])

        let paths = environment.split(separator: ":").map(String.init)
        #expect(paths.contains("/Users/example/Library/pnpm"))
        #expect(paths.contains("/opt/homebrew/bin"))
        #expect(paths.contains("/usr/local/bin"))
        #expect(paths.filter { $0 == "/usr/bin" }.count == 1)
    }

    @Test func missingRequiredExecutableFailsFriendlyWithoutRestartLoop() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19006,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"],
            requiredExecutableName: "node"
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            executableChecker: FakeExecutableChecker(exists: false)
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("node not found"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }
}

private func makeAgentdPackage(at url: URL, source: Bool = false, compiled: Bool = false) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try "{}".write(to: url.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)

    if source {
        let src = url.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try "console.log('source');\n".write(to: src.appendingPathComponent("index.ts"), atomically: true, encoding: .utf8)
    }

    if compiled {
        let dist = url.appendingPathComponent("dist", isDirectory: true)
        try FileManager.default.createDirectory(at: dist, withIntermediateDirectories: true)
        try "console.log('compiled');\n".write(to: dist.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
    }
}
