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
    private(set) var launchCount = 0
    private(set) var didTerminate = false
    var launchError: Error?
    private var stdout: ((Data) -> Void)?
    private var stderr: ((Data) -> Void)?
    private var launchTerminationHandlers: [((Int32) -> Void)?] = []

    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        if let launchError { throw launchError }
        launchedConfiguration = configuration
        launchCount += 1
        launchTerminationHandlers.append(terminationHandler)
        self.stdout = stdout
        self.stderr = stderr
    }

    func terminate() { didTerminate = true }
    func emitStdout(_ text: String) { stdout?(Data(text.utf8)) }
    func emitStdoutBytes(_ data: Data) { stdout?(data) }
    func emitStderr(_ text: String) { stderr?(Data(text.utf8)) }
    func crash(code: Int32) { terminationHandler?(code) }
    func terminateLaunch(at index: Int, code: Int32) { launchTerminationHandlers[index]?(code) }
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

/// Deterministic stand-in for the launcher's restart backoff sleep. Each
/// scheduled restart suspends until the test resumes it, so tests never wait
/// wall-clock backoff time. `resumeNext()` is banked if it arrives before the
/// restart task has started sleeping.
@MainActor
private final class ManualRestartDelayScheduler {
    private(set) var requestedDelays: [TimeInterval] = []
    private var pending: [CheckedContinuation<Void, Never>] = []
    private var bankedResumes = 0

    func sleep(for delay: TimeInterval) async {
        requestedDelays.append(delay)
        if bankedResumes > 0 {
            bankedResumes -= 1
            return
        }
        // A restart task cancelled before it reaches this sleep must not park a
        // continuation that no test-side resume will ever release.
        if Task.isCancelled { return }
        await withCheckedContinuation { pending.append($0) }
    }

    func resumeNext() {
        if pending.isEmpty {
            bankedResumes += 1
        } else {
            pending.removeFirst().resume()
        }
    }

    func resumeAll() {
        bankedResumes = 0
        let continuations = pending
        pending = []
        for continuation in continuations { continuation.resume() }
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
        #expect(runner.launchedConfiguration?.environment["PICKY_AGENTD_PARENT_PID"] == String(ProcessInfo.processInfo.processIdentifier))
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
        let scheduler = ManualRestartDelayScheduler()
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            restartSleep: { await scheduler.sleep(for: $0) }
        )

        launcher.start()
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)

        #expect(launcher.state == .restarting(attempt: 1, delay: 1))
        launcher.stop()
        scheduler.resumeAll()
    }

    @Test func repeatedImmediateCrashesIncreaseRestartBackoff() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        var currentTime = Date(timeIntervalSince1970: 1_000)
        let configuration = PickyAgentDaemonConfiguration(
            port: 19032,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let scheduler = ManualRestartDelayScheduler()
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            now: { currentTime },
            restartSleep: { await scheduler.sleep(for: $0) }
        )

        launcher.start()
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)
        #expect(launcher.state == .restarting(attempt: 1, delay: 1))

        scheduler.resumeNext()
        try await waitForState(of: launcher) { $0 == .running }
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)
        #expect(launcher.state == .restarting(attempt: 2, delay: 2))

        scheduler.resumeNext()
        try await waitForState(of: launcher) { $0 == .running }
        currentTime.addTimeInterval(30)
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)
        #expect(launcher.state == .restarting(attempt: 1, delay: 1))
        launcher.stop()
        scheduler.resumeAll()
    }

    @Test func explicitRestartResetsCrashBackoffAttempts() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19033,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let scheduler = ManualRestartDelayScheduler()
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            restartSleep: { await scheduler.sleep(for: $0) }
        )

        launcher.start()
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)
        #expect(launcher.state == .restarting(attempt: 1, delay: 1))

        launcher.stop()
        launcher.start()
        runner.crash(code: 9)
        try await waitForState(of: launcher, matching: isRestarting)

        #expect(launcher.state == .restarting(attempt: 1, delay: 1))
        launcher.stop()
        scheduler.resumeAll()
    }

    @Test func delayedTerminationFromStoppedLaunchDoesNotAffectNewLaunch() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19034,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs")
        )

        launcher.start()
        launcher.stop()
        launcher.start()
        runner.terminateLaunch(at: 0, code: 15)
        await drainMainActorHops()

        #expect(launcher.state == .running)
        #expect(runner.launchCount == 2)
    }

    @Test func stalePreflightFailureDoesNotRestartAfterExplicitRelaunch() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19035,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["pnpm", "dev"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs")
        )

        launcher.start()
        launcher.stop()
        // The replacement launch fails preflight (package removed), so it must
        // still invalidate the previous launch's pending termination callback.
        try FileManager.default.removeItem(at: temp.appendingPathComponent("package.json"))
        launcher.start()
        runner.terminateLaunch(at: 0, code: 15)
        await drainMainActorHops()

        #expect({ if case .failedToStart = launcher.state { return true }; return false }())
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
        #expect(configuration.nodeSource == .absent)
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

    @Test func resolveNodeExecutableWithPickyNodePathOverrideReturnsAbsolute() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let node = temp.appendingPathComponent("override-node")
        try makeExecutableFile(at: node)

        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: nil,
            environment: ["PICKY_NODE_PATH": node.path]
        )

        #expect(resolved == .absolute(node, source: .override))
    }

    @Test func resolveNodeExecutableWithBundledNodeReturnsAbsolute() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let node = resources.appendingPathComponent("agentd-runtime/bin/node")
        try makeExecutableFile(at: node)

        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: resources,
            environment: [:]
        )

        #expect(resolved == .absolute(node, source: .bundled))
    }

    @Test func resolveNodeExecutableOverrideWinsOverBundle() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundledNode = resources.appendingPathComponent("agentd-runtime/bin/node")
        let overrideNode = temp.appendingPathComponent("override-node")
        try makeExecutableFile(at: bundledNode)
        try makeExecutableFile(at: overrideNode)

        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: resources,
            environment: ["PICKY_NODE_PATH": overrideNode.path]
        )

        #expect(resolved == .absolute(overrideNode, source: .override))
    }

    @Test func resolveNodeExecutableInvalidOverrideFallsBack() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundledNode = resources.appendingPathComponent("agentd-runtime/bin/node")
        try makeExecutableFile(at: bundledNode)

        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: resources,
            environment: ["PICKY_NODE_PATH": temp.appendingPathComponent("missing-node").path]
        )

        #expect(resolved == .absolute(bundledNode, source: .bundled))
    }

    @Test func resolveNodeExecutableNoBundleNoOverrideReturnsViaEnv() {
        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: nil,
            environment: [:]
        )

        #expect(resolved == .viaEnv)
    }

    @Test func resolveNodeExecutableRejectsDirectoryOverride() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        // A bare directory is searchable/executable per POSIX, so FileManager.isExecutableFile
        // would otherwise accept it. We must reject it so we don't try to spawn a directory.
        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: nil,
            environment: ["PICKY_NODE_PATH": temp.path]
        )

        #expect(resolved == .viaEnv)
    }

    @Test func resolveNodeExecutableRejectsBundledDirectory() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundledNodeDir = resources.appendingPathComponent("agentd-runtime/bin/node", isDirectory: true)
        try FileManager.default.createDirectory(at: bundledNodeDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let resolved = PickyAgentDaemonConfiguration.resolveNodeExecutable(
            bundleResourceURL: resources,
            environment: [:]
        )

        #expect(resolved == .viaEnv)
    }

    @Test func configurationExternalCompiledWithBundledNodeUsesAbsolutePath() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundledNode = resources.appendingPathComponent("agentd-runtime/bin/node")
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeExecutableFile(at: bundledNode)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: resources
        )

        #expect(configuration.executableURL == bundledNode)
        #expect(configuration.arguments == [agentd.appendingPathComponent("dist/index.js").path])
        #expect(configuration.requiredExecutableName == nil)
    }

    @Test func configurationExternalCompiledWithBundledNodeSetsNodeSourceBundled() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let resources = temp.appendingPathComponent("Resources", isDirectory: true)
        let bundledNode = resources.appendingPathComponent("agentd-runtime/bin/node")
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeExecutableFile(at: bundledNode)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: resources
        )

        #expect(configuration.nodeSource == .bundled)
    }

    @Test func configurationExternalCompiledWithOverrideSetsNodeSourceOverride() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let overrideNode = temp.appendingPathComponent("override-node")
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeExecutableFile(at: overrideNode)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: [
                "PICKY_AGENTD_ROOT": agentd.path,
                "PICKY_NODE_PATH": overrideNode.path
            ],
            bundleResourceURL: nil
        )

        #expect(configuration.nodeSource == .override)
    }

    @Test func configurationExternalCompiledWithoutBundleOrOverrideSetsNodeSourceExternal() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )

        #expect(configuration.nodeSource == .external)
    }

    @Test func configurationExternalSourcePnpmSetsNodeSourceAbsent() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd, source: true, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )

        #expect(configuration.nodeSource == .absent)
    }

    @Test func configurationExternalCompiledWithoutBundledNodeUsesEnvNode() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd-runtime", isDirectory: true)
        try makeAgentdPackage(at: agentd, compiled: true)

        let configuration = PickyAgentDaemonConfiguration.development(
            appSupportRoot: temp,
            environment: ["PICKY_AGENTD_ROOT": agentd.path],
            bundleResourceURL: nil
        )

        #expect(configuration.executableURL == URL(fileURLWithPath: "/usr/bin/env"))
        #expect(configuration.arguments == ["node", agentd.appendingPathComponent("dist/index.js").path])
        #expect(configuration.nodeSource == .external)
        #expect(configuration.requiredExecutableName == "node")
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

    @Test func missingOverrideNodeExecutableFailsWithActionableMessage() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let missingNode = temp.appendingPathComponent("missing-node")
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19026,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: missingNode,
            arguments: ["dist/index.js"],
            nodeSource: .override
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message == "PICKY_NODE_PATH=\(missingNode.path) is not executable. Unset the variable or point it to a Node 22.x binary.")
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
    }

    @Test func missingBundledNodeExecutableFailsWithActionableMessage() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let missingNode = temp.appendingPathComponent("agentd-runtime/bin/node")
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19027,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: nil,
            workingDirectory: temp,
            executableURL: missingNode,
            arguments: ["dist/index.js"],
            nodeSource: .bundled
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: temp.appendingPathComponent("Logs"))

        launcher.start()

        if case .failedToStart(let message) = launcher.state {
            #expect(message == "Bundled Node at \(missingNode.path) is missing or not executable. Reinstall Picky.")
        } else {
            Issue.record("Expected friendly failedToStart state")
        }
        #expect(runner.launchedConfiguration == nil)
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

    @Test func nodeVersionValidationIsDeferredToAgentdStartup() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        var configuration = PickyAgentDaemonConfiguration(
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
        configuration.nodeSource = .external
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: temp.appendingPathComponent("Logs"),
            executableChecker: FakeExecutableChecker(exists: true, version: "v22.11.0")
        )

        launcher.start()

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration != nil)
        let snapshot = try decodeNodePreflight(at: temp.appendingPathComponent("Logs/agentd.node-preflight.json"))
        #expect(snapshot.status == "deferredToAgentd")
        #expect(snapshot.nodeSource == "external")
        #expect(snapshot.executablePath == "/usr/bin/env")
        #expect(snapshot.failureReason?.contains("process.versions.node") == true)
    }

    @Test func statusSnapshotRecordsRuntimeAndPortConflictClassification() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let runner = FakeProcessRunner()
        var configuration = PickyAgentDaemonConfiguration(
            port: 17631,
            token: "token-123",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: "mock",
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        configuration.nodeSource = .external
        let logs = temp.appendingPathComponent("Logs")
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: logs)

        launcher.start()
        runner.emitStderr("Error: listen EADDRINUSE: address already in use 127.0.0.1:17631\n")

        let snapshot = try decodeStatus(at: logs.appendingPathComponent("agentd.status.json"))
        #expect(snapshot.state == "running")
        #expect(snapshot.agentdRuntimeOverride == "mock")
        #expect(snapshot.nodeSource == "external")
        #expect(snapshot.executablePath == "/usr/bin/env")
        #expect(snapshot.workingDirectory == agentd.path)
        #expect(snapshot.lastFailureKind == "portConflict")
        #expect(snapshot.lastFailurePort == 17631)
        #expect(snapshot.lastFailureAt != nil)
    }

    @Test func unsupportedNodeDiagnosticStopsRestartLoopWithActionableState() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        try makeAgentdPackage(at: temp)
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19025,
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
            executableChecker: FakeExecutableChecker(exists: true, version: "v18.12.1")
        )

        launcher.start()
        runner.emitStderr("PICKY_UNSUPPORTED_NODE:18.12.1:required=22.19.0\n")
        runner.crash(code: 2)
        await drainMainActorHops()

        if case .failedToStart(let message) = launcher.state {
            #expect(message.contains("Node 18.12.1 is too old"))
            #expect(message.contains("22.19.0"))
        } else {
            Issue.record("Expected unsupported Node to become a terminal failedToStart state")
        }
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

    @Test func nodeVersionHelperProbeIsNotRequiredForDaemonWorkingDirectory() throws {
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
            executableChecker: FakeExecutableChecker(exists: true, probeResult: .timedOut(seconds: 5), requiredVersionWorkingDirectory: agentd)
        )

        launcher.start()

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func unknownNodeVersionDoesNotBlockLauncherPreflight() throws {
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

        #expect(launcher.state == .running)
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func timedOutNodeVersionHelperDoesNotBlockLauncherPreflight() throws {
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

        #expect(launcher.state == .running)
        let snapshot = try decodeNodePreflight(at: temp.appendingPathComponent("Logs/agentd.node-preflight.json"))
        #expect(snapshot.status == "deferredToAgentd")
        #expect(snapshot.nodePath == "/fake/bin/node")
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func failedNodeVersionHelperDoesNotBlockLauncherPreflight() throws {
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

        #expect(launcher.state == .running)
        let snapshot = try decodeNodePreflight(at: temp.appendingPathComponent("Logs/agentd.node-preflight.json"))
        #expect(snapshot.status == "deferredToAgentd")
        #expect(snapshot.version == nil)
        #expect(snapshot.outputPreview == nil)
        #expect(runner.launchedConfiguration != nil)
    }

    @Test func sourceModeStillRequiresNodeExecutable() throws {
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
        // asynchronously. Under the full parallel suite, a fixed number of
        // yields can still race with other MainActor-heavy tests, so poll until
        // the lifecycle snapshot advances.
        let crashedSnapshot = try await waitForStatus(at: statusURL) { snapshot in
            snapshot.state == "restarting" || snapshot.state == "crashed"
        }
        #expect(crashedSnapshot.state == "restarting" || crashedSnapshot.state == "crashed")

        launcher.stop()
        let stoppedSnapshot = try decodeStatus(at: statusURL)
        #expect(stoppedSnapshot.state == "stopped")
    }

    private func decodeStatus(at url: URL) throws -> PickyDaemonStatusSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PickyDaemonStatusSnapshot.self, from: data)
    }

    private func decodeNodePreflight(at url: URL) throws -> PickyNodePreflightSnapshot {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PickyNodePreflightSnapshot.self, from: data)
    }

    private func isRestarting(_ state: PickyDaemonLifecycleState) -> Bool {
        if case .restarting = state { return true }
        return false
    }

    private func waitForState(
        of launcher: PickyAgentDaemonLauncher,
        timeout: TimeInterval = 10,
        matching predicate: (PickyDaemonLifecycleState) -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate(launcher.state) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for launcher state; last=\(launcher.state)")
    }

    /// The launcher's termination handler hops to the MainActor via `Task`.
    /// Yielding re-enqueues this test task behind hops that were already
    /// queued, so "state did not change" assertions can run after the hop
    /// without a fixed real-time sleep.
    private func drainMainActorHops() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func waitForStatus(
        at url: URL,
        timeout: TimeInterval = 10,
        matching predicate: (PickyDaemonStatusSnapshot) -> Bool
    ) async throws -> PickyDaemonStatusSnapshot {
        let deadline = Date().addingTimeInterval(timeout)
        var latest = try decodeStatus(at: url)
        while Date() < deadline {
            latest = try decodeStatus(at: url)
            if predicate(latest) { return latest }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        Issue.record("Timed out waiting for daemon status snapshot")
        return latest
    }

    @Test func stdoutLogRotatesWhenSizeExceedsThreshold() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let logs = temp.appendingPathComponent("Logs")
        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19030,
            token: "token-rotate",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: "mock",
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(
            configuration: configuration,
            runner: runner,
            logDirectory: logs,
            maxLogFileSize: 1024,
            maxLogRotations: 2
        )

        launcher.start()
        let chunk = String(repeating: "X", count: 600) + "\n"
        runner.emitStdout(chunk) // ~600B, under threshold
        runner.emitStdout(chunk) // ~1.2KB total, the third write triggers rotation
        runner.emitStdout("AFTER_FIRST_ROTATION\n")
        runner.emitStdout(String(repeating: "Y", count: 600) + "\n")
        runner.emitStdout(String(repeating: "Z", count: 600) + "\n")
        runner.emitStdout("AFTER_SECOND_ROTATION\n")

        let stdout = logs.appendingPathComponent("agentd.stdout.log")
        let backup1 = logs.appendingPathComponent("agentd.stdout.log.1")
        let backup2 = logs.appendingPathComponent("agentd.stdout.log.2")
        let backup3 = logs.appendingPathComponent("agentd.stdout.log.3")

        #expect(FileManager.default.fileExists(atPath: backup1.path))
        #expect(FileManager.default.fileExists(atPath: backup2.path))
        #expect(!FileManager.default.fileExists(atPath: backup3.path), "maxLogRotations=2 must cap at .2")

        let live = try String(contentsOf: stdout)
        #expect(live.contains("AFTER_SECOND_ROTATION"))
        let liveSize = (try FileManager.default.attributesOfItem(atPath: stdout.path)[.size] as? NSNumber)?.int64Value ?? 0
        #expect(liveSize <= 1024 + Int64(600 + 1))
    }

    @Test func startPurgesStaleChildSessionStatusFilesOlderThan24Hours() throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("picky-launcher-\(UUID().uuidString)", isDirectory: true)
        let agentd = temp.appendingPathComponent("agentd", isDirectory: true)
        try makeAgentdPackage(at: agentd)
        let logs = temp.appendingPathComponent("Logs")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)

        let stalePath = logs.appendingPathComponent("agentd.status.child-session-AAA.json")
        let freshPath = logs.appendingPathComponent("agentd.status.child-session-BBB.json")
        let unrelatedPath = logs.appendingPathComponent("agentd.status.primary.json")
        try "{}".write(to: stalePath, atomically: true, encoding: .utf8)
        try "{}".write(to: freshPath, atomically: true, encoding: .utf8)
        try "{}".write(to: unrelatedPath, atomically: true, encoding: .utf8)
        let twoDaysAgo = Date(timeIntervalSinceNow: -2 * 24 * 60 * 60)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: stalePath.path)
        try FileManager.default.setAttributes([.modificationDate: twoDaysAgo], ofItemAtPath: unrelatedPath.path)

        let runner = FakeProcessRunner()
        let configuration = PickyAgentDaemonConfiguration(
            port: 19031,
            token: "token-purge",
            appSupportRoot: temp,
            defaultCwd: "/tmp",
            runtime: "mock",
            workingDirectory: agentd,
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["node", "dist/index.js"]
        )
        let launcher = PickyAgentDaemonLauncher(configuration: configuration, runner: runner, logDirectory: logs)

        launcher.start()

        #expect(!FileManager.default.fileExists(atPath: stalePath.path))
        #expect(FileManager.default.fileExists(atPath: freshPath.path), "recent child-session status must be preserved")
        #expect(FileManager.default.fileExists(atPath: unrelatedPath.path), "non-child-session status files must be preserved even when stale")
    }
}

private func makeExecutableFile(at url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
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
