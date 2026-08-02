//
//  PickySubagentProgressPresentationTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickySubagentProgressPresentationTests {
    @Test func projectsRunningAndSettledCountsWithErrorTone() throws {
        let presentation = try #require(PickySubagentProgressPresentation(runs: [
            run(2, status: .running),
            run(1, status: .error, batchID: "batch-a"),
            run(3, status: .done, batchID: "batch-a"),
        ]))

        #expect(presentation.pillText == "1 agents · 2/3")
        #expect(presentation.headerText == "1 agents running · 2/3 done")
        #expect(presentation.tone == .error)
        #expect(presentation.groups.map(\.runs.count) == [1, 2])
    }

    @Test func formatsLiveAndCompletedElapsedDurations() throws {
        let presentation = try #require(PickySubagentProgressPresentation(runs: [run(1, status: .running)]))
        let completed = run(2, status: .done, elapsedMs: 154_000)
        #expect(presentation.elapsedText(for: completed) == "2m 34s")
    }

    @Test func decodesSubagentRunsFromSessionAndSlimUpdate() throws {
        let sessionData = Data("""
        {"id":"session-1","title":"Pickle","status":"running","createdAt":"2026-07-14T01:00:00.000Z","updatedAt":"2026-07-14T01:00:00.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[],"subagentRuns":[{"runId":1,"agent":"worker","task":"Inspect","status":"running"}]}
        """.utf8)
        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: sessionData)
        #expect(session.subagentRuns.first?.agent == "worker")

        let eventData = Data("""
        {"id":"event-1","protocolVersion":"2026-07-23","timestamp":"2026-07-14T01:00:00.000Z","type":"sessionSubagentRunsUpdated","sessionId":"session-1","runs":[{"runId":1,"agent":"worker","task":"Inspect","status":"done"}],"seq":4}
        """.utf8)
        let event = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: eventData)
        guard case .sessionSubagentRunsUpdated(_, let runs, let seq) = event.event else {
            Issue.record("Expected subagent runs update")
            return
        }
        #expect(runs.first?.status == .done)
        #expect(seq == 4)
    }

    @MainActor @Test func appliesSlimRunUpdateAndTracksInlineExpansion() throws {
        let viewModel = PickySessionListViewModel(client: FakePickyAgentClient(), notificationCenter: PickyNoopNotificationCenter())
        let sessionData = Data("""
        {"id":"session-1","title":"Pickle","status":"running","createdAt":"2026-07-14T01:00:00.000Z","updatedAt":"2026-07-14T01:00:00.000Z","logs":[],"tools":[],"artifacts":[],"changedFiles":[]}
        """.utf8)
        let session = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyAgentSession.self, from: sessionData)
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "session", protocolVersion: "2026-07-23", timestamp: Date(), event: .sessionUpdated(session))))

        let runs = [run(1, status: .running)]
        viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "runs", protocolVersion: "2026-07-23", timestamp: Date(), event: .sessionSubagentRunsUpdated(sessionId: "session-1", runs: runs, seq: 1))))
        #expect(viewModel.sessions.first?.subagentRuns == runs)
        #expect(viewModel.isSubagentProgressExpanded(sessionID: "session-1", isComplete: false))
        viewModel.toggleSubagentRunExpanded(1, sessionID: "session-1")
        #expect(viewModel.isSubagentRunExpanded(1, sessionID: "session-1"))
    }

    private func run(_ id: Int, status: PickySubagentRunStatus, batchID: String? = nil, elapsedMs: Double? = nil) -> PickySubagentRun {
        PickySubagentRun(runId: id, agent: "worker", task: "Task \(id)", displayTask: nil, status: status, errorClass: nil, startedAt: Date(timeIntervalSince1970: 1_700_000_000), elapsedMs: elapsedMs, batchId: batchID, pipelineId: nil, pipelineStepIndex: nil, resultPreview: nil, model: nil)
    }
}
