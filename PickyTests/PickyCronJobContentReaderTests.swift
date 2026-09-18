import Foundation
import Testing
@testable import Picky

struct PickyCronJobContentReaderTests {
    @Test func readsCurrentPromptAndOnlyLinkedHistoricalSnapshots() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let current = try fixture.write("prompts/current.md", "Current instructions")
        let snapshot = try fixture.write("runs/job/snapshot.prompt.md", "Original instructions")
        var job = fixture.job
        job.promptFile = current.path
        let date = Date(timeIntervalSince1970: 100)
        job.executions = [.init(date: date, exitCode: 0, promptFile: snapshot.path)]
        #expect(fixture.content.readPrompt(for: job) == .loaded("Current instructions"))
        #expect(fixture.content.readPrompt(for: job, executionDate: date) == .loaded("Original instructions"))
        #expect(fixture.content.readPrompt(for: job, executionDate: date.addingTimeInterval(1)) == .missing)
    }

    @Test func rejectsEscapesSymlinksNonRegularInvalidAndOversizedPrompts() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var job = fixture.job
        job.promptFile = "/etc/passwd"
        #expect(fixture.content.readPrompt(for: job) == .unsafePath)
        job.promptFile = fixture.root.path + "/../escape"
        #expect(fixture.content.readPrompt(for: job) == .unsafePath)
        let target = try fixture.write("target.md", "private")
        let link = fixture.root.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        job.promptFile = link.path
        #expect(fixture.content.readPrompt(for: job) == .unsafePath)
        job.promptFile = fixture.root.appendingPathComponent("absent.md").path
        #expect(fixture.content.readPrompt(for: job) == .missing)
        let directory = fixture.root.appendingPathComponent("directory")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        job.promptFile = directory.path
        #expect(fixture.content.readPrompt(for: job) == .unsafePath)
        let invalid = fixture.root.appendingPathComponent("invalid.md")
        try Data([0xff]).write(to: invalid)
        job.promptFile = invalid.path
        #expect(fixture.content.readPrompt(for: job) == .unreadable)
        job.promptFile = try fixture.write("large.md", String(repeating: "a", count: 256 * 1024 + 1)).path
        #expect(fixture.content.readPrompt(for: job) == .tooLarge)
    }

    @Test func calendarReadsMultipleDaysAndOnceHistoryWithoutDuplicatingFinishTime() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let latest = try fixture.write("runs/job/2026-09-18T09-00-00-000Z.log", "# cron run: job\nstartedAt: 2026-09-18T09:05:00Z\nexitCode: 0\ntimedOut: false\n\n## stdout\nexitCode: 99")
        _ = try fixture.write("runs/job/2026-09-17T09-00-00-000Z.log", "# cron run: job\nstartedAt: 2026-09-17T09:05:00Z\nexitCode: 2\n\n## stdout\nprivate")
        _ = try fixture.write("runs/once/2026-09-16T09-00-00-000Z.log", "# cron session delivery: once\ndeliveredAt: 2026-09-16T09:01:00Z\noutcome: settled\n\nprivate")
        _ = try fixture.write("runs/job/2026-09-15T09-00-00-000Z.log", "# cron run failure: job\nfailedAt: 2026-09-15T09:01:00Z\n\n## error\nprivate")
        _ = try fixture.write("runs/job/2026-09-14T09-00-00-000Z.log", "malformed\nexitCode: 0")
        _ = try fixture.write("runs/job/not-a-date.log", "# cron run: job\nexitCode: 0")
        let snapshot = try fixture.write("runs/job/token.prompt.md", "historical")
        try fixture.store(jobs: [["id": "job", "name": "Job", "enabled": true,
            "lastRunAt": "2026-09-18T09:05:00Z", "lastExitCode": 0,
            "lastRunLog": latest.path, "lastRunPromptFile": snapshot.path]],
            history: [["id": "once", "name": "Once", "enabled": false,
                "lastRunAt": "2026-09-16T09:01:00Z",
                "lastRunLog": fixture.root.appendingPathComponent("runs/once/2026-09-16T09-00-00-000Z.log").path]])
        let interval = DateInterval(start: Self.date("2026-09-14T00:00:00Z"), end: Self.date("2026-09-19T00:00:00Z"))
        guard case .jobs(let jobs) = fixture.reader.readCalendar(interval: interval) else { Issue.record("Expected jobs"); return }
        let result = PickyCronCalendarProjection.occurrences(jobs: jobs, interval: interval, now: interval.end)
        #expect(result.occurrences.map(\.date) == [15, 16, 17, 18].map { Self.date("2026-09-\($0)T09:00:00Z") })
        #expect(result.occurrences.map { $0.execution?.exitCode } == [1, nil, 2, 0])
        let job = try #require(jobs.first { $0.id == "job" })
        #expect(fixture.content.readPrompt(for: job, executionDate: Self.date("2026-09-18T09:00:00Z")) == .loaded("historical"))
        let narrow = DateInterval(start: Self.date("2026-09-18T09:01:00Z"), end: interval.end)
        guard case .jobs(let narrowJobs) = fixture.reader.readCalendar(interval: narrow) else { Issue.record("Expected jobs"); return }
        #expect(PickyCronCalendarProjection.occurrences(jobs: narrowJobs, interval: narrow, now: narrow.end).occurrences.isEmpty)
    }

    @Test func ignoresUnsafeHistoryDirectoriesAndDoesNotGuessMissingLogSuccess() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.write("other/2026-09-18T09-00-00-000Z.log", "# cron run: linked\nexitCode: 0\n\n")
        try FileManager.default.createDirectory(at: fixture.root.appendingPathComponent("runs"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("runs/linked"), withDestinationURL: fixture.root.appendingPathComponent("other"))
        try fixture.store(jobs: [["id": "linked", "name": "Linked", "enabled": false],
            ["id": "missing", "name": "Missing", "enabled": false, "lastRunAt": "2026-09-18T09:00:00Z"],
            ["id": "../other", "name": "Escape", "enabled": false]])
        let interval = DateInterval(start: Self.date("2026-09-18T00:00:00Z"), duration: 86400)
        guard case .jobs(let jobs) = fixture.reader.readCalendar(interval: interval) else { Issue.record("Expected jobs"); return }
        let result = PickyCronCalendarProjection.occurrences(jobs: jobs, interval: interval, now: interval.end)
        #expect(result.occurrences.map(\.job.id) == ["missing"])
        #expect(result.occurrences.first?.execution?.exitCode == nil)
    }

    @Test func historicalInstructionsPreferSnapshotAndMarkCurrentFallbackExplicitly() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var job = fixture.job
        job.promptFile = try fixture.write("prompts/current.md", "Current instruction").path
        let snapshot = try fixture.write("runs/job/old.prompt.md", "Original instruction")
        let date = Date(timeIntervalSince1970: 100)
        job.executions = [.init(date: date, exitCode: 0, promptFile: snapshot.path)]
        #expect(fixture.content.readInstructions(for: job, executionDate: date) == .init(result: .loaded("Original instruction"), isHistorical: true))
        #expect(fixture.content.readInstructions(for: job, executionDate: date.addingTimeInterval(-1)) == .init(result: .loaded("Current instruction")))
    }

    @Test func oldFilesDoNotConsumeLogBudgetAndOmittedHistoryIsReported() throws {
        let fixture = try CronContentFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for day in 1...5 {
            _ = try fixture.write(String(format: "runs/job/2026-08-%02dT09-00-00-000Z.log", day), "# cron run: job\nexitCode: 0\n\n")
        }
        _ = try fixture.write("runs/job/2026-09-18T09-00-00-000Z.log", "# cron run: job\nexitCode: 0\n\n")
        _ = try fixture.write("runs/other/2026-09-18T10-00-00-000Z.log", "# cron run: other\nexitCode: 1\n\n")
        try fixture.store(jobs: [["id": "job", "name": "A", "enabled": true], ["id": "other", "name": "B", "enabled": true]])
        let interval = DateInterval(start: Self.date("2026-09-18T00:00:00Z"), duration: 86400)
        guard case .jobs(let all) = fixture.reader.readCalendar(interval: interval, maximumLogReads: 2) else { Issue.record("Expected jobs"); return }
        #expect(all.flatMap(\.executions).count == 2)
        #expect(!all.contains { $0.historyTruncated })
        guard case .jobs(let limited) = fixture.reader.readCalendar(interval: interval, maximumLogReads: 1) else { Issue.record("Expected jobs"); return }
        #expect(limited.flatMap(\.executions).count == 1)
        #expect(limited.contains { $0.historyTruncated })
    }

    private static func date(_ text: String) -> Date { PickyCronJobReader.parseDate(text)! }
}

private struct CronContentFixture {
    let root: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("cron-content-\(UUID().uuidString)").appendingPathComponent("cron")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    var content: PickyCronJobContentReader { .init(cronDirectory: root) }
    var reader: PickyCronJobReader {
        .init(preferences: .init(codingAgentDir: root.deletingLastPathComponent().path), homeURL: root, environment: [:])
    }
    var job: PickyCronJobPresentation {
        .init(id: "job", name: "Job", status: .active, enabled: true, schedule: nil, runAtText: nil,
              nextRunAt: nil, lastRunAt: nil, completedAt: nil, lastExitCode: nil)
    }
    @discardableResult func write(_ path: String, _ text: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }
    func store(jobs: [[String: Any]], history: [[String: Any]] = []) throws {
        try JSONSerialization.data(withJSONObject: ["version": 2, "jobs": jobs, "history": history])
            .write(to: root.appendingPathComponent("jobs.json"))
    }
}
