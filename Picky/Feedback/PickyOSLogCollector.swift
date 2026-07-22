//
//  PickyOSLogCollector.swift
//  Picky
//
//  Collects recent unified-log entries for Picky only. The system store is
//  tried first because it can retain a crashed process's prior entries; access
//  may be denied, in which case the current-process store remains best effort.
//

import Foundation
import OSLog

enum PickyOSLogCollector {
    static let defaultWindow: TimeInterval = 600
    static let maximumRenderedBytes = 256 * 1024

    enum Scope: String {
        case system
        case currentProcess
    }

    struct Entry: Equatable {
        let date: Date
        let level: String
        let subsystem: String
        let processID: Int32?
        let message: String
    }

    typealias EntryProvider = (Scope, Date) throws -> [Entry]

    /// Uses the system store on macOS 14.2+ (the app deployment target), then
    /// falls back if privacy permissions or the store itself reject the query.
    static func collectPreviousProcess(window: TimeInterval = defaultWindow, now: Date = Date()) -> String {
        collect(window: window, now: now, entryProvider: loadEntries)
    }

    /// Injectable collection policy for deterministic tests; the provider is
    /// the only boundary that reads the machine's unified logging store.
    static func collect(window: TimeInterval, now: Date, entryProvider: EntryProvider) -> String {
        let start = now.addingTimeInterval(-window)
        do {
            return render(
                entries: entriesInRequestedWindow(try entryProvider(.system, start), start: start, end: now),
                scope: .system,
                window: window,
                fallbackReason: nil
            )
        } catch {
            let reason = PickyDiagnosticTextRedactor.redact(error.localizedDescription)
            do {
                return render(
                    entries: entriesInRequestedWindow(try entryProvider(.currentProcess, start), start: start, end: now),
                    scope: .currentProcess,
                    window: window,
                    fallbackReason: "system unavailable: \(reason)"
                )
            } catch {
                return render(
                    entries: [],
                    scope: .currentProcess,
                    window: window,
                    fallbackReason: "system unavailable; current-process unavailable: \(PickyDiagnosticTextRedactor.redact(error.localizedDescription))"
                )
            }
        }
    }

    /// Renders entries with a fixed byte cap, retaining newest Picky lines if
    /// the body must be truncated. Rendering is public to the module for unit
    /// tests and does not query OSLog.
    static func render(
        entries: [Entry],
        scope: Scope,
        window: TimeInterval,
        fallbackReason: String? = nil,
        maxBytes: Int = maximumRenderedBytes
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let lines = entries
            .filter { $0.subsystem == PickyLog.subsystem }
            .sorted { $0.date < $1.date }
            .map { entry -> String in
                let pid = entry.processID.map { " pid=\($0)" } ?? ""
                let message = PickyDiagnosticTextRedactor.redact(entry.message)
                return "\(formatter.string(from: entry.date)) \(entry.level) [\(entry.subsystem)]\(pid) \(message)"
            }
        let body = lines.isEmpty ? "(no Picky OSLog entries in the requested window)" : lines.joined(separator: "\n")
        let baseHeader = [
            "# Picky OSLog diagnostics",
            "scope=\(scope.rawValue)",
            "subsystem=\(PickyLog.subsystem)",
            "windowSeconds=\(Int(window))"
        ]
        let fallbackLine = fallbackReason.map { "fallback=\(PickyDiagnosticTextRedactor.redact($0))" }
        let untruncatedHeader = (baseHeader + (fallbackLine.map { [$0] } ?? []) + ["truncated=false"]).joined(separator: "\n") + "\n"
        let truncatedHeader = (baseHeader + (fallbackLine.map { [$0] } ?? []) + ["truncated=true"]).joined(separator: "\n") + "\n"
        let bodyLimit = max(0, maxBytes - untruncatedHeader.lengthOfBytes(using: .utf8))
        let initiallyBoundedBody = PickyDiagnosticTextRedactor.truncateUTF8(body, maxBytes: bodyLimit, keepingNewest: true)
        let wasTruncated = initiallyBoundedBody.lengthOfBytes(using: .utf8) < body.lengthOfBytes(using: .utf8)
        let header = wasTruncated ? truncatedHeader : untruncatedHeader
        let finalBodyLimit = max(0, maxBytes - header.lengthOfBytes(using: .utf8))
        let finalBody = PickyDiagnosticTextRedactor.truncateUTF8(body, maxBytes: finalBodyLimit, keepingNewest: true)
        return PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(header + finalBody),
            maxBytes: maxBytes,
            keepingNewest: false
        )
    }

    private static func entriesInRequestedWindow(_ entries: [Entry], start: Date, end: Date) -> [Entry] {
        entries.filter { $0.date >= start && $0.date <= end }
    }

    private static func loadEntries(scope: Scope, start: Date) throws -> [Entry] {
        let storeScope: OSLogStore.Scope = scope == .system ? .system : .currentProcessIdentifier
        let store = try OSLogStore(scope: storeScope)
        let entries = try store.getEntries(at: store.position(date: start))
        return entries.compactMap { entry -> Entry? in
            guard let logEntry = entry as? OSLogEntryLog,
                  logEntry.subsystem == PickyLog.subsystem else { return nil }
            return Entry(
                date: logEntry.date,
                level: describe(level: logEntry.level),
                subsystem: logEntry.subsystem,
                processID: logEntry.processIdentifier,
                message: logEntry.composedMessage
            )
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
