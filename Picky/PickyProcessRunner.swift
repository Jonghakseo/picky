//
//  PickyProcessRunner.swift
//  Picky
//
//  Foundation-backed process runner used by the agentd launcher.
//

import Darwin
import Foundation

final class FoundationPickyProcessRunner: PickyProcessRunning {
    nonisolated private static let terminationGracePeriod: TimeInterval = 2.0
    nonisolated private static let terminationPollInterval: TimeInterval = 0.05

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    var terminationHandler: ((Int32) -> Void)?
    var processIdentifier: Int32? { process?.processIdentifier }

    func launch(configuration: PickyAgentDaemonConfiguration, stdout: @escaping (Data) -> Void, stderr: @escaping (Data) -> Void) throws {
        let process = Process()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.currentDirectoryURL = configuration.workingDirectory
        process.environment = configuration.environment

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in stdout(handle.availableData) }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in stderr(handle.availableData) }
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // Capture the handler at launch time so a stale process's termination
        // invokes the closure (and launch generation) that was current when it
        // started, not whatever handler a later launch installed.
        let handler = terminationHandler
        process.terminationHandler = { process in handler?(process.terminationStatus) }

        try process.run()
        self.process = process
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
    }

    func terminate() {
        guard let process = detachProcess(), process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).async {
            Self.escalateTermination(of: process)
        }
    }

    func terminateAndWaitForExit() {
        guard let process = detachProcess(), process.isRunning else { return }
        process.terminate()
        Self.escalateTermination(of: process)
    }

    private func detachProcess() -> Process? {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        let process = self.process
        self.process = nil
        stdoutPipe = nil
        stderrPipe = nil
        return process
    }

    /// Waits up to the grace period for a SIGTERM'd process, then SIGKILLs it.
    /// Blocks the calling thread, so the non-waiting path runs it off-main.
    nonisolated private static func escalateTermination(of process: Process) {
        let deadline = Date().addingTimeInterval(terminationGracePeriod)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: terminationPollInterval)
        }
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        process.waitUntilExit()
    }
}
