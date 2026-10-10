//
//  PickyDaemonTerminalFailure.swift
//  Picky
//
//  Final, structured failure a launcher publishes once it has stopped trying to
//  keep picky-agentd alive. `PickyAgentDaemonLauncher.state` carries the
//  human-readable message as `.failedToStart`; this value adds the cause so a
//  UI can pick the right recovery without parsing that message.
//

import Foundation

enum PickyDaemonFailureCause: String, Equatable {
    /// Node (bundled, `PICKY_NODE_PATH`, or on PATH) is missing or not executable.
    case nodeMissing
    /// Node is older than picky-agentd supports.
    case nodeUnsupported
    /// The daemon's port was taken on every attempt.
    case portInUse
    /// The daemon kept exiting shortly after start until the restart limit was reached.
    case repeatedCrash
    /// The agentd package or its entry point is not where the launcher expects it.
    case agentdMissing
    /// The process could not be launched for another reason.
    case launchFailed
}

struct PickyDaemonTerminalFailure: Equatable {
    var cause: PickyDaemonFailureCause
    var message: String
    /// Set when `cause == .portInUse`.
    var port: Int?
    /// Exit code of the last crashed run, when a process actually ran.
    var lastExitCode: Int32?
    /// Restarts attempted before giving up. `0` for failures found before any restart.
    var restartAttempts: Int = 0

    /// Classifies a crash loop from what the last run reported (`lastFailureKind` is the
    /// launcher's diagnostics kind, for example `portConflict`).
    static func restartLimitReached(
        attempts: Int,
        lastExitCode: Int32?,
        lastFailureKind: String?,
        lastFailurePort: Int?
    ) -> PickyDaemonTerminalFailure {
        if lastFailureKind == "portConflict", let port = lastFailurePort {
            return PickyDaemonTerminalFailure(
                cause: .portInUse,
                message: "Port \(port) is already in use, so picky-agentd could not start after \(attempts) restart attempts. Quit the app that is using it and relaunch Picky.",
                port: port,
                lastExitCode: lastExitCode,
                restartAttempts: attempts
            )
        }
        if lastFailureKind == "launchError" {
            return PickyDaemonTerminalFailure(
                cause: .launchFailed,
                message: "picky-agentd could not be launched after \(attempts) restart attempts. See the Picky agentd launcher log for the error.",
                restartAttempts: attempts
            )
        }
        let exitDetail = lastExitCode.map { " (last exit code \($0))" } ?? ""
        return PickyDaemonTerminalFailure(
            cause: .repeatedCrash,
            message: "picky-agentd kept exiting right after it started and was not restarted again after \(attempts) attempts\(exitDetail). See agentd.stderr.log for the cause.",
            lastExitCode: lastExitCode,
            restartAttempts: attempts
        )
    }
}

extension PickyDaemonLaunchPreflightError {
    var failureCause: PickyDaemonFailureCause {
        switch self {
        case .missingAgentdPackage, .missingAgentdEntryPoint:
            return .agentdMissing
        case .missingExecutableAtPath:
            return .nodeMissing
        case .missingRequiredExecutable(let name):
            return name == "node" ? .nodeMissing : .launchFailed
        }
    }
}
