//
//  ShellCommandInstallerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct ShellCommandInstallerTests {
    @Test func currentStatusIsNotInstalledWhenWrapperMissing() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: env.bundleURL)
        #expect(status == .notInstalled)
    }

    @Test func installWritesExecutableWrapperWithPinnedAppPath() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        #expect(FileManager.default.fileExists(atPath: env.installPath.path))
        let perms = try FileManager.default.attributesOfItem(atPath: env.installPath.path)[.posixPermissions] as? NSNumber
        #expect(perms?.uint16Value == 0o755)
        let body = try String(contentsOf: env.installPath, encoding: .utf8)
        #expect(body.contains("PICKY_APP_PATH='\(env.bundleURL.path)'"))
        #expect(body.contains("dist/cli.js"))
        #expect(body.contains("PICKY_NODE_OVERRIDE"))
    }

    @Test func currentStatusReportsCurrentAfterInstall() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: env.bundleURL)
        #expect(status == .installedCurrent(installPath: env.installPath))
    }

    @Test func currentStatusReportsStaleWhenPinnedPathDiffers() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let alternateBundle = env.makeAlternateBundle()
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: alternateBundle)
        guard case .installedStale(let pinnedInstallPath, let pinnedAppPath) = status else {
            Issue.record("expected installedStale status, got \(status)")
            return
        }
        #expect(pinnedInstallPath == env.installPath)
        #expect(pinnedAppPath == env.bundleURL.path)
    }

    @Test func currentStatusReportsForeignWhenScriptIsNotOurs() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try "#!/bin/sh\necho hello\n".write(to: env.installPath, atomically: true, encoding: .utf8)
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: env.bundleURL)
        #expect(status == .foreign(installPath: env.installPath))
    }

    @Test func installIsIdempotent() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: env.bundleURL)
        #expect(status == .installedCurrent(installPath: env.installPath))
    }

    @Test func uninstallRemovesWrapperAndIsIdempotent() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        #expect(FileManager.default.fileExists(atPath: env.installPath.path))
        try ShellCommandInstaller.uninstall(installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        #expect(!FileManager.default.fileExists(atPath: env.installPath.path))
        // Second uninstall on missing wrapper succeeds without throwing.
        try ShellCommandInstaller.uninstall(installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
    }

    @Test func installFailsWhenCliEntryMissing() throws {
        let env = try TempEnvironment(includeCli: false)
        defer { env.cleanup() }
        let runner = RecordingRunner()
        do {
            try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: runner)
            Issue.record("expected install to throw")
        } catch ShellCommandInstaller.InstallError.missingCliEntry {
            // ok
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(runner.invocations.isEmpty)
    }

    @Test func wrapperHandlesAppPathsContainingSpacesAndQuotes() throws {
        let env = try TempEnvironment(bundleNamePrefix: "Picky With 'Quotes' And Spaces")
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let status = ShellCommandInstaller.currentStatus(installPath: env.installPath, bundleURL: env.bundleURL)
        #expect(status == .installedCurrent(installPath: env.installPath))
    }

    // MARK: - installSilentlyIfPossible

    @Test func silentInstallWritesWrapperWhenSlotIsCleanAndWritable() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: env.bundleURL, installPath: env.installPath)
        #expect(outcome == .installed(installPath: env.installPath))
        #expect(FileManager.default.fileExists(atPath: env.installPath.path))
        let body = try String(contentsOf: env.installPath, encoding: .utf8)
        #expect(body.contains("PICKY_APP_PATH='\(env.bundleURL.path)'"))
    }

    @Test func silentInstallSkipsWhenCliMissingFromBundle() throws {
        let env = try TempEnvironment(includeCli: false)
        defer { env.cleanup() }
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: env.bundleURL, installPath: env.installPath)
        #expect(outcome == .skippedMissingCli)
        #expect(!FileManager.default.fileExists(atPath: env.installPath.path))
    }

    @Test func silentInstallSkipsWhenAlreadyInstalled() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: env.bundleURL, installPath: env.installPath)
        guard case .skippedAlreadyPresent(let status) = outcome else {
            Issue.record("expected skippedAlreadyPresent, got \(outcome)")
            return
        }
        #expect(status == .installedCurrent(installPath: env.installPath))
    }

    @Test func silentInstallLeavesStaleWrapperAlone() throws {
        // Stale wrappers (after Sparkle moves the bundle) are handled by the
        // panel banner, not silently overwritten on launch — we don't want to
        // resurrect a wrapper the user may have intentionally pointed at the
        // old build.
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())
        let alternate = env.makeAlternateBundle()
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: alternate, installPath: env.installPath)
        guard case .skippedAlreadyPresent(let status) = outcome else {
            Issue.record("expected skippedAlreadyPresent, got \(outcome)")
            return
        }
        if case .installedStale = status {
            // ok
        } else {
            Issue.record("expected installedStale inside skippedAlreadyPresent, got \(status)")
        }
        // Pinned path still references the original bundle.
        let body = try String(contentsOf: env.installPath, encoding: .utf8)
        #expect(body.contains("PICKY_APP_PATH='\(env.bundleURL.path)'"))
    }

    @Test func silentInstallLeavesForeignFileAlone() throws {
        let env = try TempEnvironment()
        defer { env.cleanup() }
        let foreignBody = "#!/bin/sh\necho not-picky\n"
        try foreignBody.write(to: env.installPath, atomically: true, encoding: .utf8)
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: env.bundleURL, installPath: env.installPath)
        guard case .skippedAlreadyPresent(let status) = outcome else {
            Issue.record("expected skippedAlreadyPresent, got \(outcome)")
            return
        }
        #expect(status == .foreign(installPath: env.installPath))
        // Confirm we did not overwrite the unrelated file.
        let body = try String(contentsOf: env.installPath, encoding: .utf8)
        #expect(body == foreignBody)
    }

    @Test func silentInstallSkipsWhenParentDirectoryIsNotWritable() throws {
        let env = try TempEnvironment()
        defer {
            // Restore writable perms before cleanup so the temp directory can
            // be removed without escalation.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: env.installPath.deletingLastPathComponent().path)
            env.cleanup()
        }
        let binDir = env.installPath.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: binDir.path)
        let outcome = ShellCommandInstaller.installSilentlyIfPossible(bundleURL: env.bundleURL, installPath: env.installPath)
        #expect(outcome == .skippedNeedsAdmin)
        #expect(!FileManager.default.fileExists(atPath: env.installPath.path))
    }

    @Test func wrapperResolvesCliPathWithoutEmbeddedQuotes() throws {
        // Regression: the previous template inlined the single-quoted Picky.app path
        // inside `${PICKY_AGENTD_ROOT_OVERRIDE:-'...'/Contents/...}`, but POSIX sh treats
        // single quotes as literal characters inside an already-double-quoted parameter
        // expansion. The expanded PICKY_RESOURCES then began with a literal `'`, which
        // node interpreted as a relative path and prefixed with cwd, surfacing as a
        // "Cannot find module" error at install time.
        let env = try TempEnvironment()
        defer { env.cleanup() }
        try ShellCommandInstaller.install(bundleURL: env.bundleURL, installPath: env.installPath, privilegedCommandRunner: RecordingRunner())

        // Resolve via the wrapper's own logic by running it through `sh` and printing the
        // computed cli.js path. PICKY_NODE_OVERRIDE intercepts the exec so we don't have
        // to install a fake node binary into PATH.
        let probeURL = env.root.appendingPathComponent("node-probe.sh")
        try "#!/bin/sh\nprintf '%s\\n' \"$1\"\nexit 0\n".write(to: probeURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: probeURL.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [env.installPath.path]
        process.environment = ["PICKY_NODE_OVERRIDE": probeURL.path]
        // Run the wrapper from a cwd different from the install path so a relative-path bug
        // (cwd prefix) would surface in the printed cli.js path.
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let printed = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let expected = env.bundleURL.appendingPathComponent("Contents/Resources/agentd/dist/cli.js").path
        #expect(process.terminationStatus == 0)
        #expect(printed == expected, "wrapper resolved cli.js to \(printed), expected \(expected)")
    }
}

@MainActor
private final class TempEnvironment {
    let root: URL
    let bundleURL: URL
    let installPath: URL

    init(includeCli: Bool = true, bundleNamePrefix: String = "Picky") throws {
        let id = UUID().uuidString
        root = FileManager.default.temporaryDirectory.appendingPathComponent("picky-shell-installer-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        bundleURL = root.appendingPathComponent("\(bundleNamePrefix).app", isDirectory: true)
        let cliDir = bundleURL.appendingPathComponent("Contents/Resources/agentd/dist", isDirectory: true)
        try FileManager.default.createDirectory(at: cliDir, withIntermediateDirectories: true)
        if includeCli {
            try "console.log('cli stub');".write(to: cliDir.appendingPathComponent("cli.js"), atomically: true, encoding: .utf8)
        }
        let binDir = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
        installPath = binDir.appendingPathComponent("picky")
    }

    func makeAlternateBundle() -> URL {
        // Same parent so the test still runs entirely under the temp root.
        let alternate = root.appendingPathComponent("Picky-Alternate.app", isDirectory: true)
        try? FileManager.default.createDirectory(at: alternate.appendingPathComponent("Contents/Resources/agentd/dist", isDirectory: true), withIntermediateDirectories: true)
        try? "console.log('alt');".write(to: alternate.appendingPathComponent("Contents/Resources/agentd/dist/cli.js"), atomically: true, encoding: .utf8)
        return alternate
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}

private final class RecordingRunner: PrivilegedCommandRunning {
    private(set) var invocations: [String] = []

    func run(_ shellCommand: String) throws {
        invocations.append(shellCommand)
    }
}
