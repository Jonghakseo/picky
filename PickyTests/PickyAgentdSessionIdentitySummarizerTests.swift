//
//  PickyAgentdSessionIdentitySummarizerTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

@Suite
struct PickyAgentdSessionIdentitySummarizerTests {
    @Test func parsesTitleRefreshLine() {
        let line = "2026-06-23T09:20:00.000Z picky-agentd pickle session title refreshed from pi sessionId=\"session-3EFAEA4F\" previousTitle=\"New Pickle \u{00B7} dotnco\" name=\"\u{AC10}\u{C2DC}\u{BAA8}\u{B4DC} \u{C571} \u{C124}\u{ACC4}\""
        let event = PickyAgentdSessionIdentitySummarizer.parseLine(line)
        #expect(event?.sessionId == "session-3EFAEA4F")
        #expect(event?.event == "pickle session title refreshed from pi")
        #expect(event?.previousTitle == "New Pickle \u{00B7} dotnco")
        #expect(event?.name == "\u{AC10}\u{C2DC}\u{BAA8}\u{B4DC} \u{C571} \u{C124}\u{ACC4}")
    }

    @Test func reducesSessionFilePathToBasename() {
        let line = "2026-06-23T09:19:05.000Z picky-agentd terminal tail started sessionId=\"session-3EFAEA4F\" sessionFilePath=\"/Users/mindasom/.pi/agent/sessions/--Users-mindasom-dev-dotnco--/1782206345_abc123.jsonl\""
        let event = PickyAgentdSessionIdentitySummarizer.parseLine(line)
        #expect(event?.sessionFiles == ["1782206345_abc123.jsonl"])
    }

    @Test func ignoresLinesWithoutIdentityFields() {
        let toolLine = "2026-06-23T09:20:00.000Z picky-agentd tool activity sessionId=\"session-3EFAEA4F\" tool=\"bash\" status=running"
        #expect(PickyAgentdSessionIdentitySummarizer.parseLine(toolLine) == nil)
        let noSession = "2026-06-23T09:20:00.000Z picky-agentd something happened cwd=\"/tmp\""
        #expect(PickyAgentdSessionIdentitySummarizer.parseLine(noSession) == nil)
    }

    @Test func summarizeFlagsTitleFlipSharedFileAndRedactsHomePath() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("picky-session-identity-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        let raw = """
        2026-06-23T09:19:04.000Z picky-agentd empty pickle session queued sessionId=\"session-AAA\" cwd=\"/Users/mindasom/dev/dotnco\" contextId=\"ctx-1\"
        user chat should never appear
        2026-06-23T09:19:05.000Z picky-agentd terminal tail started sessionId=\"session-AAA\" sessionFilePath=\"/Users/mindasom/.pi/agent/sessions/--enc--/shared_file.jsonl\"
        2026-06-23T09:20:30.000Z picky-agentd pickle session title refreshed from pi sessionId=\"session-AAA\" previousTitle=\"New Pickle \u{00B7} dotnco\" name=\"\u{AC10}\u{C2DC}\u{BAA8}\u{B4DC} \u{C571} \u{C124}\u{ACC4}\"
        2026-06-23T09:21:00.000Z picky-agentd terminal tail started sessionId=\"session-BBB\" sessionFilePath=\"/Users/mindasom/.pi/agent/sessions/--enc--/shared_file.jsonl\"
        """
        try raw.write(to: url, atomically: true, encoding: .utf8)

        let summary = PickyAgentdSessionIdentitySummarizer.summarize(from: url)
        // Title flip is visible.
        #expect(summary.contains("previousTitle=\"New Pickle \u{00B7} dotnco\" -> name=\"\u{AC10}\u{C2DC}\u{BAA8}\u{B4DC} \u{C571} \u{C124}\u{ACC4}\""))
        #expect(summary.contains("titleTimeline:"))
        // Cross-load detection fires for the shared basename.
        #expect(summary.contains("shared_file.jsonl <- session=session-AAA, session=session-BBB"))
        // Privacy: home path redacted, raw chat excluded.
        #expect(summary.contains("/Users/<redacted-user>/dev/dotnco"))
        #expect(!summary.contains("mindasom"))
        #expect(!summary.contains("user chat should never appear"))
    }
}
