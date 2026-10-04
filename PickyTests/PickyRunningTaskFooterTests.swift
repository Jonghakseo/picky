import AppKit
import SwiftUI
import Testing
import Vision
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyRunningTaskFooterTests {
    @Test func onlyUnfinishedOrUnresolvedWorkKeepsTheFooterVisible() throws {
        let fixture = Fixture()
        let hosts = [false, true].map { compact in
            makeHost(PickyRunningTaskFooterView(store: fixture.store,
                maxListHeight: 120, compact: compact, bottomSpacing: DS.Spacing.space2).frame(width: 422))
        }
        // The footer reports work that has not finished, plus results and states the
        // daemon still cannot confirm. Finished-and-delivered work leaves no band.
        let visible = ["running", "queued", "stopping", "processing", "pending", "unknown",
                       "failed", "reconciling", "omitted"]
        for state in visible + ["handled", "settled-failure", "empty", "omitted-quiet"] {
            var task = PickyAsyncTaskShelfFixtures.task("bash")
            switch state {
            case "queued": task.execution = .queued
            case "stopping": task.execution = .cancelling
            case "processing", "pending", "handled": task.execution = .succeeded
            case "failed", "settled-failure": task.execution = .failed
            default: task.execution = .running
            }
            task.presence = ["processing", "pending", "handled", "failed", "settled-failure"].contains(state)
                ? .settled : state == "unknown" ? .unknown : .active
            fixture.session.asyncTasks = ["empty", "omitted", "omitted-quiet"].contains(state) ? [] : [task]
            // A failure stays visible on its own unresolved delivery, not because
            // the daemon happens to report attention somewhere else.
            fixture.session.completionTickets = ["processing", "pending", "handled", "failed"].contains(state)
                ? [PickyAsyncTaskShelfFixtures.ticket(task, state: state == "processing" ? .processing
                    : state == "handled" ? .handled : state == "failed" ? .failed : .pending)] : []
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(
                active: ["running", "queued", "stopping", "reconciling", "omitted"].contains(state) ? 1 : 0,
                pending: ["processing", "pending"].contains(state) ? 1 : 0,
                unknown: state == "unknown" ? 1 : 0, attention: state == "failed" ? 1 : 0,
                tracking: state == "reconciling" ? .reconciling : .ready)
            try fixture.publish(omitted: state.hasPrefix("omitted") ? ["asyncTasks", "completionTickets"] : [])
            for host in hosts {
                host.layoutSubtreeIfNeeded()
                #expect(visible.contains(state) ? host.fittingSize.height >= 28 : host.fittingSize.height == 0,
                    "\(state) must not hide live work or leave an empty footer band")
            }
        }
    }

    @Test func runningBatchKeepsFinishedMembersWithTheirOwnStates() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["verifier", "reviewer", "challenger"])
            fixture.finish(child: 2, execution: .succeeded)
            fixture.finish(child: 3, execution: .succeeded)
            try fixture.publish()
            let lines = try renderedLines(makeExpandedHost(fixture))
            let text = lines.joined(separator: "\n")
            // The reported bug: members that finished first disappeared from a running batch.
            for agent in ["verifier", "reviewer", "challenger"] {
                #expect(text.contains(agent), "\(agent) must stay in its batch: \(lines)")
            }
            #expect(countsLine(lines, "running1", "completed2") != nil, "Rendered rows: \(lines)")
            // The header is translated chrome, never a raw catalog key.
            #expect(lines.contains { $0.localizedCaseInsensitiveContains("Background work") },
                "Rendered rows: \(lines)")
            #expect(!lines.contains { $0.contains("hud.") }, "Rendered rows: \(lines)")
            #expect(!text.contains("Private delegation instructions"))
            #expect(!text.contains("subagent batch"))
            #expect(!lines.contains { $0.lowercased().contains("stop") || $0.lowercased().contains("details") })
        }
    }

    @Test func mixedWorkKeepsEachGroupSeparateWithoutASharedTotal() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["verifier", "reviewer"])
            fixture.finish(child: 2, execution: .succeeded)
            var command = PickyAsyncTaskShelfFixtures.task("logs", title: "Collect logs")
            command.createdAt = Date(timeIntervalSinceNow: -30)
            fixture.session.asyncTasks?.append(command)
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 2)
            try fixture.publish()
            let lines = try renderedLines(makeExpandedHost(fixture))
            #expect(lines.contains { normalized($0).contains("subagents") }, "Rendered rows: \(lines)")
            #expect(countsLine(lines, "running1", "completed1") != nil, "Rendered rows: \(lines)")
            #expect(lines.contains { normalized($0).contains("collectlogs") },
                "The standalone command keeps its own row: \(lines)")
            // Agents and commands are never summed into one background-work total.
            #expect(!lines.contains { normalized($0).contains("running2") }, "Rendered rows: \(lines)")
        }
    }

    /// The daemon never resends a whole session for ordinary progress: it sends
    /// `asyncTaskDetailSet` and `metaPatch` transactions. This drives the mounted
    /// footer through that routing instead of a sequence of snapshots.
    @Test func liveV2TransactionsMoveTheSameFooterFromRunningThroughResultHandling() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture(routesProtocolEvents: true)
            try fixture.installGroup(["verifier", "reviewer"])
            let host = makeExpandedHost(fixture)
            let started = try renderedLines(host)
            #expect(started.contains { $0.contains("verifier") }, "Rendered rows: \(started)")

            fixture.finish(child: 2, execution: .succeeded)
            try fixture.routeDetail()
            host.layoutSubtreeIfNeeded()
            let partial = try renderedLines(host)
            #expect(countsLine(partial, "running1", "completed1") != nil, "Rendered rows: \(partial)")

            // Every execution finished, but the result has not reached the agent yet.
            fixture.finish(child: 1, execution: .succeeded)
            fixture.finish(child: 0, execution: .succeeded)
            fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(
                try #require(fixture.session.asyncTasks?.first), state: .processing)]
            try fixture.routeDetail()
            try fixture.routeSummary(PickyAsyncTaskShelfFixtures.summary(active: 0, pending: 1))
            host.layoutSubtreeIfNeeded()
            let processing = try renderedLines(host)
            #expect(processing.contains { normalized($0).contains("processingresult") },
                "Rendered rows: \(processing)")
            #expect(countsLine(processing, "completed2") != nil, "Rendered rows: \(processing)")
            #expect(processing.contains { $0.contains("verifier") } &&
                processing.contains { $0.contains("reviewer") }, "Rendered rows: \(processing)")
            #expect(host.fittingSize.height >= 28, "Result handling keeps the footer open")

            fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(
                try #require(fixture.session.asyncTasks?.first), state: .handled)]
            try fixture.routeDetail()
            try fixture.routeSummary(PickyAsyncTaskShelfFixtures.summary(active: 0))
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == 0, "Handled work leaves no footer and no padding")
        }
    }

    @Test func aSettledFailureStaysHiddenWhileUnrelatedWorkNeedsAttention() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            // An older batch failed and its result was already handled.
            var old = PickyAsyncTaskShelfFixtures.task("old", kind: "subagent_group",
                title: "subagent batch", execution: .failed, presence: .settled)
            old.invocationId = "older-invocation"
            var oldChild = PickyAsyncTaskShelfFixtures.task("old-child", root: "old", kind: "subagent",
                execution: .failed, presence: .settled)
            oldChild.details = ["runId": .number(1)]
            // Unrelated current work the daemon reports as needing attention.
            let current = PickyAsyncTaskShelfFixtures.task("logs", title: "Collect daemon logs")
            fixture.session.asyncTasks = [old, oldChild, current]
            fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(old, state: .handled)]
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 1, attention: 1)
            try fixture.publish()
            let lines = try renderedLines(makeExpandedHost(fixture))
            let text = lines.joined(separator: "\n")
            #expect(text.contains("Collect daemon logs"), "Rendered rows: \(lines)")
            #expect(!lines.contains { normalized($0).contains("subagents") },
                "A handled older failure must not reappear: \(lines)")
            #expect(!lines.contains { $0.localizedCaseInsensitiveContains("Failed") },
                "A handled older failure must not reappear: \(lines)")
            // The daemon's own unresolved attention still has to reach the user.
            #expect(text.localizedCaseInsensitiveContains("needs attention"), "Rendered rows: \(lines)")
        }
    }

    @Test func anInvocationFailureStaysVisibleWhenEveryAgentCompleted() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["verifier", "reviewer"])
            fixture.finish(child: 1, execution: .succeeded)
            fixture.finish(child: 2, execution: .succeeded)
            // The batch itself failed after its agents finished, and the result
            // has not been confirmed.
            fixture.finish(child: 0, execution: .failed)
            fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(
                try #require(fixture.session.asyncTasks?.first), state: .unknown)]
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1)
            try fixture.publish()
            let lines = try renderedLines(makeExpandedHost(fixture))
            #expect(countsLine(lines, "completed2") != nil, "Rendered rows: \(lines)")
            #expect(lines.contains { $0.localizedCaseInsensitiveContains("Failed") },
                "The invocation failure must not hide behind finished agents: \(lines)")
            // The batch root is reported as a state, never as one more agent.
            #expect(countsLine(lines, "failed1") == nil, "Rendered rows: \(lines)")
            #expect(lines.contains { normalized($0).contains("verification") }, "Rendered rows: \(lines)")
            #expect(!lines.contains { $0.lowercased().contains("stop") || $0.lowercased().contains("details") },
                "Rendered rows: \(lines)")
        }
    }

    @Test func settledRowsReportProviderDurationAndStayFixedAcrossUnrelatedUpdates() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["verifier", "reviewer"])
            // Only the first agent's executor reported timing; the other stays blank.
            fixture.finish(child: 1, execution: .succeeded, elapsedMs: 90_000)
            fixture.finish(child: 2, execution: .succeeded)
            fixture.finish(child: 0, execution: .succeeded)
            fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(
                try #require(fixture.session.asyncTasks?.first), state: .processing)]
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, pending: 1)
            try fixture.publish()
            let host = makeExpandedHost(fixture)
            let initial = try renderedLines(host)
            #expect(durations(initial) == ["1:30"], "Rendered rows: \(initial)")

            // An unrelated lifecycle update bumps updatedAt; a finished duration must not move.
            for index in fixture.session.asyncTasks?.indices ?? (0..<0) {
                fixture.session.asyncTasks?[index].updatedAt = Date(timeIntervalSinceNow: 600)
                fixture.session.asyncTasks?[index].providerRevision += 1
            }
            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            let refreshed = try renderedLines(host)
            #expect(durations(refreshed) == ["1:30"], "Rendered rows: \(refreshed)")

            // Corrupt provider metadata is discarded, not rendered or converted.
            fixture.session.asyncTasks?[1].details?["elapsedMs"] = .number(1e25)
            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            let corrupted = try renderedLines(host)
            #expect(durations(corrupted).isEmpty, "Rendered rows: \(corrupted)")
            #expect(host.fittingSize.height >= 28, "The work itself stays visible")
        }
    }

    @Test func liveElapsedTimeAppearsOnlyAfterTheProviderReportsAStart() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["verifier"])
            let host = makeExpandedHost(fixture)
            let queued = try renderedLines(host)
            // `createdAt` includes reservation and queue wait, so it is not a start.
            #expect(durations(queued).isEmpty, "Rendered rows: \(queued)")

            let formatter = ISO8601DateFormatter()
            fixture.session.asyncTasks?[1].details?["startedAt"] =
                .string(formatter.string(from: Date(timeIntervalSinceNow: -90)))
            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            let running = try renderedLines(host)
            #expect(!durations(running).isEmpty, "Rendered rows: \(running)")
        }
    }

    @Test func missingRunMetadataKeepsTheAgentVisibleWithoutItsInstructions() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["worker", "reviewer"])
            try fixture.publish(omitted: ["subagentRuns"])
            let host = makeExpandedHost(fixture)
            let pending = try renderedLines(host)
            #expect(host.fittingSize.height >= 28, "Late metadata must not hide running agents")
            #expect(!pending.joined().contains("Private delegation instructions"), "Rendered rows: \(pending)")
            #expect(pending.contains { $0.contains("Agent") }, "Unnamed agents stay visible: \(pending)")

            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            let named = try renderedLines(host)
            #expect(named.contains { $0.contains("worker") } && named.contains { $0.contains("reviewer") },
                "Rendered rows: \(named)")
        }
    }

    /// Re-entry omits the task detail while the daemon still reports counts. The
    /// counts cannot distinguish a failure from an unverified execution, so the
    /// footer must ask for verification instead of declaring work failed.
    @Test func canonicalCountsWithoutDetailReportVerificationInsteadOfFailure() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            fixture.session.asyncTasks = []
            fixture.session.completionTickets = []
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, unknown: 1, attention: 1)
            try fixture.publish(omitted: ["asyncTasks", "completionTickets"])
            guard case .loaded(let metadata) = fixture.store.metaStore.metadataState else {
                Issue.record("Projected metadata is required for the footer")
                return
            }
            let summary = try #require(metadata.asyncWorkSummary)
            let model = try #require(PickyBackgroundWorkFooterPresentation.model(
                summary: summary,
                detail: fixture.store.asyncTaskStore.detailState, runs: { [] },
                runtimeInstanceId: metadata.agentCycle?.runtimeInstanceId))
            #expect(model.status.state == .unknown, "Counts alone are not a confirmed failure")

            let host = makeExpandedHost(fixture)
            #expect(host.fittingSize.height >= 28, "Canonical attention stays visible without detail")
            let lines = try renderedLines(host)
            let text = lines.joined(separator: "\n").lowercased()
            #expect(text.contains("verification"), "Rendered rows: \(lines)")
            #expect(!text.contains("failed"), "Rendered rows: \(lines)")
        }
    }

    @Test func unverifiedDeliveryIsNotReportedAsAConfirmedFailure() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for (ticket, expected, rejected) in [(PickyCompletionState.unknown, "verification", "failed"),
                                                 (.failed, "failed", "verification")] {
                let fixture = Fixture()
                try fixture.installGroup(["verifier"])
                fixture.finish(child: 1, execution: .succeeded)
                fixture.finish(child: 0, execution: .succeeded)
                fixture.session.completionTickets = [PickyAsyncTaskShelfFixtures.ticket(
                    try #require(fixture.session.asyncTasks?.first), state: ticket)]
                fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(active: 0, attention: 1)
                try fixture.publish()
                let lines = try renderedLines(makeExpandedHost(fixture))
                let text = lines.joined(separator: "\n").lowercased()
                #expect(text.contains(expected), "\(ticket) delivery: \(lines)")
                #expect(!text.contains(rejected), "\(ticket) delivery: \(lines)")
            }
        }
    }

    private func makeExpandedHost(_ fixture: Fixture) -> NSHostingView<some View> {
        let host = makeHost(PickyRunningTaskFooterView(store: fixture.store,
            maxListHeight: 180, initiallyExpanded: true).frame(width: 422))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
    }

    /// Offscreen hosts resolve `Text("key")` through the environment locale, so
    /// they must carry the same localization root the app installs. Without it a
    /// test renders whichever language the developer's Mac happens to use.
    private func makeHost<Content: View>(_ view: Content) -> NSHostingView<LocalizedFooterTestRoot<Content>> {
        let host = NSHostingView(rootView: LocalizedFooterTestRoot(content: view))
        host.appearance = NSAppearance(named: .aqua)
        return host
    }

    /// Production localization root plus an opaque backdrop, so rendered text is
    /// readable for the OCR assertions in either system appearance.
    struct LocalizedFooterTestRoot<Content: View>: View {
        let content: Content

        var body: some View {
            LocalizedHostingRoot { content.background(DS.Colors.surface1) }
        }
    }

    private func renderedLines(_ host: NSView) throws -> [String] {
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let recognition = VNRecognizeTextRequest()
        recognition.recognitionLevel = .accurate
        recognition.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: #require(bitmap.cgImage)).perform([recognition])
        return (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    /// A single work row can never carry two different state tallies, so requiring
    /// every token on one line identifies the group summary without guessing.
    private func countsLine(_ lines: [String], _ tokens: String...) -> String? {
        lines.first { line in tokens.allSatisfy { normalized(line).contains($0) } }
    }

    private func durations(_ lines: [String]) -> [String] {
        let pattern = try? NSRegularExpression(pattern: "\\d+:\\d{2}")
        return lines.flatMap { line -> [String] in
            let range = NSRange(line.startIndex..., in: line)
            return (pattern?.matches(in: line, range: range) ?? []).compactMap {
                Range($0.range, in: line).map { String(line[$0]) }
            }
        }
    }

    // OCR varies the glyph for the interpunct and multiplication, not the names or counts.
    private func normalized(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "×", with: "x")
            .filter { !$0.isWhitespace && !["·", "•", ".", ":", "-"].contains($0) }
    }

    @MainActor private final class Fixture {
        let storage = PickyRegistrySessionProjectionStorage()
        var store: PickySessionStore { storage.registry.sessionStore(sessionID: "session") }
        var session = PickyAgentSession(id: "session", title: "Running footer", status: .running,
            cwd: "/tmp/project", createdAt: Date(timeIntervalSince1970: 1), updatedAt: Date(timeIntervalSince1970: 2),
            logs: [], tools: [], artifacts: [], changedFiles: [])
        private var revision = 0
        private let events = PickyProjectionEventFixtures(epoch: "running-footer-tests")
        /// Present only for tests that drive the footer through the production
        /// protocol-event path, where the revision cursor lives in the view model.
        private let viewModel: PickySessionListViewModel?

        init(routesProtocolEvents: Bool = false) {
            viewModel = routesProtocolEvents ? PickySessionListViewModel(
                client: FakePickyAgentClient(),
                notificationCenter: PickyNoopNotificationCenter(),
                notificationPreferencesProvider: PickyStubNotificationPreferences(),
                sessionProjectionStorage: storage) : nil
        }

        /// One `asyncTaskDetailSet` transaction, the progress-only frame the
        /// daemon sends while a batch runs.
        func routeDetail() throws {
            try route([PickyProjectionEventFixtures.asyncTaskDetailSetMutation(PickyAsyncTaskDetail(
                tasks: session.asyncTasks ?? [], tickets: session.completionTickets ?? []))])
        }

        /// One ordinary `metaPatch` transaction carrying the canonical counts.
        func routeSummary(_ summary: PickyAsyncWorkSummary) throws {
            session.asyncWorkSummary = summary
            try route([PickyProjectionEventFixtures.asyncWorkSummaryPatchMutation(summary)])
        }

        private func route(_ mutations: [String]) throws {
            let viewModel = try #require(self.viewModel, "This fixture does not route protocol events")
            viewModel.apply(.protocolEvent(events.transactionEnvelope(
                sessionID: session.id, mutations: mutations)))
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }

        func installGroup(_ agents: [String]) throws {
            // The provider reports the batch root with the same `subagent` kind as its
            // agents; the legacy group aliases survive only in historical sessions.
            var root = PickyAsyncTaskShelfFixtures.task("group", kind: "subagent", title: "subagent batch")
            root.invocationId = "invocation"
            root.createdAt = Date(timeIntervalSinceNow: -60)
            session.asyncTasks = [root] + agents.enumerated().map { index, _ in
                var child = PickyAsyncTaskShelfFixtures.task("child-\(index)", root: "group", kind: "subagent")
                child.createdAt = root.createdAt
                child.details = ["runId": .number(Double(index + 1))]
                return child
            }
            // Same runId in an older invocation must not supply the current agent type.
            let records = [["runId": 1, "agent": "unrelated", "task": "Private delegation instructions",
                            "status": "running", "invocationId": "older-invocation"]] +
                agents.enumerated().map { index, agent in
                    ["runId": index + 1, "agent": agent, "task": "Private delegation instructions",
                     "status": "running", "invocationId": "invocation"] as [String: Any]
                }
            session.subagentRuns = try JSONDecoder.pickyAgentProtocolDecoder().decode([PickySubagentRun].self,
                from: JSONSerialization.data(withJSONObject: records))
            session.completionTickets = []
            session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary()
            try publish()
        }

        /// Index 0 is the batch root; its agents start at 1.
        func finish(child index: Int, execution: PickyExecutionState, elapsedMs: Double? = nil) {
            session.asyncTasks?[index].execution = execution
            session.asyncTasks?[index].presence = .settled
            if let elapsedMs {
                session.asyncTasks?[index].details?["elapsedMs"] = .number(elapsedMs)
            }
        }

        func publish(omitted: [String] = []) throws {
            revision = events.nextSnapshotRevision(sessionID: session.id)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var projection = try #require(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
            for field in omitted { projection.removeValue(forKey: field) }
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": session.id, "epoch": "running-footer-tests",
                "revision": revision, "complete": omitted.isEmpty, "omittedFields": omitted, "projection": projection])
            let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: data)
            if let viewModel {
                // The cursor that validates later transactions lives behind this entry point.
                viewModel.apply(.protocolEvent(PickyEventEnvelope(id: "snapshot-\(revision)",
                    protocolVersion: pickyAgentProtocolVersion, timestamp: Date(),
                    event: .sessionProjectionSnapshot(snapshot))))
                #expect(storage.registry.existingSessionStore(sessionID: session.id) != nil)
            } else {
                #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
            }
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
