//
//  PickySubagentProgressPresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySubagentProgressPresentationTests {
    @Test func mergesPlannedChainStepsWithSpawnedRunsInOrder() throws {
        let presentation = try #require(makePresentation(
            action: .chain,
            planned: [plan("worker", "Implement"), plan("verifier", "Verify"), plan("reviewer", "Review")],
            runs: [run(8, agent: "worker", status: .done), run(9, agent: "verifier", status: .running)]
        ))

        #expect(presentation.headerLabel == "chain 2/3")
        #expect(presentation.chainAgentsText == "worker → verifier → reviewer")
        #expect(presentation.rows.map(\.status) == [.done, .running, .pending])
        #expect(presentation.rows.last?.displayTask == "Review")
        #expect(!presentation.isComplete)
    }

    @Test func collapsesOnlyAfterEveryPlannedRunSettles() throws {
        let invocation = PickySubagentInvocation(invocationId: "call-1", action: .batch, planned: [plan("worker", "Implement"), plan("reviewer", "Review")])
        let previous = try #require(PickySubagentInvocationPresentation(
            invocation: invocation,
            runs: [run(1, agent: "worker", status: .done), run(2, agent: "reviewer", status: .running)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
        let current = try #require(PickySubagentInvocationPresentation(
            invocation: invocation,
            runs: [run(1, agent: "worker", status: .done), run(2, agent: "reviewer", status: .error)],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))

        #expect(current.statusText == L10n.t("hud.subagent.pill.failed", Int64(1), Int64(1), Int64(2)))
        #expect(current.isComplete)
        #expect(PickySubagentInvocationExpansionPolicy.shouldCollapse(previousIsComplete: previous.isComplete, currentIsComplete: current.isComplete))
        #expect(!PickySubagentInvocationExpansionPolicy.isExpanded(savedValue: nil, isComplete: current.isComplete))
    }

    @Test func presentsOneCurrentActivityWithoutRepeatingStaleToolMetadata() throws {
        let usage = PickyContextUsage(tokens: 84_000, contextWindow: 200_000, percent: 42)
        let active = run(
            1,
            agent: "worker",
            status: .running,
            activity: .init(toolName: "bash", toolCallCount: 12, lastLine: "→ read ~/project/AGENTS.md", contextUsage: usage)
        )
        let presentation = try #require(makePresentation(action: .run, planned: [plan("worker", "Implement")], runs: [active]))
        let row = presentation.rows[0]

        #expect(presentation.activityText(for: row) == "read ~/project/AGENTS.md")
        #expect(presentation.toolCountText(for: row) == "12 tools")
        #expect(presentation.contextUsage(for: row) == usage)

        let done = try #require(PickySubagentInvocationPresentation(
            invocation: presentation.invocation,
            runs: [run(1, agent: "worker", status: .done, activity: active.lastActivity)],
            createdAt: Date()
        ))
        #expect(done.activityText(for: done.rows[0]) == nil)
        #expect(done.toolCountText(for: done.rows[0]) == nil)
        #expect(done.contextUsage(for: done.rows[0]) == usage)
    }

    @Test func fallsBackToTheStructuredToolWhenNoActivityPreviewExists() throws {
        let active = run(1, agent: "worker", status: .running, activity: .init(toolName: "grep", toolCallCount: 7))
        let presentation = try #require(makePresentation(action: .run, planned: [plan("worker", "Inspect")], runs: [active]))

        #expect(presentation.activityText(for: presentation.rows[0]) == "grep")
    }

    @Test func showsToolCountWhenActivityHasNoText() throws {
        let active = run(1, agent: "worker", status: .running, activity: .init(toolCallCount: 7))
        let presentation = try #require(makePresentation(action: .run, planned: [plan("worker", "Inspect")], runs: [active]))
        let row = presentation.rows[0]

        #expect(presentation.activityText(for: row) == nil)
        #expect(presentation.toolCountText(for: row) == "7 tools")
        #expect(presentation.hasActivityRowContent(for: row))
    }

    @Test func showsResponsePreviewOnlyAfterRunSettles() throws {
        let response = "# Result\n\nImplemented the presentation."
        let running = try #require(makePresentation(
            action: .run,
            planned: [plan("worker", "Implement the presentation")],
            runs: [run(1, agent: "worker", status: .running, resultPreview: response, resultText: response)]
        ))
        let done = try #require(makePresentation(
            action: .run,
            planned: [plan("worker", "Implement the presentation")],
            runs: [run(1, agent: "worker", status: .done, resultPreview: response, resultText: response)]
        ))
        let doneWithoutResponse = try #require(makePresentation(
            action: .run,
            planned: [plan("worker", "Implement the presentation")],
            runs: [run(1, agent: "worker", status: .done)]
        ))

        #expect(running.rows[0].displayText == "Implement the presentation")
        #expect(done.rows[0].displayText == "# Result Implemented the presentation.")
        #expect(done.rows[0].hasResponseText)
        #expect(doneWithoutResponse.rows[0].displayText == "Implement the presentation")
        #expect(!doneWithoutResponse.rows[0].hasResponseText)
    }

    @Test func decodesInvocationMessageAndOptionalRunFields() throws {
        let data = Data("""
        {"id":"session-1","title":"Pickle","status":"running","createdAt":"2026-07-14T01:00:00.000Z","updatedAt":"2026-07-14T01:00:00.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"subagentRuns":[{"runId":1,"agent":"worker","task":"Inspect","status":"running","resultText":"# Findings\\n- Result","invocationId":"tool-1","lastActivity":{"toolName":"read","toolCallCount":2,"lastLine":"opened file","contextUsage":{"tokens":84000,"contextWindow":200000,"percent":42}}}],"messages":[{"id":"invocation-1","kind":"subagent_invocation","createdAt":"2026-07-14T01:00:00.000Z","subagentInvocation":{"invocationId":"tool-1","action":"run","planned":[{"agent":"worker","task":"Inspect"}],"completed":true}}]}
        """.utf8)
        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: data)

        #expect(session.subagentRuns.first?.invocationId == "tool-1")
        #expect(session.subagentRuns.first?.resultText == "# Findings\n- Result")
        #expect(session.subagentRuns.first?.lastActivity?.toolCallCount == 2)
        #expect(session.subagentRuns.first?.lastActivity?.contextUsage?.percent == 42)
        #expect(session.messages.first?.kind == .subagentInvocation)
        #expect(session.messages.first?.subagentInvocation?.planned.first?.agent == "worker")
        #expect(session.messages.first?.subagentInvocation?.completed == true)
    }

    @Test func marksUnspawnedPlansAsFailedAfterInvocationCompletes() throws {
        let presentation = try #require(makePresentation(
            action: .batch,
            planned: [plan("worker", "Implement")],
            runs: [],
            completed: true
        ))

        #expect(presentation.rows.map(\.status) == [.error])
        #expect(presentation.isComplete)
        #expect(presentation.elapsedText(now: Date(timeIntervalSince1970: 1_800_000_000)).isEmpty)
    }

    @Test func completedInvocationUsesRecordedElapsedEvenWhenLateRunIsStillRunning() throws {
        let presentation = try #require(makePresentation(
            action: .run,
            planned: [plan("worker", "Implement")],
            runs: [run(1, agent: "worker", status: .running)],
            completed: true
        ))

        #expect(presentation.isComplete)
        #expect(presentation.elapsedText(now: Date(timeIntervalSince1970: 1_800_000_000)) == "1s")
    }

    @Test func collapsedHeaderUsesCompletionOutcomeDespiteStaleRunningRows() throws {
        let succeeded = try #require(makePresentation(
            action: .run,
            planned: [plan("worker", "Implement")],
            runs: [run(1, agent: "worker", status: .running)],
            completed: true
        ))
        let failed = try #require(makePresentation(
            action: .batch,
            planned: [plan("worker", "Implement"), plan("reviewer", "Review")],
            runs: [
                run(1, agent: "worker", status: .error),
                run(2, agent: "reviewer", status: .running)
            ],
            completed: true
        ))

        #expect(succeeded.tone == .running)
        #expect(succeeded.collapsedTone == .success)
        #expect(succeeded.collapsedText == L10n.t("hud.subagent.pill.done.one"))
        #expect(failed.collapsedTone == .error)
        #expect(failed.collapsedText == L10n.t("hud.subagent.pill.failed", Int64(1), Int64(1), Int64(2)))
    }

    @Test func decodesUnknownSubagentInvocationActionsAsRun() throws {
        let data = Data("""
        {"id":"session-1","title":"Pickle","status":"running","createdAt":"2026-07-14T01:00:00.000Z","updatedAt":"2026-07-14T01:00:00.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"messages":[{"id":"invocation-1","kind":"subagent_invocation","createdAt":"2026-07-14T01:00:00.000Z","subagentInvocation":{"invocationId":"tool-1","action":"future_action","planned":[]}}]}
        """.utf8)

        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: data)

        #expect(session.messages.first?.subagentInvocation?.action == .run)
    }

    @Test func decodesUnknownMessageKindsWithoutDroppingTheSession() throws {
        let data = Data("""
        {"id":"session-1","title":"Pickle","status":"running","createdAt":"2026-07-14T01:00:00.000Z","updatedAt":"2026-07-14T01:00:00.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"messages":[{"id":"future","kind":"future_kind","createdAt":"2026-07-14T01:00:00.000Z"}]}
        """.utf8)
        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: data)
        #expect(session.messages.first?.kind == .system)
    }

    private func makePresentation(
        action: PickySubagentInvocationAction,
        planned: [PickySubagentInvocationPlan],
        runs: [PickySubagentRun],
        completed: Bool? = nil
    ) -> PickySubagentInvocationPresentation? {
        PickySubagentInvocationPresentation(
            invocation: .init(invocationId: "call-1", action: action, planned: planned, completed: completed),
            runs: runs,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    private func plan(_ agent: String, _ task: String) -> PickySubagentInvocationPlan {
        .init(agent: agent, task: task)
    }

    private func run(
        _ id: Int,
        agent: String,
        status: PickySubagentRunStatus,
        activity: PickySubagentLastActivity? = nil,
        resultPreview: String? = nil,
        resultText: String? = nil
    ) -> PickySubagentRun {
        PickySubagentRun(
            runId: id,
            agent: agent,
            task: "Task \(id)",
            displayTask: nil,
            status: status,
            errorClass: nil,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            elapsedMs: 1_000,
            batchId: nil,
            pipelineId: nil,
            pipelineStepIndex: nil,
            resultPreview: resultPreview,
            resultText: resultText,
            model: nil,
            invocationId: "call-1",
            lastActivity: activity
        )
    }
}
