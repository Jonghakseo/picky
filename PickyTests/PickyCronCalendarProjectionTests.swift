import Foundation
import Testing
@testable import Picky

struct PickyCronCalendarProjectionTests {
    @Test func readerPreservesTimezoneAndProjectsWeekdaysWithoutInventingHistory() throws {
        let jobs = try readJobs([
            ["id": "weekday", "schedule": "0 9 * * 1-5", "timezone": "Asia/Seoul",
             "lastRunAt": "2026-09-17T00:00:00Z", "nextRunAt": "2026-09-18T00:15:00Z"]
        ])
        let result = project(jobs, start: "2026-09-14T00:00:00Z", end: "2026-09-23T00:00:00Z", zone: "Asia/Seoul")
        #expect(jobs.first?.timezone == "Asia/Seoul")
        #expect(result.occurrences.map(\.date) == [
            date("2026-09-17T00:00:00Z"), date("2026-09-18T00:15:00Z"),
            date("2026-09-21T00:00:00Z"), date("2026-09-22T00:00:00Z")
        ])
        #expect(result.occurrences.map(\.kind) == [.actual, .next, .projected, .projected])
        #expect(result.unsupportedJobIDs.isEmpty)
    }

    @Test func oneShotAndOnceCronNeverRepeatAndDisabledJobsOnlyShowActualRun() throws {
        let jobs = try readJobs([
            ["id": "at", "runAt": "2026-09-19T12:00:00Z", "once": true],
            ["id": "once-cron", "schedule": "0 9 * * *", "once": true,
             "nextRunAt": "2026-09-19T09:00:00Z"],
            ["id": "disabled", "enabled": false, "schedule": "* * * * *",
             "lastRunAt": "2026-09-17T12:00:00Z", "completedAt": "2026-09-17T12:05:00Z",
             "nextRunAt": "2026-09-19T10:00:00Z"]
        ])
        let result = project(jobs)
        #expect(result.occurrences.map(\.job.id) == ["disabled", "once-cron", "at"])
        #expect(result.occurrences.map(\.kind) == [.actual, .next, .next])
        #expect(result.occurrences.first?.date == date("2026-09-17T12:00:00Z"))
    }

    @Test func unsupportedRulesAreReportedButAuthoritativeNextRemainsVisible() throws {
        let jobs = try readJobs([
            ["id": "named", "schedule": "0 9 * * MON", "nextRunAt": "2026-09-19T09:00:00Z"],
            ["id": "seconds", "schedule": "0 0 9 * * *"],
            ["id": "zero-step", "schedule": "*/0 * * * *"],
            ["id": "weekday-seven", "schedule": "0 9 * * 7"]
        ])
        let result = project(jobs)
        #expect(result.unsupportedJobIDs == ["named", "seconds", "zero-step", "weekday-seven"])
        #expect(result.occurrences.map(\.job.id) == ["named"])
        #expect(result.occurrences.first?.kind == .next)
    }

    @Test func dayOfMonthAndWeekdayUsePluginAndSemanticsWithListsAndSteps() throws {
        let jobs = try readJobs([
            ["id": "and", "schedule": "0,30 9-10/1 21 9 1"]
        ])
        let result = project(jobs, end: "2026-10-01T00:00:00Z")
        #expect(result.occurrences.map(\.date) == [
            date("2026-09-21T09:00:00Z"), date("2026-09-21T09:30:00Z"),
            date("2026-09-21T10:00:00Z"), date("2026-09-21T10:30:00Z")
        ])
    }

    @Test func minutelyMonthIsBoundedAndGloballyChronological() throws {
        let jobs = try readJobs([
            ["id": "minute", "schedule": "* * * * *"],
            ["id": "early", "runAt": "2026-09-18T00:00:30Z"]
        ])
        let result = project(jobs, end: "2026-10-18T00:00:00Z", limit: 5)
        #expect(result.truncated)
        #expect(result.occurrences.count == 5)
        #expect(result.occurrences.first?.job.id == "early")
        #expect(result.occurrences.last?.date == date("2026-09-18T00:04:00Z"))
        let zero = project(jobs, limit: 0)
        #expect(zero.occurrences.isEmpty)
        #expect(zero.truncated)
    }

    @Test func intervalEndIsExclusiveAndImpossibleDatesDoNotBecomeFakeRuns() throws {
        let jobs = try readJobs([
            ["id": "impossible", "schedule": "0 9 31 2 *"],
            ["id": "completed", "enabled": false, "completedAt": "2026-09-17T00:00:00Z"],
            ["id": "end", "runAt": "2026-09-23T00:00:00Z"]
        ])
        let result = project(jobs)
        #expect(result.occurrences.map(\.job.id) == ["completed"])
        #expect(result.occurrences.first?.kind == .actual)
        #expect(result.unsupportedJobIDs.isEmpty)
        #expect(!result.truncated)
    }

    @Test func dstGapAndRepeatedHourFollowLocalDateSetterSemantics() throws {
        let spring = try readJobs([["id": "spring", "schedule": "30 2 * * *", "timezone": "America/New_York"]])
        let springResult = PickyCronCalendarProjection.occurrences(
            jobs: spring, interval: .init(start: date("2026-03-08T00:00:00Z"), end: date("2026-03-10T00:00:00Z")),
            now: date("2026-03-08T00:00:00Z"), schedulerTimeZone: TimeZone(identifier: "America/New_York")!
        )
        #expect(springResult.occurrences.map(\.date) == [date("2026-03-09T06:30:00Z")])
        let fall = try readJobs([["id": "fall", "schedule": "30 1 * * *", "timezone": "America/New_York"]])
        let fallResult = PickyCronCalendarProjection.occurrences(
            jobs: fall, interval: .init(start: date("2026-11-01T00:00:00Z"), end: date("2026-11-02T00:00:00Z")),
            now: date("2026-11-01T00:00:00Z"), schedulerTimeZone: TimeZone(identifier: "America/New_York")!
        )
        #expect(fallResult.occurrences.map(\.date) == [date("2026-11-01T05:30:00Z")])
    }

    @Test func storedTimezoneDoesNotOverrideCronSchedulerLocalTimezone() throws {
        let jobs = try readJobs([["id": "local", "schedule": "0 9 * * *", "timezone": "Asia/Seoul"]])
        let result = project(jobs, start: "2026-09-18T00:00:00Z", end: "2026-09-19T00:00:00Z")
        #expect(jobs.first?.timezone == "Asia/Seoul")
        #expect(result.occurrences.map(\.date) == [date("2026-09-18T09:00:00Z")])
    }

    private func date(_ text: String) -> Date {
        PickyCronJobReader.parseDate(text)!
    }

    private func project(
        _ jobs: [PickyCronJobPresentation],
        start: String = "2026-09-17T00:00:00Z",
        end: String = "2026-09-23T00:00:00Z",
        limit: Int = 500,
        zone: String = "UTC"
    ) -> PickyCronCalendarProjectionResult {
        PickyCronCalendarProjection.occurrences(
            jobs: jobs, interval: .init(start: date(start), end: date(end)),
            now: date("2026-09-18T00:00:00Z"), limit: limit, schedulerTimeZone: TimeZone(identifier: zone)!
        )
    }

    private func readJobs(_ fields: [[String: Any]]) throws -> [PickyCronJobPresentation] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cron = root.appendingPathComponent("cron")
        try FileManager.default.createDirectory(at: cron, withIntermediateDirectories: true)
        let jobs = fields.map { fields in
            fields.merging(["name": fields["id"] as? String ?? "Job", "enabled": true, "timezone": "UTC"]) { existing, _ in existing }
        }
        let data = try JSONSerialization.data(withJSONObject: ["version": 2, "jobs": jobs, "history": []])
        try data.write(to: cron.appendingPathComponent("jobs.json"))
        let reader = PickyCronJobReader(
            preferences: .init(codingAgentDir: root.path), homeURL: root, environment: [:]
        )
        guard case .jobs(let presentations) = reader.read() else {
            Issue.record("Expected temporary Cron JSON to decode")
            return []
        }
        return presentations
    }
}
