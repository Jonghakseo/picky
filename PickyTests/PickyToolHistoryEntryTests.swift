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
        #expect(PickyToolHistoryRenderer.category(for: "mcp__example__jira_getissue") == .other)
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
            argsPreview: #"{"command":"pnpm test"}"#,
            resultPreview: "Tests 316 passed"
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 2)
        #expect(entry.category == .bash)
        guard case let .bash(command, output) = entry.detail else {
            Issue.record("Expected bash detail")
            return
        }
        #expect(command == "pnpm test")
        #expect(output == "Tests 316 passed")
    }

    @Test func bashEntryRecoversCommandFromTruncatedJson() {
        let truncatedArgs = #"{"command":"xcodebuild -project Picky.xcodeproj -scheme Picky -destination 'platform=macOS' test -only-testing:PickyTests/Foo""# // missing closing quote/brace
        let tool = PickyToolActivity(
            toolCallId: "call-2b",
            name: "bash",
            status: "running",
            argsPreview: truncatedArgs
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 1)
        guard case let .bash(command, _) = entry.detail else {
            Issue.record("Expected bash detail")
            return
        }
        #expect(command?.contains("xcodebuild") == true)
        #expect(command?.contains("only-testing") == true)
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

    @Test func editEntryRecoversPathAndFirstChangeFromTruncatedJson() {
        let truncatedArgs = "{\"path\":\"Picky/HUD/Foo.swift\",\"edits\":[{\"oldText\":\"let old = 1\\nlet more = \\\"quoted"
        let tool = PickyToolActivity(
            toolCallId: "call-3b",
            name: "edit",
            status: "running",
            argsPreview: truncatedArgs
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 1)
        guard case let .edit(file, changes) = entry.detail else {
            Issue.record("Expected edit detail")
            return
        }
        #expect(file == "Picky/HUD/Foo.swift")
        #expect(changes.count == 1)
        #expect(changes.first?.oldText.contains("let old = 1\nlet more = \"quoted") == true)
    }

    @Test func writeEntryRecoversPathAndContentFromTruncatedJson() {
        let truncatedArgs = "{\"path\":\"Sources/NewFile.swift\",\"content\":\"line 1\\nline 2"
        let tool = PickyToolActivity(
            toolCallId: "call-4b",
            name: "write",
            status: "running",
            argsPreview: truncatedArgs
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 1)
        guard case let .write(file, content) = entry.detail else {
            Issue.record("Expected write detail")
            return
        }
        #expect(file == "Sources/NewFile.swift")
        #expect(content == "line 1\nline 2")
    }

    @Test func otherToolUsesPrettyJsonAndKeepsResult() {
        let tool = PickyToolActivity(
            toolCallId: "call-5",
            name: "mcp__example__jira_getissue",
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

    @Test func scopeFiltersToolsByStartedAt() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let tools: [PickyToolActivity] = [
            PickyToolActivity(toolCallId: "t1", name: "bash", status: "succeeded", argsPreview: #"{"command":"a"}"#, startedAt: base),
            PickyToolActivity(toolCallId: "t2", name: "bash", status: "succeeded", argsPreview: #"{"command":"b"}"#, startedAt: base.addingTimeInterval(60)),
            PickyToolActivity(toolCallId: "t3", name: "bash", status: "succeeded", argsPreview: #"{"command":"c"}"#, startedAt: base.addingTimeInterval(120)),
        ]
        let sessionEntries = PickyToolHistoryRenderer.entries(from: tools, scope: .session)
        #expect(sessionEntries.map(\.id) == ["t1", "t2", "t3"])
        let middle = PickyToolHistoryRenderer.entries(from: tools, scope: .dateRange(start: base.addingTimeInterval(30), end: base.addingTimeInterval(90)))
        #expect(middle.map(\.id) == ["t2"])
        let openEnded = PickyToolHistoryRenderer.entries(from: tools, scope: .dateRange(start: base.addingTimeInterval(60), end: nil))
        #expect(openEnded.map(\.id) == ["t2", "t3"])
        let toolWithoutStart = PickyToolActivity(toolCallId: "t4", name: "bash", status: "succeeded", argsPreview: #"{"command":"d"}"#)
        let mixed = PickyToolHistoryRenderer.entries(from: [toolWithoutStart] + tools, scope: .dateRange(start: base, end: nil))
        #expect(mixed.map(\.id) == ["t1", "t2", "t3"]) // tool without startedAt is excluded under bounded range
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

    @Test func readRangeFallsBackWhenOffsetOrLimitMissing() {
        let offsetOnly = PickyToolActivity(
            toolCallId: "r-1",
            name: "read",
            status: "succeeded",
            argsPreview: #"{"path":"a.swift","offset":40}"#
        )
        guard case let .read(_, range1, _) = PickyToolHistoryRenderer.entry(from: offsetOnly, index: 1).detail else {
            Issue.record("Expected read detail"); return
        }
        #expect(range1 == "from L40")

        let limitOnly = PickyToolActivity(
            toolCallId: "r-2",
            name: "read",
            status: "succeeded",
            argsPreview: #"{"path":"a.swift","limit":120}"#
        )
        guard case let .read(_, range2, _) = PickyToolHistoryRenderer.entry(from: limitOnly, index: 1).detail else {
            Issue.record("Expected read detail"); return
        }
        #expect(range2 == "first 120 lines")

        let neither = PickyToolActivity(
            toolCallId: "r-3",
            name: "read",
            status: "succeeded",
            argsPreview: #"{"path":"a.swift"}"#
        )
        guard case let .read(_, range3, _) = PickyToolHistoryRenderer.entry(from: neither, index: 1).detail else {
            Issue.record("Expected read detail"); return
        }
        #expect(range3 == nil)
    }

    @Test func statusMapsErrorAndUnknownStrings() {
        let failed = PickyToolHistoryRenderer.entry(
            from: PickyToolActivity(toolCallId: "s-1", name: "bash", status: "error", argsPreview: #"{"command":"x"}"#),
            index: 1
        )
        #expect(failed.status == .failed)

        let running = PickyToolHistoryRenderer.entry(
            from: PickyToolActivity(toolCallId: "s-2", name: "bash", status: "in_progress", argsPreview: #"{"command":"x"}"#),
            index: 1
        )
        // Anything other than succeeded/failed/error falls back to running, matching
        // the renderer's defensive default so a never-before-seen status string still
        // surfaces a row instead of being silently dropped.
        #expect(running.status == .running)
    }

    @Test func recoverStringValueDecodesEscapeSequencesFromTruncatedJson() {
        let truncated = #"{"command":"echo \"hi\"\nls -la /tmp\tend""#
        let recovered = PickyToolHistoryRenderer.recoverStringValue(from: truncated, key: "command")
        #expect(recovered == "echo \"hi\"\nls -la /tmp\tend")

        // Missing key falls back to nil instead of fabricating.
        #expect(PickyToolHistoryRenderer.recoverStringValue(from: truncated, key: "path") == nil)
        #expect(PickyToolHistoryRenderer.recoverStringValue(from: nil, key: "command") == nil)
    }

    @Test func genericDetailFallsBackToRawArgsWhenJsonIsInvalid() {
        let invalid = "{not-json: \"oh no\""
        let tool = PickyToolActivity(
            toolCallId: "g-1",
            name: "mcp__unknown__doSomething",
            status: "succeeded",
            argsPreview: invalid,
            resultPreview: "ok"
        )
        let entry = PickyToolHistoryRenderer.entry(from: tool, index: 1)
        guard case let .generic(argsJSON, result) = entry.detail else {
            Issue.record("Expected generic detail"); return
        }
        // prettyJSON should have returned nil, so the renderer keeps the raw preview
        // verbatim instead of dropping context into the void.
        #expect(argsJSON == invalid)
        #expect(result == "ok")
    }

    @Test func durationReturnsNilWhenBoundsAreMissingOrInverted() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let onlyStart = PickyToolHistoryRenderer.entry(
            from: PickyToolActivity(toolCallId: "d-1", name: "bash", status: "running", argsPreview: #"{"command":"x"}"#, startedAt: start),
            index: 1
        )
        #expect(onlyStart.durationMs == nil)

        let inverted = PickyToolHistoryRenderer.entry(
            from: PickyToolActivity(toolCallId: "d-2", name: "bash", status: "succeeded", argsPreview: #"{"command":"x"}"#, startedAt: start, endedAt: start.addingTimeInterval(-1)),
            index: 1
        )
        #expect(inverted.durationMs == nil)
    }

    @Test func categoryFiltersPreserveSourceOrderAndAllowMultipleSelections() {
        let entries = filterEntries()
        let visible = PickyToolHistoryFilterPolicy.filter(
            entries: entries,
            selectedCategories: [.read, .edit]
        )

        #expect(visible.map(\.id) == ["read", "edit"])
    }

    @Test func failureAndTextFiltersCombineWithCategoryFilters() {
        let entries = filterEntries()
        let visible = PickyToolHistoryFilterPolicy.filter(
            entries: entries,
            selectedCategories: [.bash],
            failuresOnly: true,
            query: "RETRY"
        )

        #expect(visible.map(\.id) == ["failed-bash"])
    }

    @Test func searchMatchesRenderedDetailTextCaseInsensitively() {
        let entries = filterEntries()

        #expect(PickyToolHistoryFilterPolicy.filter(entries: entries, query: "config.swift").map(\.id) == ["read"])
        #expect(PickyToolHistoryFilterPolicy.filter(entries: entries, query: "deploy preview").map(\.id) == ["failed-bash"])
        #expect(PickyToolHistoryFilterPolicy.filter(entries: entries, query: "  ").map(\.id) == entries.map(\.id))
    }

    @Test func filterResultKeepsTotalAndReportsNoMatches() {
        let result = PickyToolHistoryFilterPolicy.result(
            entries: filterEntries(),
            selectedCategories: [.write],
            failuresOnly: true,
            query: "missing"
        )

        #expect(result.totalCount == 4)
        #expect(result.visibleCount == 0)
        #expect(result.entries.isEmpty)
    }

    private func filterEntries() -> [PickyToolHistoryEntry] {
        [
            PickyToolHistoryEntry(
                id: "read",
                index: 1,
                name: "read",
                category: .read,
                status: .succeeded,
                durationMs: nil,
                startedAt: nil,
                detail: .read(file: "Config.swift", range: "L1–L10", resultSummary: "10 lines")
            ),
            PickyToolHistoryEntry(
                id: "failed-bash",
                index: 2,
                name: "bash",
                category: .bash,
                status: .failed,
                durationMs: nil,
                startedAt: nil,
                detail: .bash(command: "deploy preview", output: "retry after failure")
            ),
            PickyToolHistoryEntry(
                id: "edit",
                index: 3,
                name: "edit",
                category: .edit,
                status: .succeeded,
                durationMs: nil,
                startedAt: nil,
                detail: .edit(file: "PickyHUDView.swift", changes: [])
            ),
            PickyToolHistoryEntry(
                id: "write",
                index: 4,
                name: "write",
                category: .write,
                status: .running,
                durationMs: nil,
                startedAt: nil,
                detail: .write(file: "Report.md", content: "draft")
            ),
        ]
    }
}
