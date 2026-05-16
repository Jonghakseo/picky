//
//  PickyAgentdToolEventSummarizerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyAgentdToolEventSummarizerTests {
    @Test func parsesOnlyToolNameStatusAndTimestamp() {
        let line = "2026-05-12T08:00:00.000Z picky-agentd tool activity sessionId=\"secret-session\" tool=\"bash\" status=running previewChars=999"
        let event = PickyAgentdToolEventSummarizer.parseToolEventLine(line)
        #expect(event == PickyAgentdToolEvent(timestamp: "2026-05-12T08:00:00.000Z", toolName: "bash", status: "running"))
    }

    @Test func ignoresNonToolActivityLines() {
        let line = "2026-05-12T08:00:00.000Z picky-agentd session status sessionId=\"secret\" status=running"
        #expect(PickyAgentdToolEventSummarizer.parseToolEventLine(line) == nil)
    }

    @Test func summarizeOmitsSessionPreviewArgumentsAndResults() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-tool-events-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = """
        2026-05-12T08:00:00.000Z picky-agentd tool activity sessionId=\"secret-session\" tool=\"bash\" status=running previewChars=999
        user chat should never appear
        command=\"rm -rf sensitive\"
        result=\"private output\"
        2026-05-12T08:00:01.000Z picky-agentd tool activity sessionId=\"secret-session\" tool=\"bash\" status=succeeded previewChars=999
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let summary = PickyAgentdToolEventSummarizer.summarize(from: url)
        #expect(summary.contains("tool=bash status=running"))
        #expect(summary.contains("tool=bash status=succeeded"))
        #expect(summary.contains("bash: 2"))
        #expect(!summary.contains("secret-session"))
        #expect(!summary.contains("user chat should never appear"))
        #expect(!summary.contains("rm -rf sensitive"))
        #expect(!summary.contains("private output"))
    }
}
