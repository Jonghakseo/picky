import AppKit
import SwiftUI
import Testing
import Vision
@testable import Picky

@MainActor
@Suite(.serialized)
struct PickyRunningTaskFooterTests {
    @Test func projectionUpdatesShowOnlyActiveRunningWorkWithoutAnEmptyBand() throws {
        let fixture = Fixture()
        let hosts = [false, true].map { compact in
            NSHostingView(rootView: PickyRunningTaskFooterView(store: fixture.store,
                maxListHeight: 120, compact: compact, bottomSpacing: DS.Spacing.space2).frame(width: 422))
        }
        for state in ["running", "omitted", "running", "processing", "failed", "unknown", "queued", "empty", "running", "reconciling", "empty"] {
            var task = PickyAsyncTaskShelfFixtures.task("bash")
            task.execution = state == "processing" ? .succeeded : state == "failed" ? .failed :
                state == "queued" ? .queued : .running
            task.presence = state == "unknown" ? .unknown :
                ["processing", "failed"].contains(state) ? .settled : .active
            fixture.session.asyncTasks = state == "empty" ? [] : [task]
            fixture.session.completionTickets = state == "processing" ?
                [PickyAsyncTaskShelfFixtures.ticket(task, state: .processing)] : []
            fixture.session.asyncWorkSummary = PickyAsyncTaskShelfFixtures.summary(
                active: ["running", "omitted"].contains(state) ? 1 : 0, pending: state == "processing" ? 1 : 0,
                unknown: state == "unknown" ? 1 : 0, attention: state == "failed" ? 1 : 0,
                tracking: state == "reconciling" ? .reconciling : .ready)
            try fixture.publish(omitted: state == "omitted" ? ["asyncTasks", "completionTickets"] : [])
            for host in hosts {
                host.layoutSubtreeIfNeeded()
                #expect(state == "running" ? host.fittingSize.height >= 28 : host.fittingSize.height == 0,
                    "\(state) must not leave hidden work or an empty footer band")
            }
        }
    }

    @Test func expandedFooterShowsActualAgentTypesWithoutInstructionsOrStopLabels() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            for (agents, expected) in [
                (["worker", "worker"], "Running subagents: worker × 2"),
                (["worker", "reviewer"], "Running subagents: worker · reviewer")
            ] {
                let fixture = Fixture()
                try fixture.installGroup(agents)
                let host = makeExpandedHost(fixture)
                let lines = try renderedLines(host)
                #expect(lines.contains { normalized($0) == normalized(expected) }, "Rendered rows: \(lines)")
                let text = lines.joined(separator: "\n")
                #expect(!text.contains("Private delegation instructions"))
                #expect(!text.contains("subagent batch"))
                #expect(!lines.contains { $0.lowercased().contains("stop") || $0.lowercased().contains("details") })
            }
        }
    }

    @Test func survivingChildAndLateRunMetadataUpdateTheSameMountedFooter() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.english) {
            let fixture = Fixture()
            try fixture.installGroup(["worker", "reviewer"])
            fixture.session.asyncTasks?[0].execution = .failed
            fixture.session.asyncTasks?[0].presence = .settled
            fixture.session.asyncTasks?[2].execution = .succeeded
            fixture.session.asyncTasks?[2].presence = .settled
            try fixture.publish(omitted: ["subagentRuns"])
            let host = makeExpandedHost(fixture)
            let pendingLines = try renderedLines(host)
            #expect(pendingLines.contains { normalized($0) == normalized("Subagents · 1") }, "Rendered rows: \(pendingLines)")
            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            let lines = try renderedLines(host)
            #expect(lines.contains { normalized($0) == normalized("Running subagents: worker") }, "Rendered rows: \(lines)")
            let text = lines.joined(separator: "\n")
            #expect(!text.contains("reviewer"), "Finished children do not appear as running")
            fixture.session.asyncTasks?[1].execution = .succeeded
            fixture.session.asyncTasks?[1].presence = .settled
            try fixture.publish()
            host.layoutSubtreeIfNeeded()
            #expect(host.fittingSize.height == 0)
        }
    }

    private func makeExpandedHost(_ fixture: Fixture) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: PickyRunningTaskFooterView(store: fixture.store,
            maxListHeight: 120, initiallyExpanded: true).frame(width: 422))
        host.setFrameSize(host.fittingSize)
        host.layoutSubtreeIfNeeded()
        return host
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

    // OCR varies the glyph for multiplication and the interpunct, not the row's names/count.
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

        func installGroup(_ agents: [String]) throws {
            var root = PickyAsyncTaskShelfFixtures.task("group", kind: "subagent_group", title: "subagent batch")
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

        func publish(omitted: [String] = []) throws {
            revision += 1
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            var projection = try #require(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
            for field in omitted { projection.removeValue(forKey: field) }
            let data = try JSONSerialization.data(withJSONObject: ["sessionId": session.id, "epoch": "running-footer-tests",
                "revision": revision, "complete": omitted.isEmpty, "omittedFields": omitted, "projection": projection])
            let snapshot = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickySessionProjectionSnapshot.self, from: data)
            #expect(storage.applyProjectionSnapshot(snapshot, archived: false) != nil)
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }
}
