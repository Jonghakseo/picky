//
//  PickyLogger.swift
//  Picky
//
//  Single entry point for Picky-internal log messages so every category lands
//  in the unified logging system (OSLogStore) and the developer console alike.
//  Picky's diagnostics bundle uses `OSLogStore(scope: .currentProcessIdentifier)`
//  to collect `picky-oslog.txt`; before this helper existed every site used
//  `print` and the bundle's oslog file showed almost nothing Picky-specific.
//

import Foundation
import OSLog

enum PickyLog {
    /// Subsystem identifier shared by every Picky logger. Matches the app's
    /// bundle id so log filtering (`log show --predicate 'subsystem == ...'`)
    /// stays predictable.
    static let subsystem = "com.jonghakseo.picky"

    /// Categories used by the existing log-helper sites. Adding a new category
    /// is fine — the diagnostics collector grabs every category from the
    /// current process, so the bundle automatically picks them up.
    enum Category: String {
        case agentClient = "agent-client"
        case daemonLauncher = "daemon-launcher"
        case sessionUI = "session-ui"
        case speech = "speech"
    }

    /// Returns a fresh `Logger` for `category`. `Logger` is a thin wrapper
    /// around `os_log` handles and is cheap to construct, so we avoid a
    /// global cache (which would need synchronization across concurrent log
    /// sites) and instantiate per call.
    static func logger(_ category: Category) -> Logger {
        Logger(subsystem: subsystem, category: category.rawValue)
    }

    /// Emit a notice-level event for `category`. `notice` is the default level
    /// that OSLogStore persists across process restarts, so anything routed
    /// through this helper is recoverable from the diagnostics bundle.
    ///
    /// Also mirrors to stderr via `print` (preserving the existing
    /// emoji-prefixed developer console output) unless we are running inside a
    /// Swift Testing / XCTest process, where the noise would just clutter the
    /// test runner.
    static func notice(_ category: Category, prefix: String, message: String) {
        let composed = "\(prefix) \(message)"
        if !isRunningTests {
            print(composed)
        }
        logger(category).notice("\(message, privacy: .public)")
    }

    private static let isRunningTests: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}
