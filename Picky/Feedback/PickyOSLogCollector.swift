//
//  PickyOSLogCollector.swift
//  Picky
//
//  Pulls the current process's unified-logging entries from the last N
//  minutes for the diagnostics bundle. Picky's existing code uses a mix of
//  `print` / `NSLog` (which never reach OSLogStore) and the occasional
//  `os_log`, so this collector may return very little until logging is
//  migrated. We still attach the file so the structure is in place and the
//  recipient can spot when entries do show up.
//

import Foundation
import OSLog

enum PickyOSLogCollector {
    /// Default window matches the user-facing "last 10 minutes" framing.
    static let defaultWindow: TimeInterval = 600

    /// Collects log entries from the current process emitted within `window`.
    /// Returns a single string ready to write as `picky-oslog.txt`. Always
    /// returns text (never throws) — failures produce a `(reason)` placeholder
    /// so the diagnostics bundle stays consistent.
    static func collectCurrentProcess(window: TimeInterval = defaultWindow) -> String {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            let start = Date().addingTimeInterval(-window)
            let position = store.position(date: start)
            let entries = try store.getEntries(at: position)

            var lines: [String] = []
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            for entry in entries {
                guard let logEntry = entry as? OSLogEntryLog else { continue }
                let timestamp = formatter.string(from: logEntry.date)
                let level = describe(level: logEntry.level)
                let subsystem = logEntry.subsystem.isEmpty ? "-" : logEntry.subsystem
                let redactedMessage = PickyDiagnosticTextRedactor.redact(logEntry.composedMessage)
                lines.append("\(timestamp) \(level) [\(subsystem)] \(redactedMessage)")
            }

            if lines.isEmpty {
                return "(no OSLog entries from this process in the last \(Int(window))s)"
            }
            return lines.joined(separator: "\n")
        } catch {
            return "(OSLog unavailable: \(error.localizedDescription))"
        }
    }

    private static func describe(level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "U"
        case .debug: return "D"
        case .info: return "I"
        case .notice: return "N"
        case .error: return "E"
        case .fault: return "F"
        @unknown default: return "?"
        }
    }
}
