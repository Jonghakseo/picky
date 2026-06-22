//
//  PickyAgentDaemonStatus.swift
//  Picky
//
//  Daemon lifecycle + status snapshot value types extracted from
//  PickyAgentDaemonLauncher.swift to keep that file under the size limit.
//  Behavior is unchanged; these are pure value types persisted as
//  `agentd.status.json` for the diagnostics bundle.
//

import Foundation

enum PickyDaemonLifecycleState: Equatable {
    case stopped
    case starting
    case running
    case crashed(exitCode: Int32)
    case restarting(attempt: Int, delay: TimeInterval)
    case failedToStart(String)

    /// Short, log-stable label used for the status snapshot file. Avoids
    /// associated-value churn so a diagnostics reader can grep by name
    /// without parsing the payload.
    var diagnosticsLabel: String {
        switch self {
        case .stopped: return "stopped"
        case .starting: return "starting"
        case .running: return "running"
        case .crashed: return "crashed"
        case .restarting: return "restarting"
        case .failedToStart: return "failedToStart"
        }
    }
}

/// Snapshot of the daemon launcher's current state. The launcher rewrites a
/// JSON copy of this struct (`agentd.status.json`) on every state transition
/// so the diagnostics bundle can answer "was the daemon even running when the
/// user hit Send Feedback?" without needing a live launcher reference. The
/// file persists across Picky restarts the same way `agentd.stderr.log` does.
struct PickyDaemonStatusSnapshot: Codable, Equatable {
    /// Lifecycle label (matches `PickyDaemonLifecycleState.diagnosticsLabel`).
    var state: String
    /// Optional associated detail for non-trivial states (e.g. exitCode for
    /// `.crashed`, attempt/delay for `.restarting`, error message for
    /// `.failedToStart`). Free-form so the schema does not have to balloon.
    var detail: String?
    /// PID of the agentd child, when one is alive.
    var pid: Int32?
    /// Daemon role: `primary` for the app-wide daemon, `child(sessionId)`
    /// for per-Pickle daemons spawned by the pool.
    var role: String
    /// TCP port the launcher tried to bind. `0` for child daemons that use a
    /// random port.
    var port: Int
    /// Cumulative restart attempts observed by this launcher instance.
    var attempts: Int
    /// ISO-8601 timestamp of the most recent state change.
    var lastUpdatedAt: String
    /// ISO-8601 timestamp of the most recent successful `.running` entry.
    var lastRunningAt: String?
    /// Main-agent runtime mode requested for this launch (`pi`, `openai-realtime`, ...).
    var mainAgentRuntimeMode: String?
    /// Optional PICKY_AGENTD_RUNTIME override (`mock`, etc.). Nil for the default runtime.
    var agentdRuntimeOverride: String?
    /// How Node was resolved for compiled/bundled launches.
    var nodeSource: String?
    /// Executable path used for launch. Redacted before diagnostics upload.
    var executablePath: String?
    /// Agentd package root used as the process working directory. Redacted before diagnostics upload.
    var workingDirectory: String?
    /// Last classified startup/runtime failure observed in stderr or preflight.
    var lastFailureKind: String?
    /// TCP port associated with `lastFailureKind` when applicable.
    var lastFailurePort: Int?
    /// ISO-8601 timestamp of the last classified failure.
    var lastFailureAt: String?
}
