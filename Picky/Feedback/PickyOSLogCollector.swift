//
//  PickyOSLogCollector.swift
//  Picky
//
//  Collects recent unified-log entries for Picky only. The system store is
//  tried first because it can retain a crashed process's prior entries; access
//  may be denied, in which case the current-process store remains best effort.
//
//  Iteration is bounded at the source. `OSLogStore` can hold far more Picky
//  entries than a feedback report needs, so the reader walks newest-first when
//  the store supports it and stops at the first limit it hits (window start,
//  entry count, byte budget, or wall-clock deadline). A full traversal that
//  keeps only a trailing suffix is the fallback, not the default.
//

import Foundation
import OSLog

enum PickyOSLogCollector {
    static let defaultWindow: TimeInterval = 600
    static let maximumRenderedBytes = 256 * 1024
    /// Caps both the OSLog iteration working set and the number of lines
    /// considered by rendering.
    static let maximumCollectedEntries = 2_000
    /// Wall-clock budget for one collection. Opening `OSLogStore` and walking
    /// its entries are synchronous calls that cannot be cancelled, so the
    /// budget bounds how long a feedback send waits for them; the bundle is
    /// built without OSLog evidence when the budget expires.
    static let defaultBudget: TimeInterval = 8
    /// Share of the budget the worker may spend reading. The rest is left for
    /// filtering, rendering, and handing the text back.
    static let workingDeadlineFraction: Double = 0.8

    enum Scope: String {
        case system
        case currentProcess
    }

    /// Direction in which a store hands back entries. `.reverse` enumeration is
    /// honored by the system store but ignored by the current-process store on
    /// macOS 26, so the reader detects the real order instead of assuming it.
    enum Order: String, Equatable, Sendable {
        case newestFirst
        case chronological
    }

    struct Entry: Equatable {
        let date: Date
        let level: String
        let subsystem: String
        let processID: Int32?
        let message: String
    }

    /// A lazily consumed entry sequence plus the order it yields. Keeping the
    /// sequence lazy is what makes the caps bound real iteration.
    struct EntryStream {
        let order: Order
        let entries: AnySequence<Entry>

        init(order: Order, entries: AnySequence<Entry>) {
            self.order = order
            self.entries = entries
        }

        init(order: Order, entries: [Entry]) {
            self.init(order: order, entries: AnySequence(entries))
        }
    }

    /// Outcome of a bounded walk. `entries` is always chronological so the
    /// rendered body reads top-to-bottom like a log file.
    struct BoundedEntries: Equatable {
        var entries: [Entry] = []
        var examinedCount = 0
        var limitedByCount = false
        var limitedByBytes = false
        var deadlineExceeded = false
        var order: Order = .chronological

        var isTruncated: Bool { limitedByCount || limitedByBytes || deadlineExceeded }
    }

    /// Why no OSLog evidence is present, when that is the case.
    enum Omission: Equatable {
        case deadlineExceeded(TimeInterval)
        case alreadyCollecting

        var reason: String {
            switch self {
            case .deadlineExceeded(let budget):
                return "collection exceeded its \(Int(budget))s budget; feedback was sent without OSLog evidence"
            case .alreadyCollecting:
                return "a previous collection is still running; feedback was sent without OSLog evidence"
            }
        }
    }

    typealias EntryProvider = (Scope, Date) throws -> [Entry]
    typealias EntryStreamProvider = (Scope, Date, Date) throws -> EntryStream

    // MARK: - Entry points

    /// Uses the system store on macOS 14.2+ (the app deployment target), then
    /// falls back if privacy permissions or the store itself reject the query.
    /// Returns a placeholder instead of blocking indefinitely when the store
    /// does not answer within `budget`.
    static func collectRecentProcesses(
        retainedProcessIDs: Set<Int32> = [],
        window: TimeInterval = defaultWindow,
        now: Date = Date(),
        budget: TimeInterval = defaultBudget
    ) -> String {
        guard beginExclusiveCollection() else {
            return renderOmission(.alreadyCollecting, window: window, retainedProcessIDs: retainedProcessIDs)
        }

        // Measured from when collection starts, not from `now`: a queued
        // feedback job anchors its log window at the moment the user pressed
        // Send, which can be well in the past by the time it is delivered.
        //
        // The worker stops iterating before the caller gives up, so what it
        // already collected still gets rendered and returned. Without that
        // headroom the two deadlines coincide and every slow read is thrown
        // away as an omission.
        let deadline = Date().addingTimeInterval(budget * workingDeadlineFraction)
        let box = CollectedTextBox()
        // Escape hatch per docs/swift-concurrency.md: `OSLogStore` opening and
        // enumeration are synchronous C calls with no cancellation. A
        // semaphore with a timeout is what lets the caller walk away from a
        // hung store; `Task` cancellation would not stop the blocked thread.
        let finished = DispatchSemaphore(value: 0)
        collectionQueue.async {
            let text = collect(
                window: window,
                now: now,
                retainedProcessIDs: retainedProcessIDs,
                deadline: deadline,
                streamProvider: { scope, start, end in
                    try liveEntryStream(
                        scope: scope,
                        start: start,
                        end: end,
                        retainedProcessIDs: retainedProcessIDs
                    )
                }
            )
            box.store(text)
            endExclusiveCollection()
            finished.signal()
        }

        if finished.wait(timeout: .now() + budget) == .timedOut {
            // The worker keeps running on the single shared queue; the
            // exclusivity flag blocks another one from piling up behind it.
            return renderOmission(.deadlineExceeded(budget), window: window, retainedProcessIDs: retainedProcessIDs)
        }
        return box.take() ?? renderOmission(
            .deadlineExceeded(budget),
            window: window,
            retainedProcessIDs: retainedProcessIDs
        )
    }

    /// Injectable collection policy for deterministic tests; the provider is
    /// the only boundary that reads the machine's unified logging store.
    /// An empty `retainedProcessIDs` keeps every Picky-subsystem process.
    static func collect(
        window: TimeInterval,
        now: Date,
        retainedProcessIDs: Set<Int32> = [],
        entryProvider: @escaping EntryProvider
    ) -> String {
        collect(
            window: window,
            now: now,
            retainedProcessIDs: retainedProcessIDs,
            deadline: nil,
            streamProvider: { scope, start, _ in
                EntryStream(order: .chronological, entries: try entryProvider(scope, start))
            }
        )
    }

    static func collect(
        window: TimeInterval,
        now: Date,
        retainedProcessIDs: Set<Int32> = [],
        deadline: Date?,
        streamProvider: EntryStreamProvider
    ) -> String {
        let start = now.addingTimeInterval(-window)
        let isExpired: () -> Bool = {
            guard let deadline else { return false }
            return Date() >= deadline
        }

        do {
            let bounded = bound(
                try streamProvider(.system, start, now),
                start: start,
                end: now,
                retainedProcessIDs: retainedProcessIDs,
                isExpired: isExpired
            )
            return render(
                bounded: bounded,
                scope: .system,
                window: window,
                retainedProcessIDs: retainedProcessIDs,
                fallbackReason: nil
            )
        } catch {
            let reason = PickyDiagnosticTextRedactor.redact(error.localizedDescription)
            do {
                let bounded = bound(
                    try streamProvider(.currentProcess, start, now),
                    start: start,
                    end: now,
                    retainedProcessIDs: [],
                    isExpired: isExpired
                )
                return render(
                    bounded: bounded,
                    scope: .currentProcess,
                    window: window,
                    retainedProcessIDs: [],
                    fallbackReason: "system unavailable: \(reason)"
                )
            } catch {
                return render(
                    bounded: BoundedEntries(),
                    scope: .currentProcess,
                    window: window,
                    retainedProcessIDs: [],
                    fallbackReason: "system unavailable; current-process unavailable: \(PickyDiagnosticTextRedactor.redact(error.localizedDescription))"
                )
            }
        }
    }

    // MARK: - Bounded walk

    /// Walks `stream` and stops at the first limit it reaches. Newest-first
    /// input never discards recent evidence: the walk ends at the window start
    /// or a cap, and nothing older is read at all. Chronological input has to
    /// be traversed, so a trailing ring buffer keeps the newest entries.
    static func bound(
        _ stream: EntryStream,
        start: Date,
        end: Date,
        retainedProcessIDs: Set<Int32>,
        maximumCount: Int = maximumCollectedEntries,
        maximumBytes: Int = maximumRenderedBytes,
        isExpired: () -> Bool = { false }
    ) -> BoundedEntries {
        var result = BoundedEntries()
        result.order = stream.order
        guard maximumCount > 0 else { return result }

        switch stream.order {
        case .newestFirst:
            var newestFirst: [Entry] = []
            var usedBytes = 0
            for entry in stream.entries {
                if isExpired() {
                    result.deadlineExceeded = true
                    break
                }
                result.examinedCount += 1
                if entry.date > end { continue }
                if entry.date < start { break }
                guard keeps(entry, retainedProcessIDs: retainedProcessIDs) else { continue }

                newestFirst.append(entry)
                usedBytes += estimatedBytes(of: entry)
                if newestFirst.count >= maximumCount {
                    result.limitedByCount = true
                    break
                }
                if usedBytes >= maximumBytes {
                    result.limitedByBytes = true
                    break
                }
            }
            result.entries = newestFirst.reversed()

        case .chronological:
            var window: [Entry] = []
            var usedBytes = 0
            for entry in stream.entries {
                if isExpired() {
                    result.deadlineExceeded = true
                    break
                }
                result.examinedCount += 1
                if entry.date > end { break }
                if entry.date < start { continue }
                guard keeps(entry, retainedProcessIDs: retainedProcessIDs) else { continue }

                window.append(entry)
                usedBytes += estimatedBytes(of: entry)
                while window.count > maximumCount {
                    usedBytes -= estimatedBytes(of: window.removeFirst())
                    result.limitedByCount = true
                }
                while usedBytes > maximumBytes, window.count > 1 {
                    usedBytes -= estimatedBytes(of: window.removeFirst())
                    result.limitedByBytes = true
                }
            }
            result.entries = window
        }

        return result
    }

    // MARK: - Rendering

    /// Renders entries with a fixed byte cap, retaining newest Picky lines if
    /// the body must be truncated. Rendering is public to the module for unit
    /// tests and does not query OSLog.
    static func render(
        entries: [Entry],
        scope: Scope,
        window: TimeInterval,
        retainedProcessIDs: Set<Int32> = [],
        fallbackReason: String? = nil,
        maxBytes: Int = maximumRenderedBytes
    ) -> String {
        let filtered = entries.filter { entry in
            entry.subsystem == PickyLog.subsystem && keeps(entry, retainedProcessIDs: retainedProcessIDs)
        }
        let kept = boundedNewestEntries(from: filtered, maximumCount: maximumCollectedEntries)
        var bounded = BoundedEntries()
        bounded.entries = kept
        bounded.examinedCount = entries.count
        bounded.limitedByCount = filtered.count > kept.count
        return render(
            bounded: bounded,
            scope: scope,
            window: window,
            retainedProcessIDs: retainedProcessIDs,
            fallbackReason: fallbackReason,
            maxBytes: maxBytes
        )
    }

    static func render(
        bounded: BoundedEntries,
        scope: Scope,
        window: TimeInterval,
        retainedProcessIDs: Set<Int32> = [],
        fallbackReason: String? = nil,
        maxBytes: Int = maximumRenderedBytes
    ) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let entries = bounded.entries.filter { entry in
            entry.subsystem == PickyLog.subsystem && keeps(entry, retainedProcessIDs: retainedProcessIDs)
        }
        let baseHeader = [
            "# Picky OSLog diagnostics",
            "scope=\(scope.rawValue)",
            "subsystem=\(PickyLog.subsystem)",
            "processFilter=\(describeProcessFilter(retainedProcessIDs))",
            "iterationOrder=\(bounded.order.rawValue)",
            "entryLimit=\(maximumCollectedEntries)",
            "windowSeconds=\(Int(window))",
            "examinedEntries=\(bounded.examinedCount)",
            "keptEntries=\(entries.count)",
            "entryLimitReached=\(bounded.limitedByCount)",
            "byteLimitReached=\(bounded.limitedByBytes)",
            "deadlineExceeded=\(bounded.deadlineExceeded)"
        ]
        let fallbackLine = fallbackReason.map {
            "fallback=\(PickyDiagnosticTextRedactor.truncateUTF8(PickyDiagnosticTextRedactor.redact($0), maxBytes: 1_024, keepingNewest: false))"
        }
        let headerWithoutTruncation = (baseHeader + (fallbackLine.map { [$0] } ?? [])).joined(separator: "\n")
        let headerBytes = headerWithoutTruncation.lengthOfBytes(using: .utf8) + "\ntruncated=true\n".lengthOfBytes(using: .utf8)
        let bodyLimit = max(0, maxBytes - headerBytes)
        let body = renderBoundedBody(
            entries: entries,
            formatter: formatter,
            maxBytes: bodyLimit,
            initiallyTruncated: bounded.isTruncated
        )
        let header = headerWithoutTruncation + "\ntruncated=\(body.truncated)\n"
        return PickyDiagnosticTextRedactor.truncateUTF8(
            PickyDiagnosticTextRedactor.redact(header + body.text),
            maxBytes: maxBytes,
            keepingNewest: false
        )
    }

    /// Fixed-size trailing window over a chronological sequence. Retained for
    /// the rendering path and for chronological fallbacks.
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

    /// Classifies a rendered collection for the feedback stage breadcrumb.
    /// The header already states whether evidence was omitted and why, so the
    /// log line can report it without carrying any collected content.
    static func collectionOutcome(for rendered: String) -> PickyFeedbackStageLog.Outcome {
        let header = rendered.prefix(1_024)
        guard header.contains("omitted=true") else { return .succeeded }
        if header.contains("budget") { return .skipped("deadline") }
        return .skipped("omitted")
    }

    static func renderOmission(
        _ omission: Omission,
        window: TimeInterval,
        retainedProcessIDs: Set<Int32>
    ) -> String {
        [
            "# Picky OSLog diagnostics",
            "scope=none",
            "subsystem=\(PickyLog.subsystem)",
            "processFilter=\(describeProcessFilter(retainedProcessIDs))",
            "windowSeconds=\(Int(window))",
            "omitted=true",
            "omittedReason=\(omission.reason)",
            "",
            "(no OSLog entries were collected)"
        ].joined(separator: "\n")
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

    private static func keeps(_ entry: Entry, retainedProcessIDs: Set<Int32>) -> Bool {
        guard entry.subsystem == PickyLog.subsystem else { return false }
        guard !retainedProcessIDs.isEmpty else { return true }
        guard let processID = entry.processID else { return false }
        return retainedProcessIDs.contains(processID)
    }

    private static func estimatedBytes(of entry: Entry) -> Int {
        entry.message.lengthOfBytes(using: .utf8) + 96
    }

    private static func describeProcessFilter(_ retainedProcessIDs: Set<Int32>) -> String {
        guard !retainedProcessIDs.isEmpty else { return "subsystem-only" }
        return "pid=" + retainedProcessIDs.sorted().map(String.init).joined(separator: ",")
    }

    // MARK: - Live OSLogStore reader

    /// Single serial queue for every OSLog read. A read that blows its budget
    /// is abandoned by the caller but keeps this queue busy, and
    /// `beginExclusiveCollection` refuses a second read until it finishes, so
    /// a hung store can never accumulate workers.
    private static let collectionQueue = DispatchQueue(
        label: "com.jonghakseo.picky.oslog-collector",
        qos: .utility
    )
    nonisolated(unsafe) private static var isCollecting = false
    private static let collectingLock = NSLock()

    private static func beginExclusiveCollection() -> Bool {
        collectingLock.lock()
        defer { collectingLock.unlock() }
        if isCollecting { return false }
        isCollecting = true
        return true
    }

    private static func endExclusiveCollection() {
        collectingLock.lock()
        isCollecting = false
        collectingLock.unlock()
    }

    private final class CollectedTextBox: @unchecked Sendable {
        private let lock = NSLock()
        private var text: String?

        func store(_ value: String) {
            lock.lock()
            text = value
            lock.unlock()
        }

        func take() -> String? {
            lock.lock()
            defer { lock.unlock() }
            return text
        }
    }

    private static func liveEntryStream(
        scope: Scope,
        start: Date,
        end: Date,
        retainedProcessIDs: Set<Int32> = []
    ) throws -> EntryStream {
        let storeScope: OSLogStore.Scope = scope == .system ? .system : .currentProcessIdentifier
        let store = try OSLogStore(scope: storeScope)
        let subsystemOnly = NSPredicate(format: "subsystem == %@", PickyLog.subsystem)
        let predicate = processNarrowedPredicate(
            store: store,
            subsystemOnly: subsystemOnly,
            retainedProcessIDs: retainedProcessIDs,
            end: end
        )

        if yieldsNewestFirst(store: store, predicate: predicate, end: end),
           let reverse = try? store.getEntries(
               with: [.reverse],
               at: store.position(date: end),
               matching: predicate
           ) {
            return EntryStream(order: .newestFirst, entries: mapped(reverse))
        }

        let forward = try store.getEntries(at: store.position(date: start), matching: predicate)
        return EntryStream(order: .chronological, entries: mapped(forward))
    }

    /// Narrows the query to the processes the bundle keeps, so the store walks
    /// fewer entries instead of handing everything over to be filtered in
    /// memory. `keeps(_:retainedProcessIDs:)` still runs afterwards, so output
    /// is identical either way.
    ///
    /// Measured on macOS 26.5 (2026-10, standalone `OSLogStore` probe): a
    /// `processIdentifier` term is honored. The same query with a PID that
    /// emitted nothing returns 0 entries, while the subsystem-only query
    /// returns all of them. The app's deployment target reaches back to 14.2,
    /// which was not probed, so this verifies the narrowed query actually
    /// returns something before committing to it and otherwise falls back to
    /// the subsystem-only predicate.
    private static func processNarrowedPredicate(
        store: OSLogStore,
        subsystemOnly: NSPredicate,
        retainedProcessIDs: Set<Int32>,
        end: Date
    ) -> NSPredicate {
        guard !retainedProcessIDs.isEmpty else { return subsystemOnly }
        let narrowed = NSPredicate(
            format: "subsystem == %@ AND processIdentifier IN %@",
            PickyLog.subsystem,
            retainedProcessIDs.sorted().map(NSNumber.init(value:))
        )
        return yieldsAnyEntry(store: store, predicate: narrowed, end: end) ? narrowed : subsystemOnly
    }

    /// Single-entry probe on its own enumerator: the store hands back
    /// single-pass sequences, so the real query must start from a fresh one.
    private static func yieldsAnyEntry(store: OSLogStore, predicate: NSPredicate, end: Date) -> Bool {
        guard let sequence = try? store.getEntries(
            with: [.reverse],
            at: store.position(date: end),
            matching: predicate
        ) else { return false }
        for raw in sequence where raw is OSLogEntryLog {
            return true
        }
        return false
    }

    /// `.reverse` is honored by the system store but silently ignored by the
    /// current-process store, and a nil position makes the system store return
    /// nothing at all. Probing two entries is cheaper than trusting the flag.
    /// The probe uses its own enumerator because the store hands back a
    /// single-pass sequence: reusing it would drop the two newest entries.
    private static func yieldsNewestFirst(store: OSLogStore, predicate: NSPredicate, end: Date) -> Bool {
        guard let sequence = try? store.getEntries(
            with: [.reverse],
            at: store.position(date: end),
            matching: predicate
        ) else { return false }
        var dates: [Date] = []
        for raw in sequence {
            guard let log = raw as? OSLogEntryLog else { continue }
            dates.append(log.date)
            if dates.count == 2 { break }
        }
        guard dates.count == 2 else { return false }
        return dates[0] >= dates[1]
    }

    private static func mapped(_ sequence: AnySequence<OSLogEntry>) -> AnySequence<Entry> {
        AnySequence(sequence.lazy.compactMap { raw -> Entry? in
            guard let log = raw as? OSLogEntryLog else { return nil }
            return Entry(
                date: log.date,
                level: describe(level: log.level),
                subsystem: log.subsystem,
                processID: log.processIdentifier,
                message: log.composedMessage
            )
        })
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
