//
//  PickyMainTaskTests.swift
//  PickyTests
//
//  Contracts for the main-agent Task surface: the wire snapshot the daemon
//  broadcasts, the two user controls the app sends back, what the Tasks section
//  decides to show, and how the store applies and reports them.
//

import Foundation
import Testing
@testable import Picky

struct PickyMainTaskProtocolTests {
    @Test func decodesMainTasksUpdatedSnapshotFromTheDaemonFixture() throws {
        let event = try decodeMainTasksUpdatedEvent(from: mainTasksFixtureData())
        #expect(event.tasks.count == 3)
        #expect(event.decisions.count == 2)

        let running = try #require(event.tasks.first)
        #expect(running.status == .running)
        #expect(running.revision == 2)
        #expect(running.canStop)
        #expect(running.canResume == false)
        #expect(running.instructions.count == 2)
        #expect(running.revisionStartedAt != nil)
        #expect(running.tier == .fast)

        let blocked = try #require(event.tasks.first { $0.status == .blocked })
        let report = try #require(blocked.report)
        #expect(report.status == .blocked)
        #expect(report.escalation == .productionCode)
        #expect(report.blockers.count == 1)
        #expect(blocked.handoff?.decisionId == "delegation-1c2d3e4f-5a6b-4c7d-8e9f-0a1b2c3d4e5f")
        #expect(blocked.handoff?.pickleSessionId == "pickle-session-42")

        let cancelled = try #require(event.tasks.first { $0.status == .cancelled })
        #expect(cancelled.cleanup == .uncertain)
        #expect(cancelled.readonly)

        let pending = try #require(event.decisions.first { $0.state == .pending })
        #expect(pending.question == "Should a Pickle handle this?")
        #expect(pending.pickle == nil)
        let delegated = try #require(event.decisions.first { $0.state == .pickle })
        #expect(delegated.pickle?.state == .created)
        #expect(delegated.fromTaskId == "task-0a1b2c3d-4e5f-4a6b-8c9d-0e1f2a3b4c5d")
    }

    /// A status a newer daemon adds must not drop the Tasks the app does know.
    @Test func keepsTheSnapshotWhenTheDaemonReportsAnUnknownState() throws {
        var object = try #require(try JSONSerialization.jsonObject(with: mainTasksFixtureData()) as? [String: Any])
        var tasks = try #require(object["tasks"] as? [[String: Any]])
        tasks[0]["status"] = "teleporting"
        tasks[0]["tier"] = "quantum"
        var decisions = try #require(object["decisions"] as? [[String: Any]])
        decisions[0]["state"] = "deliberating"
        object["tasks"] = tasks
        object["decisions"] = decisions

        let event = try decodeMainTasksUpdatedEvent(from: JSONSerialization.data(withJSONObject: object))
        #expect(event.tasks.count == 3)
        #expect(event.tasks[0].status == .unknown)
        #expect(event.tasks[0].tier == .unknown)
        #expect(event.decisions[0].state == .unknown)
        #expect(event.tasks[1].status == .blocked)
    }

    @Test func controlAndDelegationCommandsRoundTripOverTheWire() throws {
        let decoder = JSONDecoder.pickyAgentProtocolDecoder()
        let control = try decoder.decode(PickyCommandEnvelope.self, from: fixtureData("control-main-task.request.json"))
        #expect(control.type == .controlMainTask)
        #expect(control.taskId == "task-7f3c2a10-1b2c-4d5e-8f90-123456789abc")
        #expect(control.action == .stop)
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: JSONEncoder().encode(control)) == control)

        let resolve = try decoder.decode(PickyCommandEnvelope.self, from: fixtureData("resolve-main-delegation.request.json"))
        #expect(resolve.type == .resolveMainDelegation)
        #expect(resolve.decisionId == "delegation-5d2e8c1a-0f3b-4a6d-9c7e-abcdef012345")
        #expect(resolve.choice == .task)
        #expect(try decoder.decode(PickyCommandEnvelope.self, from: JSONEncoder().encode(resolve)) == resolve)
    }

    /// The app's own builders have to produce the exact keys the fixtures carry.
    @Test func commandBuildersMatchTheFixturePayloads() throws {
        let built = PickyCommandEnvelope.controlMainTask(taskId: "task-1", action: .resume)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(built)) as? [String: Any])
        #expect(object["type"] as? String == "controlMainTask")
        #expect(object["taskId"] as? String == "task-1")
        #expect(object["action"] as? String == "resume")

        let resolved = PickyCommandEnvelope.resolveMainDelegation(decisionId: "decision-1", choice: .pickle)
        let resolvedObject = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(resolved)) as? [String: Any])
        #expect(resolvedObject["type"] as? String == "resolveMainDelegation")
        #expect(resolvedObject["decisionId"] as? String == "decision-1")
        #expect(resolvedObject["choice"] as? String == "pickle")
    }
}

struct PickyMainTaskPresentationTests {
    @Test func collapsesTheWorkingStatusesIntoOneState() {
        for status in [PickyMainTaskStatus.evaluating, .running, .waiting] {
            #expect(PickyMainTaskPresentation.displayState(for: status) == .working)
        }
        #expect(PickyMainTaskPresentation.displayState(for: .queued) == .queued)
        #expect(PickyMainTaskPresentation.displayState(for: .cancelled) == .cancelled)
        #expect(PickyMainTaskPresentation.displayState(for: .unknown) == .unknown)
    }

    @Test func offersOnlyTheControlsTheDaemonAllows() throws {
        let stoppable = makeTask(id: "a", status: .running, canStop: true, canResume: false)
        let resumable = makeTask(id: "b", status: .interrupted, canStop: false, canResume: true)
        let rows = PickyMainTaskPresentation.rows(for: [stoppable, resumable])
        let stoppableRow = try #require(rows.first { $0.id == "a" })
        let resumableRow = try #require(rows.first { $0.id == "b" })
        #expect(stoppableRow.showsStop)
        #expect(stoppableRow.showsResume == false)
        #expect(resumableRow.showsResume)
        #expect(resumableRow.showsStop == false)
    }

    @Test func runsTheElapsedClockOnlyWhileTheTaskIsWorking() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let working = makeTask(id: "a", status: .waiting, revisionStartedAt: start)
        let finished = makeTask(id: "b", status: .completed, revisionStartedAt: start)
        let rows = PickyMainTaskPresentation.rows(for: [working, finished])
        #expect(rows.first { $0.id == "a" }?.elapsedSince == start)
        #expect(rows.first { $0.id == "b" }?.elapsedSince == nil)
        #expect(PickyMainTaskPresentation.elapsedText(since: start, now: start.addingTimeInterval(65)) == "1:05")
        #expect(PickyMainTaskPresentation.elapsedText(since: start, now: start.addingTimeInterval(3725)) == "1:02:05")
        #expect(PickyMainTaskPresentation.elapsedText(since: start, now: start.addingTimeInterval(-10)) == "0:00")
    }

    @Test func saysSoWhenAStoppedTaskCouldNotBeConfirmedCleanedUp() {
        let uncertain = makeTask(id: "a", status: .cancelled, cleanup: .uncertain)
        let confirmed = makeTask(id: "b", status: .cancelled, cleanup: .confirmed)
        let rows = PickyMainTaskPresentation.rows(for: [uncertain, confirmed])
        #expect(rows.first { $0.id == "a" }?.noteKey == "hub.tasks.note.cleanupUncertain")
        #expect(rows.first { $0.id == "b" }?.noteKey == nil)
    }

    @Test func putsActionableTasksFirstAndKeepsOnlyRecentFinishedOnes() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var tasks: [PickyMainTask] = []
        for index in 0..<12 {
            tasks.append(makeTask(id: "done-\(index)", status: .completed, updatedAt: base.addingTimeInterval(Double(index))))
        }
        tasks.append(makeTask(id: "running", status: .running, updatedAt: base))
        tasks.append(makeTask(id: "blocked", status: .blocked, updatedAt: base))

        let rows = PickyMainTaskPresentation.rows(for: tasks)
        #expect(Array(rows.map(\.id).prefix(2)) == ["blocked", "running"])
        let finished = rows.filter { $0.state.isFinished }
        // The blocked row and history share one cap; live work is never trimmed.
        #expect(finished.count == PickyMainTaskPresentation.finishedTaskLimit - 1)
        // Newest first, so the oldest completions fall off rather than the newest.
        #expect(finished.first?.id == "done-11")
        #expect(rows.contains { $0.id == "done-5" })
        #expect(rows.contains { $0.id == "done-4" } == false)
    }

    @Test func asksTheUserOnlyWhileTheDecisionIsPending() {
        let pending = makeDecision(id: "p", state: .pending)
        let chosenTask = makeDecision(id: "t", state: .task)
        let cancelled = makeDecision(id: "c", state: .cancelled)
        let rows = PickyMainTaskPresentation.delegationRows(for: [pending, chosenTask, cancelled], tasks: [])
        #expect(rows.map(\.id) == ["p"])
        #expect(rows[0].kind == .pending)
        #expect(rows[0].showsChoices)
        #expect(rows[0].showsRetry == false)
    }

    @Test func showsProgressWhileCreatingAPickleAndARetryWhenItFails() throws {
        let creating = makeDecision(id: "a", state: .pickle, pickle: .init(state: .creating, sessionId: nil, error: nil))
        let failed = makeDecision(id: "b", state: .pickle, pickle: .init(state: .failed, sessionId: nil, error: "No worktree"))
        let rows = PickyMainTaskPresentation.delegationRows(for: [creating, failed], tasks: [])
        let creatingRow = try #require(rows.first { $0.id == "a" })
        let failedRow = try #require(rows.first { $0.id == "b" })
        #expect(creatingRow.isBusy)
        #expect(creatingRow.showsChoices == false)
        #expect(failedRow.showsRetry)
        #expect(failedRow.showsChoices == false)
        #expect(failedRow.messageKey == "hub.tasks.decision.failed")
    }

    /// The same handoff must not be stated by both a Task row and a decision row.
    @Test func dropsACreatedPickleRowWhenATaskAlreadyReportsThatHandoff() {
        let decision = makeDecision(id: "d", state: .pickle, pickle: .init(state: .created, sessionId: "s-1", error: nil))
        let handedOff = makeTask(id: "t", status: .blocked, handoff: .init(decisionId: "d", pickleSessionId: "s-1"))
        #expect(PickyMainTaskPresentation.delegationRows(for: [decision], tasks: [handedOff]).isEmpty)
        #expect(PickyMainTaskPresentation.delegationRows(for: [decision], tasks: []).map(\.kind) == [.pickleCreated])
        let rows = PickyMainTaskPresentation.rows(for: [handedOff])
        #expect(rows.first?.noteKey == "hub.tasks.note.handoff")
        // Taken over by a Pickle, the Task is history rather than something to act on.
        #expect(rows.first?.state == .handedOff)
        #expect(rows.first?.state.isFinished == true)
    }

    @Test func capsTasksWaitingOnTheUserTogetherWithHistory() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        var tasks: [PickyMainTask] = []
        for index in 0..<10 {
            tasks.append(makeTask(id: "interrupted-\(index)", status: .interrupted, updatedAt: base.addingTimeInterval(Double(index))))
        }
        tasks.append(makeTask(id: "running", status: .running, updatedAt: base))
        let rows = PickyMainTaskPresentation.rows(for: tasks)
        #expect(rows.contains { $0.id == "running" })
        #expect(rows.filter { $0.state == .interrupted }.count == PickyMainTaskPresentation.finishedTaskLimit)
        #expect(rows.first?.id == "interrupted-9")
    }

    @Test func listsPendingDecisionsBeforeInformationalOnes() {
        let base = Date(timeIntervalSince1970: 1_000_000)
        let created = makeDecision(id: "created", state: .pickle, updatedAt: base.addingTimeInterval(60), pickle: .init(state: .created, sessionId: nil, error: nil))
        let pending = makeDecision(id: "pending", state: .pending, updatedAt: base)
        let rows = PickyMainTaskPresentation.delegationRows(for: [created, pending], tasks: [])
        #expect(rows.map(\.id) == ["pending", "created"])
    }
}

@MainActor
struct PickyMainTaskStoreTests {
    @Test func replacesTheSnapshotWithEveryDaemonBroadcast() throws {
        let store = PickyMainTaskStore()
        #expect(store.snapshot.tasks.isEmpty)
        store.apply(try decodeMainTasksUpdatedEvent(from: mainTasksFixtureData()))
        #expect(store.snapshot.tasks.count == 3)
        #expect(store.snapshot.decisions.count == 2)

        store.apply(PickyMainTasksSnapshot(tasks: [makeTask(id: "only", status: .queued)], decisions: []))
        #expect(store.snapshot.tasks.map(\.id) == ["only"])
        #expect(store.snapshot.decisions.isEmpty)
    }

    @Test func sendsTheControlCommandsTheUserPicked() async {
        let store = PickyMainTaskStore()
        let recorder = CommandRecorder()
        store.send = { command in recorder.sent.append(command); return nil }

        await store.control(taskID: "task-1", action: .stop)
        await store.resolve(decisionID: "decision-1", choice: .pickle)

        #expect(recorder.sent.map(\.type) == [.controlMainTask, .resolveMainDelegation])
        #expect(recorder.sent[0].taskId == "task-1")
        #expect(recorder.sent[0].action == .stop)
        #expect(recorder.sent[1].decisionId == "decision-1")
        #expect(recorder.sent[1].choice == .pickle)
        #expect(store.commandError == nil)
        #expect(store.pendingCommandIDs.isEmpty)
    }

    @Test func surfacesADaemonRejectionInsteadOfLookingLikeItWorked() async {
        let store = PickyMainTaskStore()
        store.send = { _ in PickyErrorEvent(code: "unknown_task", message: "Unknown task", commandId: nil) }

        await store.control(taskID: "task-1", action: .resume)
        #expect(store.commandError == "Unknown task")
        #expect(store.pendingCommandIDs.isEmpty)

        store.clearCommandError()
        #expect(store.commandError == nil)
    }

    @Test func reportsATransportFailureAsAFailedCommand() async {
        let store = PickyMainTaskStore()
        store.send = { _ -> PickyErrorEvent? in throw PickyAgentClientError.disconnected }

        await store.control(taskID: "task-1", action: .stop)
        #expect(store.commandError == L10n.t("hub.tasks.error.commandFailed"))
    }

    /// A Task state change arrives only from the daemon, so a second click
    /// while the first command is still open must not send a duplicate.
    @Test func doesNotSendASecondCommandForATaskThatIsStillWaiting() async {
        let store = PickyMainTaskStore()
        let recorder = CommandRecorder()
        let gate = CommandGate()
        store.send = { command in
            recorder.sent.append(command)
            await gate.wait()
            return nil
        }

        async let first: Void = store.control(taskID: "task-1", action: .stop)
        while store.pendingCommandIDs.isEmpty { await Task.yield() }
        await store.control(taskID: "task-1", action: .stop)
        #expect(recorder.sent.count == 1)

        gate.open()
        await first
        #expect(recorder.sent.count == 1)
        #expect(store.pendingCommandIDs.isEmpty)
        await store.control(taskID: "task-1", action: .stop)
        #expect(recorder.sent.count == 2)
    }
}

// MARK: - Helpers

@MainActor
private final class CommandRecorder {
    var sent: [PickyCommandEnvelope] = []
}

@MainActor
private final class CommandGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        isOpen = true
        let pending = continuations
        continuations = []
        for continuation in pending { continuation.resume() }
    }
}

private func fixtureData(_ name: String) throws -> Data {
    guard let url = try fixtureURLs(in: "contracts/protocol").first(where: { $0.lastPathComponent == name }) else {
        throw MainTaskFixtureError.missingFixture(name)
    }
    return try Data(contentsOf: url)
}

private func mainTasksFixtureData() throws -> Data {
    try fixtureData("main-tasks-updated.event.json")
}

/// Decodes through the real event envelope so the test also proves the
/// `mainTasksUpdated` type is wired into `PickyEvent`'s decoder.
private func decodeMainTasksUpdatedEvent(from data: Data) throws -> PickyMainTasksSnapshot {
    let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: data)
    guard case .mainTasksUpdated(let snapshot) = envelope.event else {
        Issue.record("Expected mainTasksUpdated, decoded \(envelope.event)")
        throw MainTaskFixtureError.unexpectedEvent
    }
    return snapshot
}

private enum MainTaskFixtureError: Error {
    case unexpectedEvent
    case missingFixture(String)
}

private func makeTask(
    id: String,
    status: PickyMainTaskStatus,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
    revisionStartedAt: Date? = nil,
    cleanup: PickyMainTaskCleanup? = nil,
    handoff: PickyMainTaskHandoff? = nil,
    canStop: Bool = false,
    canResume: Bool = false
) -> PickyMainTask {
    PickyMainTask(
        id: id,
        revision: 1,
        title: "Task \(id)",
        status: status,
        cwd: "/Users/me",
        readonly: false,
        instructions: ["Do the thing"],
        createdAt: Date(timeIntervalSince1970: 999_000),
        updatedAt: updatedAt,
        revisionStartedAt: revisionStartedAt,
        tier: nil,
        report: nil,
        error: nil,
        cleanup: cleanup,
        decisionId: nil,
        handoff: handoff,
        canStop: canStop,
        canResume: canResume
    )
}

private func makeDecision(
    id: String,
    state: PickyMainDelegationState,
    updatedAt: Date = Date(timeIntervalSince1970: 1_000_000),
    pickle: PickyMainDelegationPickle? = nil
) -> PickyMainDelegationDecision {
    PickyMainDelegationDecision(
        id: id,
        state: state,
        title: "Decision \(id)",
        instructions: "Implement the thing",
        cwd: "/Users/me/src",
        question: nil,
        createdAt: Date(timeIntervalSince1970: 999_000),
        updatedAt: updatedAt,
        fromTaskId: nil,
        taskId: nil,
        pickle: pickle
    )
}
