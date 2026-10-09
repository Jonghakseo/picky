//
//  PickyMainTaskTests.swift
//  PickyTests
//
//  Contracts for the main-agent Task surface: the wire snapshot the daemon
//  broadcasts, the two user controls the app sends back, where Tasks and
//  questions appear in the main conversation, and how the store applies and
//  reports them.
//

import CoreGraphics
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
        #expect(running.selection == PickyMainTaskModelSelection(provider: "openai-codex", model: "gpt-6-luna", thinking: "low"))
        // A Task whose model is not chosen yet still decodes.
        #expect(event.tasks.dropFirst().allSatisfy { $0.selection == nil })

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

    /// The settings screen labels Automatic with what the daemon says it is now.
    @Test func decodesWhatEachLevelRunsOnAutomatic() throws {
        let envelope = try JSONDecoder.pickyAgentProtocolDecoder().decode(
            PickyEventEnvelope.self,
            from: fixtureData("main-task-model-presets.event.json")
        )
        guard case .mainTaskModelPresets(let automatic) = envelope.event else {
            Issue.record("Expected mainTaskModelPresets, decoded \(envelope.event)")
            return
        }
        #expect(automatic?[.fast] == PickyMainTaskModelSelection(provider: "openai-codex", model: "gpt-6-luna", thinking: "low"))
        #expect(automatic?[.powerful]?.thinkingLevel == .high)
        #expect(automatic?[.unknown] == nil)

        let noMainModelYet = Data(#"{"id":"e","protocolVersion":"2026-08-25","timestamp":"2026-10-09T05:00:00.000Z","type":"mainTaskModelPresets","commandId":"c"}"#.utf8)
        guard case .mainTaskModelPresets(let none) = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyEventEnvelope.self, from: noMainModelYet).event else {
            Issue.record("Expected mainTaskModelPresets")
            return
        }
        #expect(none == nil)
    }

    /// Saved settings become the command the daemon validates. A level left on
    /// automatic is omitted, so the daemon drops any earlier choice for it.
    @Test func sendsOnlyTheLevelsTheUserCustomized() throws {
        let settings = PickyTaskModelPresetSettings(
            fast: PickyTaskModelPresetSetting(modelPattern: " anthropic/claude-haiku-5-5 "),
            powerful: PickyTaskModelPresetSetting(modelPattern: "openrouter/anthropic/claude-opus-5-5", thinkingLevel: .xhigh)
        ).normalized
        let command = PickyCommandEnvelope.setMainTaskModelPresets(settings.wirePresets)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(command)) as? [String: Any])
        #expect(object["type"] as? String == "setMainTaskModelPresets")
        let presets = try #require(object["taskModelPresets"] as? [String: Any])
        #expect(Set(presets.keys) == ["fast", "powerful"])
        #expect((presets["fast"] as? [String: Any])?["model"] as? [String: String] == ["provider": "anthropic", "id": "claude-haiku-5-5"])
        #expect((presets["fast"] as? [String: Any])?["thinking"] == nil)
        // Provider ids have no slash; the rest of the pattern is the model id.
        #expect((presets["powerful"] as? [String: Any])?["model"] as? [String: String] == ["provider": "openrouter", "id": "anthropic/claude-opus-5-5"])
        #expect((presets["powerful"] as? [String: Any])?["thinking"] as? String == "xhigh")

        let fixture = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyCommandEnvelope.self, from: fixtureData("set-main-task-model-presets.request.json"))
        #expect(fixture.type == .setMainTaskModelPresets)
        #expect(fixture.taskModelPresets?.powerful?.thinking == .xhigh)
        #expect(fixture.taskModelPresets?.balanced == PickyMainTaskModelPreset())
    }

    /// Settings from a version without Task models, or with a reasoning level
    /// this version does not know, still load instead of resetting everything.
    @Test func loadsOlderAndNewerTaskModelSettings() throws {
        let legacy = try JSONDecoder().decode(PickySettings.self, from: Data("{}".utf8))
        #expect(legacy.taskModelPresets == .automatic)
        #expect(legacy.taskModelPresets.wirePresets == PickyMainTaskModelPresets())

        let newer = Data(#"{"taskModelPresets":{"fast":{"modelPattern":"anthropic/claude-haiku-5-5","thinkingLevel":"ultra"},"balanced":{}}}"#.utf8)
        let decoded = try JSONDecoder().decode(PickySettings.self, from: newer)
        #expect(decoded.taskModelPresets.fast == PickyTaskModelPresetSetting(modelPattern: "anthropic/claude-haiku-5-5"))
        #expect(decoded.taskModelPresets.balanced == PickyTaskModelPresetSetting())
        #expect(decoded.taskModelPresets.powerful == PickyTaskModelPresetSetting())
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

    /// Taken over by a Pickle, the Task is history: its status says where the
    /// work went, and the longer note waits in the details.
    /// Every Task surface and Settings name the levels the same way.
    @Test func namesTheLevelAndTheModelATaskRunsOn() {
        #expect(PickyMainTaskPresentation.tierLabelKey(.fast) == "hub.tasks.tier.fast")
        #expect(PickyMainTaskPresentation.tierLabelKey(.balanced) == "hub.tasks.tier.balanced")
        #expect(PickyMainTaskPresentation.tierLabelKey(.powerful) == "hub.tasks.tier.powerful")
        // Not chosen yet, or a level a newer daemon added: show nothing rather than a guess.
        #expect(PickyMainTaskPresentation.tierLabelKey(nil) == nil)
        #expect(PickyMainTaskPresentation.tierLabelKey(.unknown) == nil)
        #expect(PickyMainTaskPresentation.modelText(for: nil) == nil)
        let text = PickyMainTaskPresentation.modelText(for: PickyMainTaskModelSelection(provider: "openai-codex", model: "gpt-6-sol", thinking: "medium"))
        #expect(text?.contains("openai-codex/gpt-6-sol") == true)
        #expect(text?.contains(PickyMainAgentThinkingLevel.medium.displayName) == true)
    }

    @Test func movesTheHandoffNoteIntoTheDetails() {
        let handedOff = makeTask(id: "t", status: .blocked, handoff: .init(decisionId: "d", pickleSessionId: "s-1"))
        let row = PickyMainTaskPresentation.rows(for: [handedOff])[0]
        #expect(row.state == .handedOff)
        #expect(row.state.isLive == false)
        #expect(row.noteKey == nil)
        #expect(row.detailNoteKey == "hub.tasks.note.handoff")
    }

    @Test func asksTheUserOnlyWhileTheDecisionIsPending() throws {
        let rows = PickyMainTaskPresentation.delegationRows(for: [
            makeDecision(id: "p", state: .pending),
            makeDecision(id: "a", state: .pickle, pickle: .init(state: .creating, sessionId: nil, error: nil)),
            makeDecision(id: "b", state: .pickle, pickle: .init(state: .failed, sessionId: nil, error: "No worktree")),
        ])
        let pending = try #require(rows.first { $0.id == "p" })
        let creating = try #require(rows.first { $0.id == "a" })
        let failed = try #require(rows.first { $0.id == "b" })
        #expect(pending.showsChoices && !pending.showsRetry && !pending.isRecord)
        #expect(creating.isBusy && !creating.showsChoices && !creating.isRecord)
        #expect(failed.showsRetry && !failed.showsChoices && !failed.isRecord)
        #expect(failed.messageKey == "hub.tasks.decision.failed")
    }

    /// An answered question stays in the conversation as a record of what the
    /// user chose, instead of disappearing.
    @Test func keepsAnsweredQuestionsAsRecordsOfTheChoice() {
        let rows = PickyMainTaskPresentation.delegationRows(for: [
            makeDecision(id: "pickle", state: .pickle, pickle: .init(state: .created, sessionId: "s-1", error: nil)),
            makeDecision(id: "task", state: .task),
            makeDecision(id: "cancel", state: .cancelled),
            makeDecision(id: "newer", state: .unknown),
        ])
        #expect(rows.map(\.id) == ["pickle", "task", "cancel"])
        #expect(rows.filter(\.isRecord).count == 3)
        #expect(rows[0].outcome == .handedToPickle(sessionID: "s-1"))
        #expect(rows[0].pickleSessionID == "s-1")
        #expect(rows[0].messageKey == "hub.tasks.decision.record.pickle")
        #expect(rows[1].outcome == .keptWithPicky)
        #expect(rows[1].pickleSessionID == nil)
        #expect(rows[1].messageKey == "hub.tasks.decision.record.task")
        #expect(rows[2].messageKey == "hub.tasks.decision.record.cancelled")
    }
}

/// Where a Task or question appears in the main conversation. A block belongs
/// to the turn it started in and follows what Picky said about it.
@MainActor
struct PickyMainConversationTimelineTests {
    private let start = Date(timeIntervalSince1970: 1_784_000_000)
    private func at(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    /// The common shape: Picky calls `Task` first and announces it afterwards.
    @Test func putsATaskRightAfterTheReplyThatAnnouncedIt() {
        let request = PickyMainAgentMessage(role: .user, text: "Sum this month's discounted revenue", createdAt: at(0))
        let announcement = PickyMainAgentMessage(role: .assistant, text: "Running the report now.", createdAt: at(8))
        let result = PickyMainAgentMessage(role: .assistant, text: "The total is 231.22.", createdAt: at(300))
        let task = makeTask(id: "report", status: .completed, createdAt: at(5))

        let items = timeline([request, announcement, result], tasks: [task])
        #expect(items.map(\.id) == [message(request), message(announcement), "task-report", message(result)])
    }

    /// Picky's sentence before a tool call is recorded first, so a question
    /// asked while handling a Task result follows that explanation rather than
    /// the turn's first reply, and the reply after the answer follows it.
    @Test func putsAQuestionAfterWhatPickySaidRightBeforeAsking() {
        let request = PickyMainAgentMessage(role: .user, text: "Fix the monthly report", createdAt: at(0))
        let announcement = PickyMainAgentMessage(role: .assistant, text: "Checking the script.", createdAt: at(8))
        let explanation = PickyMainAgentMessage(role: .assistant, text: "The discount is applied ten times.", createdAt: at(40))
        let afterAnswer = PickyMainAgentMessage(role: .assistant, text: "A Pickle is on it.", createdAt: at(60))
        let task = makeTask(id: "check", status: .blocked, createdAt: at(5))
        let question = makeDecision(id: "fix", state: .pickle, createdAt: at(40.1), pickle: .init(state: .created, sessionId: "s-1", error: nil))

        let items = timeline([request, announcement, explanation, afterAnswer], tasks: [task], decisions: [question])
        #expect(items.map(\.id) == [
            message(request), message(announcement), "task-check", message(explanation), "decision-fix", message(afterAnswer),
        ])
    }

    /// Before Picky replies, the block closes its turn: a later request never
    /// lands above it.
    @Test func closesTheTurnWhilePickyHasNotRepliedYet() {
        let request = PickyMainAgentMessage(role: .user, text: "Rename my screenshots", createdAt: at(0))
        let next = PickyMainAgentMessage(role: .user, text: "Also empty the trash", createdAt: at(10))
        let task = makeTask(id: "rename", status: .running, createdAt: at(2))

        #expect(timeline([request], tasks: [task]).map(\.id) == [message(request), "task-rename"])
        #expect(timeline([request, next], tasks: [task]).map(\.id) == [message(request), "task-rename", message(next)])
    }

    /// History older than the transcript leaves with its messages, but work
    /// that still runs and a question still waiting stay, at the top.
    @Test func keepsOnlyOpenBlocksOlderThanTheTranscript() {
        let request = PickyMainAgentMessage(role: .user, text: "Hello", createdAt: at(100))
        let finished = makeTask(id: "old-done", status: .completed, createdAt: at(10))
        let running = makeTask(id: "old-running", status: .running, createdAt: at(20))
        let waiting = makeDecision(id: "old-question", state: .pending, createdAt: at(30))
        let answered = makeDecision(id: "old-answer", state: .task, createdAt: at(40))

        let items = timeline([request], tasks: [finished, running], decisions: [waiting, answered])
        #expect(items.map(\.id) == ["task-old-running", "decision-old-question", message(request)])
    }

    /// A new conversation starts empty: earlier results stay out of it.
    @Test func showsOnlyOpenBlocksInANewConversation() {
        let finished = makeTask(id: "done", status: .completed, createdAt: at(10))
        let running = makeTask(id: "running", status: .running, createdAt: at(20))
        let answered = makeDecision(id: "answered", state: .cancelled, createdAt: at(30))

        #expect(timeline([], tasks: [finished, running], decisions: [answered]).map(\.id) == ["task-running"])
    }

    private func timeline(
        _ messages: [PickyMainAgentMessage],
        tasks: [PickyMainTask] = [],
        decisions: [PickyMainDelegationDecision] = []
    ) -> [PickyMainConversationTimelineItem] {
        PickyMainTaskPresentation.timelineItems(messages: messages, snapshot: PickyMainTasksSnapshot(tasks: tasks, decisions: decisions))
    }

    private func message(_ message: PickyMainAgentMessage) -> String {
        PickyMainConversationTimelineItem.message(message).id
    }
}

/// The bar above the Hub composer that points back at a question waiting on the user.
@MainActor
struct PickyHubWaitingQuestionBarTests {
    @Test func pointsAtTheNewestQuestionStillWaitingOnTheUser() {
        let snapshot = PickyMainTasksSnapshot(tasks: [], decisions: [
            makeDecision(id: "older", state: .pending, createdAt: Date(timeIntervalSince1970: 10)),
            makeDecision(id: "newer", state: .pending, createdAt: Date(timeIntervalSince1970: 20)),
            makeDecision(id: "answered", state: .task, createdAt: Date(timeIntervalSince1970: 30)),
        ])
        let items = PickyMainTaskPresentation.timelineItems(messages: [], snapshot: snapshot)
        #expect(PickyHubConversationPolicy.waitingQuestion(in: items)?.id == "decision-newer")
        #expect(PickyHubConversationPolicy.waitingQuestion(in: []) == nil)
    }

    @Test func showsOnlyWhileTheQuestionIsOutOfView() {
        let height: CGFloat = 400
        let margin = PickyHubConversationPolicy.waitingQuestionBottomMargin
        func inView(_ frame: CGRect) -> Bool {
            PickyHubConversationPolicy.isWaitingQuestionInView(frame: frame, viewportHeight: height)
        }
        #expect(inView(CGRect(x: 0, y: 100, width: 500, height: 120)))
        // Scrolled away above, or only peeking over the bottom edge.
        #expect(inView(CGRect(x: 0, y: -130, width: 500, height: 120)) == false)
        #expect(inView(CGRect(x: 0, y: height - margin + 4, width: 500, height: 120)) == false)

        func shows(_ isInView: Bool?) -> Bool {
            PickyHubConversationPolicy.showsWaitingQuestionBar(isQuestionInView: isInView, viewportHeight: height)
        }
        #expect(shows(true) == false)
        #expect(shows(false))
        // Not laid out at all: far out of view.
        #expect(shows(nil))
        // Before the viewport has a size nothing is known, so no bar flashes.
        #expect(PickyHubConversationPolicy.showsWaitingQuestionBar(isQuestionInView: nil, viewportHeight: 0) == false)
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
        #expect(store.commandError(for: "task-1") == nil)
        #expect(store.commandError(for: "decision-1") == nil)
        #expect(store.pendingCommandIDs.isEmpty)
    }

    @Test func surfacesADaemonRejectionInsteadOfLookingLikeItWorked() async {
        let store = PickyMainTaskStore()
        store.send = { _ in PickyErrorEvent(code: "unknown_task", message: "Unknown task", commandId: nil) }

        await store.control(taskID: "task-1", action: .resume)
        #expect(store.commandError(for: "task-1") == "Unknown task")
        // The failure belongs to that Task's block, not to every block.
        #expect(store.commandError(for: "task-2") == nil)
        #expect(store.pendingCommandIDs.isEmpty)

        store.clearCommandError(for: "task-1")
        #expect(store.commandError(for: "task-1") == nil)
    }

    @Test func reportsATransportFailureAsAFailedCommand() async {
        let store = PickyMainTaskStore()
        store.send = { _ -> PickyErrorEvent? in throw PickyAgentClientError.disconnected }

        await store.control(taskID: "task-1", action: .stop)
        #expect(store.commandError(for: "task-1") == L10n.t("hub.tasks.error.commandFailed"))
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
    createdAt: Date = Date(timeIntervalSince1970: 999_000),
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
        createdAt: createdAt,
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
    createdAt: Date = Date(timeIntervalSince1970: 999_000),
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
        createdAt: createdAt,
        updatedAt: updatedAt,
        fromTaskId: nil,
        taskId: nil,
        pickle: pickle
    )
}
