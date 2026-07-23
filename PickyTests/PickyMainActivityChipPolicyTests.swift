//
//  PickyMainActivityChipPolicyTests.swift
//  PickyTests
//

import Testing
@testable import Picky

struct PickyMainActivityChipPolicyTests {
    @Test func readDetailUsesOnlyLastPathComponentAndTruncatesAtFortyFourCharacters() {
        let filename = String(repeating: "a", count: 50) + ".swift"
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "read-1",
            toolName: "read",
            status: "running",
            argsPreview: "{\"path\":\"Picky/Overlay/\(filename)\"}"
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.detail == String(filename.prefix(44)) + "…")
        #expect(model?.detail?.contains("Picky/") == false)
    }

    @Test func bashDetailPrefersTitleOverCommand() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "bash-title",
            toolName: "bash",
            status: "running",
            argsPreview: #"{"title":"Run\nfocused test","command":"xcodebuild test"}"#
        )

        #expect(PickyMainActivityChipModel.chipModel(for: activity)?.detail == "Run focused test")
    }

    @Test func bashDetailUsesFirstCommandLineWithoutUserBashPrefix() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "bash-command",
            toolName: "bash",
            status: "running",
            argsPreview: #"{"command":"$ pnpm test\nsecond line"}"#
        )

        #expect(PickyMainActivityChipModel.chipModel(for: activity)?.detail == "pnpm test")
    }

    @Test func mcpToolUsesLastNameSegment() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "mcp-1",
            toolName: "mcp__creatrip__slack_searchmessages",
            status: "running",
            argsPreview: #"{"query":"release readiness"}"#
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.category == .normal)
        #expect(model?.label == "slack_searchmessages")
        #expect(model?.detail == "release readiness")
    }

    @Test func pickleToolUsesPickleCategoryAndTitle() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "pickle-1",
            toolName: "picky_start_pickle",
            status: "running",
            argsPreview: #"{"title":"Investigate overlay regression"}"#
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.category == .pickle)
        #expect(model?.detail == "Investigate overlay regression")
    }

    @Test func thinkingDetailFlattensMarkdownAndTruncatesAtSixtyCharacters() {
        let plain = "bold " + String(repeating: "x", count: 70)
        let activity = PickyMainActivity(
            kind: .thinking,
            thinkingPreview: "**bold** " + String(repeating: "x", count: 70)
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.category == .thinking)
        #expect(model?.label == "생각 중")
        #expect(model?.detail == String(plain.prefix(60)) + "…")
        #expect(model?.isRunning == true)
    }

    @Test func stackKeepsPreviousCompletedToolAndCurrentRunningTool() {
        let firstRunning = tool(id: "tool-1", status: "running")
        let firstSucceeded = tool(id: "tool-1", status: "succeeded")
        let secondRunning = tool(id: "tool-2", status: "running")
        let thirdRunning = tool(id: "tool-3", status: "running")

        let afterFirst = PickyMainActivityStack.apply(firstRunning, to: [])
        let afterCompletion = PickyMainActivityStack.apply(firstSucceeded, to: afterFirst)
        let afterSecond = PickyMainActivityStack.apply(secondRunning, to: afterCompletion)
        let afterThird = PickyMainActivityStack.apply(thirdRunning, to: afterSecond)

        #expect(afterSecond.map(\.toolCallId) == ["tool-1", "tool-2"])
        #expect(afterSecond.map(\.status) == ["succeeded", "running"])
        #expect(afterThird.map(\.toolCallId) == ["tool-2", "tool-3"])
    }

    @Test func stackDiscardsThinkingWhenAToolStarts() {
        let thinking = PickyMainActivity(kind: .thinking, thinkingPreview: "Checking the implementation")
        let tool = self.tool(id: "tool-1", status: "running")

        let stack = PickyMainActivityStack.apply(tool, to: [thinking])

        #expect(stack == [tool])
    }

    @Test func stackUpdatesMatchingToolStatusWithoutDiscardingItsDetail() {
        let running = PickyMainActivity(
            kind: .tool,
            toolCallId: "tool-1",
            toolName: "read",
            status: "running",
            argsPreview: #"{"path":"Picky/Overlay/BlueCursorView.swift"}"#
        )
        let succeeded = PickyMainActivity(kind: .tool, toolCallId: "tool-1", status: "succeeded")

        let stack = PickyMainActivityStack.apply(succeeded, to: [running])

        #expect(stack == [PickyMainActivity(
            kind: .tool,
            toolCallId: "tool-1",
            toolName: "read",
            status: "succeeded",
            argsPreview: #"{"path":"Picky/Overlay/BlueCursorView.swift"}"#
        )])
    }

    private func tool(id: String, status: String) -> PickyMainActivity {
        PickyMainActivity(kind: .tool, toolCallId: id, toolName: "read", status: status)
    }
}
