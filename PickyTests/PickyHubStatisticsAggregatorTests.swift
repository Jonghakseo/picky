//
//  PickyHubStatisticsAggregatorTests.swift
//  PickyTests
//

import Foundation
import Testing
@testable import Picky

struct PickyHubStatisticsAggregatorTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    @Test func filtersRecordsAtThePeriodBoundaryAndByProject() {
        let now = date("2026-07-16T12:00:00Z")
        let snapshot = PickyHubStatisticsSnapshot(
            generatedAt: now,
            records: [
                record(id: "before", project: "picky", activity: date("2026-07-12T23:59:59Z")),
                record(id: "boundary", project: "picky", activity: date("2026-07-13T00:00:00Z")),
                record(id: "other-project", project: "site", activity: date("2026-07-16T11:00:00Z"))
            ],
            usageSamples: [],
            pendingClassificationCount: 0
        )

        let result = PickyHubStatisticsAggregator.records(
            in: snapshot,
            filter: .init(period: .thisWeek, project: "picky"),
            now: now,
            calendar: calendar
        )

        #expect(result.map(\.id) == ["boundary"])
    }

    @Test func choosesInsightsDeterministicallyForTies() {
        let earlier = date("2026-07-14T10:00:00Z")
        let later = date("2026-07-15T10:00:00Z")
        let records = [
            record(id: "fix", title: "Fix", project: "alpha", activity: earlier, followUps: 3, delegations: 2, category: .fix),
            record(id: "research", title: "Research", project: "beta", activity: later, followUps: 3, delegations: 2, category: .research),
            record(id: "create", title: "Create", project: "alpha", activity: earlier, category: .create),
            record(id: "review", title: "Review", project: "beta", activity: earlier, category: .review)
        ]

        let insights = PickyHubStatisticsAggregator.workInsights(for: records)

        #expect(insights.topCategory?.category == .fix)
        #expect(insights.deepestPickle?.record.id == "research")
        #expect(insights.focusedProject?.project == "alpha")
        #expect(insights.distribution.map(\.category) == [.fix, .research, .create, .review])
    }

    @Test func aggregatesUsageForPeriodAndProject() {
        let now = date("2026-07-16T12:00:00Z")
        let snapshot = PickyHubStatisticsSnapshot(
            generatedAt: now,
            records: [],
            usageSamples: [
                usage(day: "2026-07-14", project: "picky", input: 10, output: 5, cache: 2),
                usage(day: "2026-07-15", project: "picky", input: 20, output: 10, cache: 4),
                usage(day: "2026-07-15", project: "other", input: 100, output: 100, cache: 100),
                usage(day: "2026-07-12", project: "picky", input: 100, output: 100, cache: 100)
            ],
            pendingClassificationCount: 0
        )

        let summary = PickyHubStatisticsAggregator.usageSummary(
            in: snapshot,
            filter: .init(period: .thisWeek, project: "picky"),
            now: now,
            calendar: calendar
        )

        #expect(summary.inputTokens == 30)
        #expect(summary.outputTokens == 15)
        #expect(summary.cacheTokens == 6)
        #expect(summary.totalTokens == 51)
        #expect(summary.days.map(\.day) == ["2026-07-14", "2026-07-15"])
        #expect(summary.models.count == 1)
    }

    @Test func fillsContinuousDaysForTheCurrentWeek() {
        let now = date("2026-07-16T12:00:00Z")
        let days = [
            PickyHubUsageDay(day: "2026-07-13", totalTokens: 10),
            PickyHubUsageDay(day: "2026-07-15", totalTokens: 30)
        ]

        let result = PickyHubStatisticsAggregator.continuousDays(days, period: .thisWeek, now: now, calendar: calendar)

        #expect(result.map(\.day) == ["2026-07-13", "2026-07-14", "2026-07-15", "2026-07-16", "2026-07-17", "2026-07-18", "2026-07-19"])
        #expect(result.map(\.totalTokens) == [10, 0, 30, 0, 0, 0, 0])
    }

    @Test func dateConversionRespectsTheRequestedTimeZoneAndRejectsInvalidDays() {
        var pacific = calendar
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let instant = date("2026-07-13T03:00:00Z")
        #expect(PickyHubStatisticsAggregator.dayString(instant, calendar: pacific) == "2026-07-12")
        #expect(PickyHubStatisticsAggregator.dayString(instant, calendar: calendar) == "2026-07-13")
        #expect(PickyHubStatisticsAggregator.date(fromDay: "2026-02-30", calendar: calendar) == nil)
        #expect(PickyHubStatisticsAggregator.date(fromDay: "2026-07-13", calendar: pacific) == date("2026-07-13T07:00:00Z"))
    }

    @Test func chartCombinesDuplicateDaysWithoutTrapping() {
        let result = PickyHubStatisticsAggregator.continuousDays([
            .init(day: "2026-07-13", totalTokens: 10),
            .init(day: "2026-07-13", totalTokens: 20)
        ], period: .thisWeek, now: date("2026-07-16T12:00:00Z"), calendar: calendar)
        #expect(result.first?.totalTokens == 30)
        #expect(result.count == 7)
    }

    @Test func projectFilterIncludesMainAgentUsageWithoutPickleRecords() {
        let snapshot = PickyHubStatisticsSnapshot(generatedAt: date("2026-07-16T12:00:00Z"), records: [], usageSamples: [
            usage(day: "2026-07-15", project: "Picky", input: 10, output: 5, cache: 0)
        ], pendingClassificationCount: 0)
        #expect(PickyHubStatisticsAggregator.projects(in: snapshot) == ["Picky"])
    }

    private func record(
        id: String,
        title: String = "Task",
        project: String,
        activity: Date,
        followUps: Int = 0,
        delegations: Int = 0,
        category: PickyHubWorkCategory = .fix
    ) -> PickyHubPickleRecord {
        PickyHubPickleRecord(
            id: id,
            title: title,
            project: project,
            cwd: nil,
            createdAt: activity,
            lastActivityAt: activity,
            followUpCount: followUps,
            delegationCount: delegations,
            reviewCount: 0,
            category: category
        )
    }

    private func usage(day: String, project: String, input: Int, output: Int, cache: Int) -> PickyHubUsageSample {
        PickyHubUsageSample(day: day, provider: "Anthropic", model: "Sonnet", project: project, inputTokens: input, outputTokens: output, cacheTokens: cache)
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
