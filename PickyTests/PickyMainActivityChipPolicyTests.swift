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

    @Test func skillReadShowsSkillNameInsteadOfManifestFilename() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "read-skill",
            toolName: "read",
            status: "running",
            argsPreview: #"{"path":"/Users/example/.pi/agent/skills/context7-cli/SKILL.md"}"#
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.label == "skill")
        #expect(model?.detail == "context7-cli")
    }

    @Test func ordinaryManifestReadKeepsReadToolPresentation() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "read-manifest",
            toolName: "read",
            status: "running",
            argsPreview: #"{"path":"docs/SKILL.md"}"#
        )

        let model = PickyMainActivityChipModel.chipModel(for: activity)

        #expect(model?.label == "read")
        #expect(model?.detail == "SKILL.md")
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

    @Test func emptyArgsPreviewOmitsDetail() {
        for empty in ["{}", "{ }", "[]", "", "   "] {
            let activity = PickyMainActivity(
                kind: .tool,
                toolCallId: "empty-\(empty.count)",
                toolName: "list_agents",
                status: "running",
                argsPreview: empty
            )
            let model = PickyMainActivityChipModel.chipModel(for: activity)
            #expect(model?.label == "list_agents")
            #expect(model?.detail == nil)
        }
    }

    @Test func nilArgsPreviewOmitsDetail() {
        let activity = PickyMainActivity(
            kind: .tool,
            toolCallId: "noargs-1",
            toolName: "reload_plugins",
            status: "running",
            argsPreview: nil
        )
        let model = PickyMainActivityChipModel.chipModel(for: activity)
        #expect(model?.label == "reload_plugins")
        #expect(model?.detail == nil)
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
        #expect(model?.label == L10n.t("overlay.activity.thinking"))
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

    // MARK: - Concise cursor chips (messenger UX)

    @Test func conciseChipsShowBashTitleOnlyAndHideUntitledCommands() {
        let titled = concise(.init(kind: .tool, toolCallId: "b1", toolName: "bash", status: "running",
                                   argsPreview: #"{"command":"rg -n label","title":"오버레이 라벨 찾기"}"#))
        #expect(titled.map(\.label) == ["오버레이 라벨 찾기"])
        #expect(titled.first?.detail == nil)

        let untitled = concise(.init(kind: .tool, toolCallId: "b2", toolName: "bash", status: "running",
                                     argsPreview: #"{"command":"git log --oneline -5"}"#))
        #expect(untitled.map(\.label) == [L10n.t("hud.liveStep.working")])
        #expect(untitled.contains { ($0.detail ?? "").contains("git") } == false)
    }

    @Test func conciseChipsNeverShowThinkingText() {
        let models = concise(.init(kind: .thinking, thinkingPreview: "The user wants the pricing header translated"))
        #expect(models.map(\.label) == [L10n.t("overlay.activity.thinking")])
        #expect(models.first?.detail == nil)
    }

    @Test func conciseChipsHideRawToolsButKeepMemoryWebSearchAndMcpServer() {
        // A finished hidden tool keeps the neutral chip until the turn clears the stack.
        #expect(concise(.init(kind: .tool, toolCallId: "r", toolName: "read", status: "completed",
                              argsPreview: #"{"path":"/repo/a.swift"}"#)).map(\.label) == [L10n.t("hud.liveStep.working")])
        #expect(PickyMainActivityConcisePolicy.models(for: []).isEmpty)
        #expect(concise(.init(kind: .tool, toolCallId: "m", toolName: "recall", status: "running",
                              argsPreview: #"{"query":"메신저 디자인"}"#)).map(\.detail) == ["메신저 디자인"])
        // memory-layer 0.6+ and vcc-ko 0.2+ renamed their tools; both generations stay memory chips.
        for (name, label) in [("memory_recall", "overlay.activity.memory.recall"), ("session_recall", "overlay.activity.memory.recall"),
                              ("memory_remember", "overlay.activity.memory.remember"), ("memory_forget", "overlay.activity.memory.forget")] {
            #expect(concise(.init(kind: .tool, toolCallId: "m", toolName: name, status: "running",
                                  argsPreview: #"{"query":"q","title":"t"}"#)).map(\.label) == [L10n.t(label)], "\(name)")
        }
        let web = concise(.init(kind: .tool, toolCallId: "w", toolName: "web_search", status: "running",
                                argsPreview: #"{"queries":["SwiftUI TimelineView"]}"#))
        #expect(web.map(\.label) == [L10n.t("overlay.activity.webSearch")])
        #expect(web.map(\.detail) == ["SwiftUI TimelineView"])

        let direct = concise(.init(kind: .tool, toolCallId: "d", toolName: "mcp__creatrip__jira_search", status: "running",
                                   argsPreview: #"{"jql":"project = PK"}"#))
        let viaCodemode = concise(.init(kind: .tool, toolCallId: "c", toolName: "codemode", status: "running",
                                        argsPreview: #"{"code":"await tools.mcp__creatrip__jira_search({})"}"#))
        let expected = L10n.t("overlay.activity.mcp", "creatrip")
        #expect(direct.map(\.label) == [expected])
        #expect(viaCodemode.map(\.label) == [expected])
        #expect(direct.first?.detail == nil)
    }

    private func concise(_ activity: PickyMainActivity) -> [PickyMainActivityChipModel] {
        PickyMainActivityConcisePolicy.models(for: [activity])
    }

    private func tool(id: String, status: String) -> PickyMainActivity {
        PickyMainActivity(kind: .tool, toolCallId: id, toolName: "read", status: status)
    }
}
