//
//  PickyToolHistoryEntryTests.swift
//  PickyTests
//
//  Verifies the pure renderer turning PickyToolActivity into structured entries.
//

import Testing
import Foundation
@testable import Picky

struct PickyToolHistoryEntryTests {
    @Test func categorizesKnownAndUnknownToolNames() {
        #expect(PickyToolHistoryRenderer.category(for: "read") == .read)
        #expect(PickyToolHistoryRenderer.category(for: "Bash") == .bash)
        #expect(PickyToolHistoryRenderer.category(for: "Edit") == .edit)
        #expect(PickyToolHistoryRenderer.category(for: "multiedit") == .edit)
        #expect(PickyToolHistoryRenderer.category(for: "write") == .write)
        #expect(PickyToolHistoryRenderer.category(for: "mcp__creatrip__jira_getissue") == .other)
    }

    @Test func readEntryExtractsFileAndRange() {
        let tool = PickyToolActivity(
            toolCallId: "call-1",
            name: "read",
            status: "succeeded",
            preview: "240 lines",
            argsPreview: #"{"path":"Picky/HUD/PickyHUDView.swift","offset":1,"limit":50}"#,
            resultPreview: "line one\nline two\nline three"
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 1)
        #expect(entry.category == .read)
        #expect(entry.status == .succeeded)
        guard case let .read(file, range, summary) = entry.detail else {
            Issue.record("Expected read detail, got \(entry.detail)")
            return
        }
        #expect(file == "Picky/HUD/PickyHUDView.swift")
        #expect(range == "L1–L50")
        #expect(summary?.contains("3 lines") == true)
    }

    @Test func bashEntryExposesCommandAndOutput() {
        let tool = PickyToolActivity(
            toolCallId: "call-2",
            name: "bash",
            status: "succeeded",
            preview: nil,
            argsPreview: #"{"command":"pnpm test","title":"테스트 실행"}"#,
            resultPreview: "Tests 316 passed"
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 2)
        #expect(entry.category == .bash)
        guard case let .bash(command, title, output) = entry.detail else {
            Issue.record("Expected bash detail")
            return
        }
        #expect(command == "pnpm test")
        #expect(title == "테스트 실행")
        #expect(output == "Tests 316 passed")
    }

    @Test func editEntryParsesEditsArrayAndKeyAliases() {
        let tool = PickyToolActivity(
            toolCallId: "call-3",
            name: "edit",
            status: "succeeded",
            preview: nil,
            argsPreview: #"{"path":"a.swift","edits":[{"oldText":"foo","newText":"bar"},{"old_string":"baz","new_string":"qux"}]}"#
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 3)
        guard case let .edit(file, changes) = entry.detail else {
            Issue.record("Expected edit detail")
            return
        }
        #expect(file == "a.swift")
        #expect(changes == [
            PickyToolHistoryEditChange(oldText: "foo", newText: "bar"),
            PickyToolHistoryEditChange(oldText: "baz", newText: "qux"),
        ])
    }

    @Test func writeEntryReadsContent() {
        let tool = PickyToolActivity(
            toolCallId: "call-4",
            name: "write",
            status: "succeeded",
            argsPreview: #"{"path":"new.swift","content":"hello"}"#
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 4)
        guard case let .write(file, content) = entry.detail else {
            Issue.record("Expected write detail")
            return
        }
        #expect(file == "new.swift")
        #expect(content == "hello")
    }

    @Test func otherToolUsesPrettyJsonAndKeepsResult() {
        let tool = PickyToolActivity(
            toolCallId: "call-5",
            name: "mcp__creatrip__jira_getissue",
            status: "succeeded",
            argsPreview: #"{"issue_key":"COM-123","fields":"summary"}"#,
            resultPreview: "{\"key\":\"COM-123\"}"
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 5)
        #expect(entry.category == .other)
        guard case let .generic(argsJSON, result) = entry.detail else {
            Issue.record("Expected generic detail")
            return
        }
        #expect(argsJSON?.contains("\"issue_key\"") == true)
        #expect(argsJSON?.contains("  ") == true)
        #expect(result == "{\"key\":\"COM-123\"}")
    }

    @Test func durationComputesFromStartAndEnd() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let end = start.addingTimeInterval(0.350)
        let tool = PickyToolActivity(
            toolCallId: "call-6",
            name: "bash",
            status: "succeeded",
            startedAt: start,
            endedAt: end
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 6)
        #expect(entry.durationMs == 350)
    }

    @Test func summaryAggregatesCounts() {
        let entries = PickyToolHistoryRenderer.entries(from: [
            PickyToolActivity(toolCallId: "1", name: "read", status: "succeeded", argsPreview: #"{"path":"a"}"#),
            PickyToolActivity(toolCallId: "2", name: "bash", status: "succeeded", argsPreview: #"{"command":"ls"}"#),
            PickyToolActivity(toolCallId: "3", name: "bash", status: "failed", argsPreview: #"{"command":"oops"}"#),
            PickyToolActivity(toolCallId: "4", name: "grep", status: "succeeded", argsPreview: #"{"pattern":"x"}"#),
        ])
        let summary = PickyToolHistorySummary(entries: entries)
        #expect(summary.total == 4)
        #expect(summary.count(of: .read) == 1)
        #expect(summary.count(of: .bash) == 2)
        #expect(summary.count(of: .other) == 1)
    }
}
