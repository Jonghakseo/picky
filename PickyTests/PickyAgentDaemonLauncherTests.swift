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
    func emitStdoutBytes(_ data: Data) { stdout?(data) }
    func emitStderr(_ text: String) { stderr?(Data(text.utf8)) }
    func crash(code: Int32) { terminationHandler?(code) }
}

private struct FakeExecutableChecker: PickyExecutableChecking {
    var exists: Bool
    var version: String? = nil
    var probeResult: PickyExecutableVersionProbeResult? = nil
    var missingExecutables: Set<String> = []
    var requiredVersionWorkingDirectory: URL? = nil

    func executableExists(named name: String, environment: [String: String]) -> Bool {
        exists && !missingExecutables.contains(name)
    }

    func executablePath(named name: String, environment: [String: String]) -> String? {
        executableExists(named: name, environment: environment) ? "/fake/bin/\(name)" : nil
    }

    func executableVersion(named name: String, environment: [String: String], workingDirectory: URL) -> String? {
        guard name == "node" else { return nil }
        if let requiredVersionWorkingDirectory, workingDirectory != requiredVersionWorkingDirectory { return nil }
        return version
    }

    func executableVersionProbe(named name: String, environment: [String: String], workingDirectory: URL) -> PickyExecutableVersionProbeResult {
        guard name == "node" else { return .emptyOutput }
        if let probeResult { return probeResult }
        if let requiredVersionWorkingDirectory, workingDirectory != requiredVersionWorkingDirectory { return .emptyOutput }
        guard let version, !version.isEmpty else { return .emptyOutput }
        return .version(version)
    }
}

private final class FakeDaemonClipboardWriter: PickyClipboardWriting {
    private(set) var copiedTexts: [String] = []

    func copy(_ text: String) {
        copiedTexts.append(text)
    }
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

    @Test func interceptsOSC52ClipboardRequestsFromStdout() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let clipboard = FakeDaemonClipboardWriter()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19012,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            clipboardWriter: clipboard
        )

        launcher.start()
        let payload = Data("hello from Pickle".utf8).base64EncodedString()
        runner.emitStdout("before\u{001B}]52;c;\(payload)\u{0007}after\n")

        let stdoutLog = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log"))
        #expect(clipboard.copiedTexts == ["hello from Pickle"])
        #expect(stdoutLog.contains("before"))
        #expect(stdoutLog.contains("after"))
        #expect(stdoutLog.contains("[Picky intercepted OSC52 clipboard request: 17 chars]"))
        #expect(!stdoutLog.contains(payload))
        #expect(!stdoutLog.contains("\u{001B}]52"))
    }

    @Test func interceptsOSC52ClipboardRequestsSplitAcrossStdoutChunks() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let clipboard = FakeDaemonClipboardWriter()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19013,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            clipboardWriter: clipboard
        )

        launcher.start()
        let payload = Data("split clipboard".utf8).base64EncodedString()
        runner.emitStdout("prefix\u{001B}]52;c;")
        runner.emitStdout(payload)
        runner.emitStdout("\u{001B}\\suffix")

        let stdoutLog = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log"))
        #expect(clipboard.copiedTexts == ["split clipboard"])
        #expect(stdoutLog == "prefix[Picky intercepted OSC52 clipboard request: 15 chars]\nsuffix")
    }

    @Test func interceptsOSC52ClipboardRequestsSplitBetweenEscapeAndBracket() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let clipboard = FakeDaemonClipboardWriter()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19015,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            clipboardWriter: clipboard
        )

        launcher.start()
        let payload = Data("edge split".utf8).base64EncodedString()
        runner.emitStdout("prefix\u{001B}")
        runner.emitStdout("]52;c;\(payload)\u{0007}suffix")

        let stdoutLog = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log"))
        #expect(clipboard.copiedTexts == ["edge split"])
        #expect(stdoutLog == "prefix[Picky intercepted OSC52 clipboard request: 10 chars]\nsuffix")
    }

    @Test func stripsNonClipboardOSCSequencesFromStdoutLogs() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let clipboard = FakeDaemonClipboardWriter()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19014,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            clipboardWriter: clipboard
        )

        launcher.start()
        runner.emitStdout("x\u{001B}]0;secret title\u{0007}y")

        let stdoutLog = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.stdout.log"))
        #expect(clipboard.copiedTexts.isEmpty)
        #expect(stdoutLog == "x[Picky stripped terminal OSC sequence: OSC 0]\ny")
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

    @Test func primaryEnvironmentTrimsMainAgentModelAndKeepsPickleOverrides() throws {
        var configuration = PickyAgentDaemonConfiguration(
            port: 19017,
            token: "token-123",
            appSupportRoot: URL(fileURLWithPath: "/tmp/picky-support"),
            defaultCwd: "/Users/test/project",
            mainAgentCwd: "/Users/test/main",
            mainAgentModelPattern: "  anthropic/claude-sonnet  ",
            pickleAgentThinkingLevel: .high,
            pickleAgentModelPattern: "  openai/gpt-test  ",
            runtime: nil,
            workingDirectory: URL(fileURLWithPath: "/tmp/agentd"),
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        configuration.baseEnvironment = ["PATH": "/usr/bin"]

        let env = configuration.environment

        #expect(env["PICKY_AGENTD_MODE"] == "primary")
        #expect(env["PICKY_MAIN_AGENT_MODEL"] == "anthropic/claude-sonnet")
        #expect(env["PICKY_PICKLE_THINKING_LEVEL"] == "high")
        #expect(env["PICKY_PICKLE_MODEL"] == "openai/gpt-test")
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

    @Test func oldNodeVersionFailsFriendlyWithoutRestartLoop() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19018,
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
            executableChecker: FakeExecutableChecker(exists: true, version: "v22.11.0")
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("Node.js 22.19.0 or newer is required"))
            #expect(message.contains("v22.11.0"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func supportedNodeVersionPassesPreflight() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19019,
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
            executableChecker: FakeExecutableChecker(exists: true, version: "v22.19.0")
        )

        launcher.start()

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func nodeVersionProbeUsesDaemonWorkingDirectory() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd, compiled: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19022,
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
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            executableChecker: FakeExecutableChecker(exists: true, version: "v22.19.0", requiredVersionWorkingDirectory: agentd)
        )

        launcher.start()

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func unknownNodeVersionFailsFriendlyWithoutLaunching() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19020,
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
            executableChecker: FakeExecutableChecker(exists: true, version: nil)
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("Node.js 22.19.0 or newer is required"))
            #expect(message.contains("node --version produced no output"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func timedOutNodeVersionProbeFailsWithSpecificMessageAndSnapshot() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19023,
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
            executableChecker: FakeExecutableChecker(exists: true, probeResult: .timedOut(seconds: 5))
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("could not verify the current node version"))
            #expect(message.contains("timed out after 5s"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        let snapshot = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.node-preflight.json"))
        #expect(snapshot.contains(#""status" : "timedOut""#))
        #expect(snapshot.contains(#""nodePath" : "\/fake\/bin\/node""#))
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func failedNodeVersionProbeIncludesExitCodeInMessageAndSnapshot() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19024,
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
            executableChecker: FakeExecutableChecker(exists: true, probeResult: .failed(exitCode: 42, output: "shim failed"))
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("node --version exited with code 42"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        let snapshot = try String(contentsOf: temp.appendingPathComponent("Logs/agentd.node-preflight.json"))
        #expect(snapshot.contains(#""status" : "failed""#))
        #expect(snapshot.contains(#""exitCode" : 42"#))
        #expect(snapshot.contains("shim failed"))
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func sourceModeStillRequiresNodePreflight() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd, source: true)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19021,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "--dir", agentd.path, "exec", "tsx", "src/index.ts"],
            requiredExecutableName: "pnpm",
            requiredAgentdEntryPoint: "src/index.ts"
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            executableChecker: FakeExecutableChecker(exists: true, version: nil, missingExecutables: ["node"])
        )

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("node not found"))
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func stdoutLineObserverDeliversReadyLineEvenWhenChunkSplitsMidCodepoint() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        var observedLines: [String] = []
        let configuration = PickyAgentDaemonConfiguration(
            port: 19099,
            token: "tok",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            stdoutLineObserver: { observedLines.append($0) }
        )
        launcher.start()

        // Stream chunk 1: a complete ready line followed by a prefix that ends with the first
        // two bytes of a Korean codepoint ("\u{B300}" is 0xEB 0x8C 0x80 in UTF-8). Decoding the
        // chunk as a whole would fail; the line observer must still emit the ready line.
        let kor = "\u{B300}\u{AE30}".data(using: .utf8)!
        let chunk1 = Data("picky-agentd listening on 127.0.0.1:55555\nthinking ".utf8) + kor.prefix(2)
        runner.emitStdoutBytes(chunk1)
        #expect(observedLines == ["picky-agentd listening on 127.0.0.1:55555"])

        // Stream chunk 2: the rest of the multibyte codepoint + the second codepoint + LF. The
        // buffered prefix should now close into a complete UTF-8 line containing the Korean.
        let chunk2 = kor.suffix(from: 2) + Data(" complete\n".utf8)
        runner.emitStdoutBytes(chunk2)
        #expect(observedLines.last == "thinking \u{B300}\u{AE30} complete")
    }

    @Test func stdoutLineObserverIgnoresCarriageReturnsBeforeLF() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        var observedLines: [String] = []
        let configuration = PickyAgentDaemonConfiguration(
            port: 19100, token: "tok", appSupportRoot: temp, defaultCwd: "/tmp",
            runtime: nil, workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration, runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            stdoutLineObserver: { observedLines.append($0) }
        )
        launcher.start()
        runner.emitStdout("picky-agentd listening on 127.0.0.1:65535\r\n")
        #expect(observedLines == ["picky-agentd listening on 127.0.0.1:65535"])
    }

    @Test func writesStatusSnapshotOnEveryLifecycleTransition() async throws {
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19200, token: "tok", appSupportRoot: temp, defaultCwd: "/tmp",
            runtime: nil, workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"), arguments: ["node", "dist/index.js"]
        )
        let logsDir = temp.appendingPathComponent("Logs")
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration, runner: runner,
            logDirectory: logsDir
        )
        let statusURL = logsDir.appendingPathComponent("agentd.status.json")
        let primaryStatusURL = logsDir.appendingPathComponent("agentd.status.primary.json")

        launcher.start()
        #expect(FileManager.default.fileExists(atPath: primaryStatusURL.path))
        let runningSnapshot = try decodeStatus(at: statusURL)
        #expect(runningSnapshot.state == "running")
        #expect(runningSnapshot.role == "primary")
        #expect(runningSnapshot.port == 19200)
        #expect(runningSnapshot.lastRunningAt != nil)
        let roleSpecificRunningSnapshot = try decodeStatus(at: primaryStatusURL)
        #expect(roleSpecificRunningSnapshot == runningSnapshot)

        runner.crash(code: 137)
        // The launcher's termination handler hops to the MainActor via
        // `Task { @MainActor ... }`, so the status file is rewritten
        // asynchronously. Yield a couple of times so the queued task lands
        // before we read back the file.
        for _ in 0..<5 { await Task.yield() }
        let crashedSnapshot = try decodeStatus(at: statusURL)
        #expect(crashedSnapshot.state == "restarting" || crashedSnapshot.state == "crashed")

        launcher.stop()
        let stoppedSnapshot = try decodeStatus(at: statusURL)
        #expect(stoppedSnapshot.state == "stopped")
    }

    private func decodeStatus(at url: URL) throws -> PickyDaemonStatusSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PickyDaemonStatusSnapshot.self, from: data)
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
