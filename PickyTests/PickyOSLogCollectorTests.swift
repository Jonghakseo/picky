//
//  PickyOSLogCollectorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyOSLogCollectorTests {
    private struct StoreError: LocalizedError {
        var errorDescription: String? { "system store denied token=private-token" }
    }

    @Test func systemFailureFallsBackToCurrentProcessAndKeepsOnlyPickyEntries() {
        var requestedScopes: [PickyOSLogCollector.Scope] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rendered = PickyOSLogCollector.collect(window: 600, now: now) { scope, _ in
            requestedScopes.append(scope)
            if scope == .system { throw StoreError() }
            return [
                PickyOSLogCollector.Entry(
                    date: now.addingTimeInterval(-1),
                    level: "N",
                    subsystem: "unrelated.process",
                    processID: 999,
                    message: "unrelated secret"
                ),
                PickyOSLogCollector.Entry(
                    date: now,
                    level: "E",
                    subsystem: PickyLog.subsystem,
                    processID: 42,
                    message: "apiKey=super-secret-value latest Picky evidence"
                )
            ]
        }

        #expect(requestedScopes == [.system, .currentProcess])
        #expect(rendered.contains("scope=currentProcess"))
        #expect(rendered.contains("fallback=system unavailable"))
        #expect(rendered.contains("pid=42"))
        #expect(rendered.contains("latest Picky evidence"))
        #expect(!rendered.contains("unrelated.process"))
        #expect(!rendered.contains("unrelated secret"))
        #expect(!rendered.contains("super-secret-value"))
        #expect(rendered.contains("<redacted>"))
    }

    @Test func systemFailureUsesUnfilteredCurrentProcessEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rendered = PickyOSLogCollector.collect(window: 600, now: now, retainedProcessIDs: [42]) { scope, _ in
            if scope == .system { throw StoreError() }
            return [
                PickyOSLogCollector.Entry(
                    date: now,
                    level: "E",
                    subsystem: PickyLog.subsystem,
                    processID: 99,
                    message: "CURRENT-PROCESS-FALLBACK-EVIDENCE"
                )
            ]
        }

        #expect(rendered.contains("scope=currentProcess"))
        #expect(rendered.contains("processFilter=subsystem-only"))
        #expect(rendered.contains("CURRENT-PROCESS-FALLBACK-EVIDENCE"))
        #expect(!rendered.contains("processFilter=pid=42"))
    }

    /// Regression: filtering to the previous run alone blinded every bug report
    /// filed while the app was still running, which is the common case.
    @Test func retainedPIDsKeepBothPreviousAndCurrentRunEvidence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rendered = PickyOSLogCollector.collect(window: 600, now: now, retainedProcessIDs: [42, 99]) { _, _ in
            [
                PickyOSLogCollector.Entry(
                    date: now.addingTimeInterval(-10),
                    level: "E",
                    subsystem: PickyLog.subsystem,
                    processID: 42,
                    message: "CRASHED-PROCESS-EVIDENCE"
                ),
                PickyOSLogCollector.Entry(
                    date: now.addingTimeInterval(-1),
                    level: "N",
                    subsystem: PickyLog.subsystem,
                    processID: 99,
                    message: "STILL-RUNNING-PROCESS-EVIDENCE"
                ),
                PickyOSLogCollector.Entry(
                    date: now,
                    level: "N",
                    subsystem: PickyLog.subsystem,
                    processID: 7,
                    message: "UNRELATED-INSTANCE-EVIDENCE"
                )
            ]
        }

        #expect(rendered.contains("processFilter=pid=42,99"))
        #expect(rendered.contains("CRASHED-PROCESS-EVIDENCE"))
        #expect(rendered.contains("STILL-RUNNING-PROCESS-EVIDENCE"))
        #expect(!rendered.contains("UNRELATED-INSTANCE-EVIDENCE"))
    }

    @Test func emptyRetainedPIDsKeepEveryPickySubsystemProcess() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rendered = PickyOSLogCollector.collect(window: 600, now: now) { _, _ in
            [
                PickyOSLogCollector.Entry(
                    date: now,
                    level: "N",
                    subsystem: PickyLog.subsystem,
                    processID: 7,
                    message: "UNFILTERED-EVIDENCE"
                )
            ]
        }

        #expect(rendered.contains("processFilter=subsystem-only"))
        #expect(rendered.contains("UNFILTERED-EVIDENCE"))
    }

    @Test func boundedEntryPolicyKeepsNewestFixedWorkingSet() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (0..<(PickyOSLogCollector.maximumCollectedEntries + 3)).map { index in
            PickyOSLogCollector.Entry(
                date: now.addingTimeInterval(TimeInterval(index)),
                level: "N",
                subsystem: PickyLog.subsystem,
                processID: 42,
                message: "entry-\(index)"
            )
        }

        let bounded = PickyOSLogCollector.boundedNewestEntries(from: entries)

        #expect(bounded.count == PickyOSLogCollector.maximumCollectedEntries)
        #expect(bounded.first?.message == "entry-3")
        #expect(bounded.last?.message == "entry-\(PickyOSLogCollector.maximumCollectedEntries + 2)")
    }

    @Test func rendererCapsOutputAndRetainsNewestPickyEntry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = (0..<100).map { index in
            PickyOSLogCollector.Entry(
                date: now.addingTimeInterval(TimeInterval(index)),
                level: "N",
                subsystem: PickyLog.subsystem,
                processID: 42,
                message: "old-\(index) \(String(repeating: "x", count: 80))"
            )
        } + [
            PickyOSLogCollector.Entry(
                date: now.addingTimeInterval(100),
                level: "N",
                subsystem: PickyLog.subsystem,
                processID: 42,
                message: String(repeating: "x", count: PickyOSLogCollector.maximumRenderedBytes + 1)
            ),
            PickyOSLogCollector.Entry(
                date: now.addingTimeInterval(101),
                level: "E",
                subsystem: PickyLog.subsystem,
                processID: 42,
                message: "NEWEST-PICKY-EVIDENCE"
            )
        ]

        let rendered = PickyOSLogCollector.render(
            entries: entries,
            scope: .system,
            window: 600,
            maxBytes: PickyOSLogCollector.maximumRenderedBytes
        )

        #expect(rendered.lengthOfBytes(using: .utf8) <= PickyOSLogCollector.maximumRenderedBytes)
        #expect(rendered.contains("scope=system"))
        #expect(rendered.contains("truncated=true"))
        #expect(rendered.contains("NEWEST-PICKY-EVIDENCE"))
        #expect(!rendered.contains("old-0"))
    }

    // MARK: - Bounded iteration

    private func entry(_ date: Date, _ message: String, pid: Int32 = 42) -> PickyOSLogCollector.Entry {
        PickyOSLogCollector.Entry(
            date: date,
            level: "N",
            subsystem: PickyLog.subsystem,
            processID: pid,
            message: message
        )
    }

    /// Regression: the collector used to traverse the whole store and keep a
    /// trailing suffix. Fed a newest-first store that is the oldest evidence,
    /// which is exactly the opposite of what a bug report needs.
    @Test func newestFirstSourceKeepsTheNewestEntriesWithinTheCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newestFirst = (0..<10).map { index in
            entry(now.addingTimeInterval(TimeInterval(-index)), "entry-\(index)")
        }

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .newestFirst, entries: newestFirst),
            start: now.addingTimeInterval(-600),
            end: now,
            retainedProcessIDs: [],
            maximumCount: 3
        )

        #expect(bounded.limitedByCount)
        #expect(bounded.entries.map(\.message) == ["entry-2", "entry-1", "entry-0"])
    }

    /// The cap has to stop the walk, not just trim its result: a full
    /// traversal is what made collection slow in the first place.
    @Test func capStopsIterationInsteadOfDrainingTheStore() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var examined = 0
        let counted = AnySequence((0..<100_000).lazy.map { index -> PickyOSLogCollector.Entry in
            examined += 1
            return self.entry(now.addingTimeInterval(TimeInterval(-index)), "entry-\(index)")
        })

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .newestFirst, entries: counted),
            start: now.addingTimeInterval(-600_000),
            end: now,
            retainedProcessIDs: [],
            maximumCount: 25
        )

        #expect(bounded.entries.count == 25)
        #expect(examined == 25)
    }

    @Test func newestFirstWalkStopsAtTheRequestedWindow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            entry(now.addingTimeInterval(-10), "inside"),
            entry(now.addingTimeInterval(-700), "outside"),
            entry(now.addingTimeInterval(-800), "far-outside")
        ]

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .newestFirst, entries: entries),
            start: now.addingTimeInterval(-600),
            end: now,
            retainedProcessIDs: []
        )

        #expect(bounded.entries.map(\.message) == ["inside"])
        #expect(!bounded.isTruncated)
        #expect(bounded.examinedCount == 2)
    }

    @Test func processFilterDropsOtherPickyInstances() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let entries = [
            entry(now, "current-run", pid: 42),
            entry(now.addingTimeInterval(-1), "other-instance", pid: 7)
        ]

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .newestFirst, entries: entries),
            start: now.addingTimeInterval(-600),
            end: now,
            retainedProcessIDs: [42]
        )

        #expect(bounded.entries.map(\.message) == ["current-run"])
    }

    /// A store that answers slowly must not hold the feedback send hostage.
    @Test func expiredDeadlineStopsTheWalkAndIsDisclosed() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var served = 0
        let entries = AnySequence((0..<1_000).lazy.map { index -> PickyOSLogCollector.Entry in
            served += 1
            return self.entry(now.addingTimeInterval(TimeInterval(-index)), "entry-\(index)")
        })

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .newestFirst, entries: entries),
            start: now.addingTimeInterval(-600_000),
            end: now,
            retainedProcessIDs: [],
            isExpired: { served >= 5 }
        )

        #expect(bounded.deadlineExceeded)
        #expect(!bounded.entries.isEmpty)
        #expect(bounded.entries.count <= 5)
        // Whatever it managed to read is still the newest slice.
        #expect(bounded.entries.last?.message == "entry-0")

        let rendered = PickyOSLogCollector.render(bounded: bounded, scope: .system, window: 600)
        #expect(rendered.contains("deadlineExceeded=true"))
        #expect(rendered.contains("iterationOrder=newestFirst"))
    }

    /// A store that never answers is reported as an omission so the reader
    /// knows the evidence is missing rather than empty.
    @Test func omittedCollectionExplainsWhyNoEntriesArePresent() {
        let rendered = PickyOSLogCollector.renderOmission(
            .deadlineExceeded(8),
            window: 600,
            retainedProcessIDs: [42]
        )

        #expect(rendered.contains("omitted=true"))
        #expect(rendered.contains("8s budget"))
        #expect(rendered.contains("processFilter=pid=42"))
    }

    /// Chronological stores (the current-process fallback ignores `.reverse`)
    /// still have to end up with the newest entries.
    @Test func chronologicalSourceKeepsNewestEntriesWithinTheCap() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let chronological = (0..<10).map { index in
            entry(now.addingTimeInterval(TimeInterval(index - 10)), "entry-\(index)")
        }

        let bounded = PickyOSLogCollector.bound(
            PickyOSLogCollector.EntryStream(order: .chronological, entries: chronological),
            start: now.addingTimeInterval(-600),
            end: now,
            retainedProcessIDs: [],
            maximumCount: 3
        )

        #expect(bounded.limitedByCount)
        #expect(bounded.entries.map(\.message) == ["entry-7", "entry-8", "entry-9"])
    }
}
