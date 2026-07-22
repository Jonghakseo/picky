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
}
