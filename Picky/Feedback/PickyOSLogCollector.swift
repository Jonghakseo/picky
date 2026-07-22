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
    /// This caps both the OSLog iteration working set and the number of lines
    /// considered by rendering. OSLogStore returns entries in chronological
    /// order, so retaining this suffix preserves the newest evidence.
    static let maximumCollectedEntries = 2_000

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
    static func collectPreviousProcess(
        preferredProcessID: Int32? = nil,
        window: TimeInterval = defaultWindow,
        now: Date = Date()
    ) -> String {
        collect(window: window, now: now, preferredProcessID: preferredProcessID, entryProvider: loadEntries)
    }

    /// Injectable collection policy for deterministic tests; the provider is
    /// the only boundary that reads the machine's unified logging store.
    static func collect(
        window: TimeInterval,
        now: Date,
        preferredProcessID: Int32? = nil,
        entryProvider: EntryProvider
    ) -> String {
        let start = now.addingTimeInterval(-window)
        do {
            return render(
                entries: entriesInRequestedWindow(
                    try entryProvider(.system, start),
                    start: start,
                    end: now,
                    preferredProcessID: preferredProcessID
                ),
                scope: .system,
                window: window,
                preferredProcessID: preferredProcessID,
                fallbackReason: nil
            )
        } catch {
            let reason = PickyDiagnosticTextRedactor.redact(error.localizedDescription)
            do {
                return render(
                    entries: entriesInRequestedWindow(
                        try entryProvider(.currentProcess, start),
                        start: start,
                        end: now,
                        preferredProcessID: nil
                    ),
                    scope: .currentProcess,
                    window: window,
                    preferredProcessID: nil,
                    fallbackReason: "system unavailable: \(reason)"
                )
            } catch {
                return render(
                    entries: [],
                    scope: .currentProcess,
                    window: window,
                    preferredProcessID: nil,
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
        preferredProcessID: Int32? = nil,
        fallbackReason: String? = nil,
        maxBytes: Int = maximumRenderedBytes
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let filtered = entries.filter { entry in
            entry.subsystem == PickyLog.subsystem
                && (preferredProcessID == nil || entry.processID == preferredProcessID)
        }
        let boundedEntries = boundedNewestEntries(from: filtered, maximumCount: maximumCollectedEntries)
        let entryLimitTruncated = filtered.count > boundedEntries.count
        let baseHeader = [
            "# Picky OSLog diagnostics",
            "scope=\(scope.rawValue)",
            "subsystem=\(PickyLog.subsystem)",
            "processFilter=\(preferredProcessID.map { "pid=\($0)" } ?? "subsystem-only")",
            "entryLimit=\(maximumCollectedEntries)",
            "windowSeconds=\(Int(window))"
        ]
        let fallbackLine = fallbackReason.map {
            "fallback=\(PickyDiagnosticTextRedactor.truncateUTF8(PickyDiagnosticTextRedactor.redact($0), maxBytes: 1_024, keepingNewest: false))"
        }
        let headerWithoutTruncation = (baseHeader + (fallbackLine.map { [$0] } ?? [])).joined(separator: "\n")
        let headerBytes = headerWithoutTruncation.lengthOfBytes(using: .utf8) + "\ntruncated=true\n".lengthOfBytes(using: .utf8)
        let bodyLimit = max(0, maxBytes - headerBytes)
        let body = renderBoundedBody(
            entries: boundedEntries,
            formatter: formatter,
            maxBytes: bodyLimit,
            initiallyTruncated: entryLimitTruncated
        )
        let header = headerWithoutTruncation + "\ntruncated=\(body.truncated)\n"
        return PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(header + body.text),
            maxBytes: maxBytes,
            keepingNewest: false
        )
    }

    /// Shared by the OSLog reader and deterministic tests. Its input is the
    /// chronological OSLog sequence, and its fixed-size suffix is the only
    /// retained working set.
    static func boundedNewestEntries(from entries: [Entry], maximumCount: Int = maximumCollectedEntries) -> [Entry] {
        guard maximumCount > 0 else { return [] }
        var newest: [Entry] = []
        newest.reserveCapacity(min(maximumCount, entries.count))
        for entry in entries {
            if newest.count == maximumCount {
                newest.removeFirst()
            }
            newest.append(entry)
        }
        return newest
    }

    private static func renderBoundedBody(
        entries: [Entry],
        formatter: ISO8601DateFormatter,
        maxBytes: Int,
        initiallyTruncated: Bool
    ) -> (text: String, truncated: Bool) {
        guard !entries.isEmpty else {
            let placeholder = "(no Picky OSLog entries in the requested window)"
            return (PickyDiagnosticTextRedactor.truncateUTF8(placeholder, maxBytes: maxBytes, keepingNewest: false), initiallyTruncated)
        }

        var newestFirstLines: [String] = []
        var usedBytes = 0
        var truncated = initiallyTruncated
        for entry in entries.reversed() {
            let pid = entry.processID.map { " pid=\($0)" } ?? ""
            let line = "\(formatter.string(from: entry.date)) \(entry.level) [\(entry.subsystem)]\(pid) \(PickyDiagnosticTextRedactor.redact(entry.message))"
            let separatorBytes = newestFirstLines.isEmpty ? 0 : 1
            let available = maxBytes - usedBytes - separatorBytes
            let lineBytes = line.lengthOfBytes(using: .utf8)
            guard available > 0 else {
                truncated = true
                break
            }
            if lineBytes > available {
                newestFirstLines.append(PickyDiagnosticTextRedactor.truncateUTF8(line, maxBytes: available, keepingNewest: false))
                truncated = true
                break
            }
            newestFirstLines.append(line)
            usedBytes += separatorBytes + lineBytes
        }
        return (newestFirstLines.reversed().joined(separator: "\n"), truncated)
    }

    private static func entriesInRequestedWindow(
        _ entries: [Entry],
        start: Date,
        end: Date,
        preferredProcessID: Int32?
    ) -> [Entry] {
        boundedNewestEntries(from: entries.filter {
            $0.date >= start
                && $0.date <= end
                && $0.subsystem == PickyLog.subsystem
                && (preferredProcessID == nil || $0.processID == preferredProcessID)
        })
    }

    private static func loadEntries(scope: Scope, start: Date) throws -> [Entry] {
        let storeScope: OSLogStore.Scope = scope == .system ? .system : .currentProcessIdentifier
        let store = try OSLogStore(scope: storeScope)
        let predicate = NSPredicate(format: "subsystem == %@", PickyLog.subsystem)
        let rawEntries = try store.getEntries(at: store.position(date: start), matching: predicate)
        var entries: [Entry] = []
        entries.reserveCapacity(maximumCollectedEntries)
        for rawEntry in rawEntries {
            guard let logEntry = rawEntry as? OSLogEntryLog else { continue }
            if entries.count == maximumCollectedEntries {
                entries.removeFirst()
            }
            entries.append(Entry(
                date: logEntry.date,
                level: describe(level: logEntry.level),
                subsystem: logEntry.subsystem,
                processID: logEntry.processIdentifier,
                message: logEntry.composedMessage
            ))
        }
        return entries
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
