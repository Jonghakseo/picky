//
//  PickySessionProgressProjectionTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySessionProgressProjectionTests {
    @Test func projectionShowsLatestRunningWorkAndNewestMeaningfulEntries() {
        let projection = PickySessionProgressProjection.project(tools: [
            tool("read", name: "read", status: "succeeded"),
            tool("edit", name: "edit", status: "succeeded", args: #"{"path":"Sources/Old.swift"}"#),
            tool("bash", name: "bash", status: "running", args: #"{"command":"pnpm test"}"#),
        ], sessionStatus: .running)

        #expect(projection.header.state == .running(PickyToolHistoryRenderer.entry(from: tool("bash", name: "bash", status: "running", args: #"{"command":"pnpm test"}"#), index: 3)))
        #expect(projection.keyItems.map(\.id) == ["bash", "edit", "investigation-summary"])
        #expect(projection.rawDetailCount == 3)
    }

    @Test func projectionUsesAuthoritativeSessionStatusWhenNoToolIsRunning() {
        let working = PickySessionProgressProjection.project(tools: [], sessionStatus: .running)
        let waiting = PickySessionProgressProjection.project(tools: [], sessionStatus: .waiting_for_input)
        let failed = PickySessionProgressProjection.project(tools: [], sessionStatus: .failed)
        let completed = PickySessionProgressProjection.project(tools: [], sessionStatus: .completed)

        #expect(working.header.state == .working)
        #expect(waiting.header.state == .waitingForInput)
        #expect(failed.header.state == .failed)
        #expect(completed.header.state == .completed)
        #expect(waiting.header.accessibilityLabelKey == "hud.progress.current")
        #expect(waiting.header.accessibilityValueKey == "hud.progress.status.needsInput")
        #expect(failed.header.accessibilityValueKey == "hud.progress.status.failed")
        #expect(completed.header.accessibilityLabelKey == "hud.progress.recent")
        #expect(completed.header.accessibilityValueKey == "hud.progress.status.succeeded")
    }

    @Test func projectionCollapsesOnlySuccessfulReadOnlyInvestigation() {
        let projection = PickySessionProgressProjection.project(tools: [
            tool("read", name: "read", status: "succeeded"),
            tool("safe-search", name: "bash", status: "succeeded", args: #"{"command":"rg Picky HUD"}"#),
            tool("delete", name: "bash", status: "succeeded", args: #"{"command":"find . -delete"}"#),
            tool("chain", name: "bash", status: "succeeded", args: #"{"command":"grep x && rm y"}"#),
            tool("pipe", name: "bash", status: "succeeded", args: #"{"command":"rg x | xargs sed -i '' -e 's/x/y/'"}"#),
            tool("failed-read", name: "read", status: "failed"),
            tool("running-search", name: "bash", status: "running", args: #"{"command":"rg waiting"}"#),
        ])

        #expect(projection.keyItems.map(\.id) == ["running-search", "failed-read", "pipe", "chain", "delete", "investigation-summary"])
        guard case let .investigation(count) = projection.keyItems.last else {
            Issue.record("Expected collapsed investigation summary")
            return
        }
        #expect(count == 2)
    }

    @Test func allSuccessfulInvestigationRemainsVisibleAsOneSummary() {
        let projection = PickySessionProgressProjection.project(tools: [
            tool("read", name: "read", status: "succeeded"),
            tool("search", name: "bash", status: "succeeded", args: #"{"command":"grep Picky README.md"}"#),
        ])

        #expect(projection.keyItems == [.investigation(count: 2)])
        #expect(projection.rawDetailCount == 2)
    }

    @Test func projectionRecognizesSingleSubagentRunAndCountsUniqueAgents() {
        let projection = PickySessionProgressProjection.project(tools: [
            tool("worker-first", name: "subagent", status: "succeeded", args: #"{"command":"subagent run worker -- -- inspect the issue"}"#),
            tool("worker-second", name: "subagent", status: "succeeded", args: #"{"command":"subagent run worker -- -- verify the issue"}"#),
            tool(
                "batch",
                name: "subagent",
                status: "succeeded",
                subagentSummary: .init(action: "batch", agents: ["verifier", "reviewer", "challenger"])
            ),
            tool("write-a", name: "write", status: "succeeded", args: #"{"path":"reports/summary.md"}"#),
            tool("edit-same", name: "edit", status: "succeeded", args: #"{"path":"reports/summary.md"}"#),
            tool("control", name: "subagent", status: "succeeded", args: #"{"command":"subagent status"}"#),
            tool("bash", name: "bash", status: "failed", args: #"{"command":"pnpm test"}"#),
        ])

        #expect(projection.summary == PickySessionProgressSummary(changedFileCount: 1, commandCount: 1, agentCount: 4))
        #expect(projection.keyItems.contains(where: { $0.id == "worker-first" }))
        #expect(projection.keyItems.contains(where: { $0.id == "batch" }))
    }

    @Test func projectionLimitsKeyProgressToNewestTwelveItemsAndKeepsRawDetails() {
        let tools = (0..<15).map { index in
            tool("edit-\(index)", name: "edit", status: "succeeded", args: #"{"path":"Sources/\#(index).swift"}"#)
        }
        let projection = PickySessionProgressProjection.project(tools: tools)

        #expect(projection.keyItems.map(\.id) == (3..<15).reversed().map { "edit-\($0)" })
        #expect(projection.hiddenKeyItemCount == 3)
        #expect(projection.rawDetailCount == 15)
    }

    @Test func projectionHasAnEmptyKeyListForNoToolHistory() {
        let projection = PickySessionProgressProjection.project(tools: [])

        #expect(projection.header.state == .completed)
        #expect(projection.keyItems.isEmpty)
        #expect(projection.rawDetailCount == 0)
    }

    private func tool(
        _ id: String,
        name: String,
        status: String,
        args: String? = nil,
        subagentSummary: PickySubagentToolSummary? = nil
    ) -> PickyToolActivity {
        PickyToolActivity(
            toolCallId: id,
            name: name,
            status: status,
            argsPreview: args,
            subagentSummary: subagentSummary,
            startedAt: Date(timeIntervalSince1970: Double(id.count))
        )
    }
}
