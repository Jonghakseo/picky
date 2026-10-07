//
//  PickyHubStatisticsHighlightsTests.swift
//  PickyTests
//
//  Contracts for the rhythm, badge, and hall-of-fame tabs: what a user sees
//  as a streak, when a badge counts as earned, and who leads each record.
//

import Foundation
import Testing
@testable import Picky

struct PickyHubStatisticsHighlightsTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar.firstWeekday = 2
        return calendar
    }()

    // MARK: Rhythm

    @Test func streakSurvivesAnUnstartedTodayAndRemembersTheLongestRun() {
        let now = date("2026-07-16T09:00:00Z")
        let records = ["07-01", "07-02", "07-03", "07-04", "07-13", "07-14", "07-15"].map {
            record(id: $0, created: date("2026-\($0)T10:00:00Z"))
        }

        let activity = PickyHubRhythmPolicy.activityCalendar(records: records, weekCount: 3, now: now, calendar: calendar)

        // Nothing yet on the 16th, so the run through yesterday still counts.
        #expect(activity.currentStreak == 3)
        #expect(activity.longestStreak == 4)
        // A one-day gap resets the current streak.
        let broken = PickyHubRhythmPolicy.activityCalendar(records: records, weekCount: 1, now: date("2026-07-17T09:00:00Z"), calendar: calendar)
        #expect(broken.currentStreak == 0)
    }

    @Test func calendarStopsAtTodayWhileTotalsCoverTheWholeHistory() {
        // Thursday, 2026-07-16; weeks start on Monday.
        let now = date("2026-07-16T09:00:00Z")
        let records = [
            record(id: "old", created: date("2026-06-01T10:00:00Z")),
            record(id: "mon-a", created: date("2026-07-13T10:00:00Z")),
            record(id: "mon-b", created: date("2026-07-13T11:00:00Z")),
            record(id: "today", created: date("2026-07-16T08:00:00Z"))
        ]

        let activity = PickyHubRhythmPolicy.activityCalendar(records: records, weekCount: 2, now: now, calendar: calendar)

        #expect(activity.weeks.count == 2)
        let currentWeek = activity.weeks[1]
        #expect(currentWeek.map { $0?.count } == [2, 0, 0, 1, nil, nil, nil])
        // The June Pickle is outside the shown weeks but still counts toward the totals.
        #expect(activity.pickleCount == 4)
        #expect(activity.activeDayCount == 3)
        #expect(activity.level(for: currentWeek[0]!) == 4)
        #expect(activity.level(for: currentWeek[1]!) == 0)
    }

    @Test func hourPatternFindsTheBusiestThreeHoursAndLateNightAndWeekendShares() {
        let records = [
            record(id: "a", created: date("2026-07-13T14:10:00Z")),
            record(id: "b", created: date("2026-07-13T15:10:00Z")),
            record(id: "c", created: date("2026-07-14T16:10:00Z")),
            record(id: "d", created: date("2026-07-14T09:00:00Z")),
            record(id: "late", created: date("2026-07-15T01:30:00Z")),
            record(id: "saturday", created: date("2026-07-18T20:00:00Z"))
        ]

        let pattern = PickyHubRhythmPolicy.hourPattern(records: records, calendar: calendar)

        #expect(pattern.total == 6)
        #expect(pattern.peakStartHour == 14)
        #expect(pattern.share(pattern.peakCount) == 50)
        #expect(pattern.lateNightCount == 1)
        #expect(pattern.weekendCount == 1)
    }

    // MARK: Badges

    @Test func badgesRecordTheMomentEachThresholdWasFirstCrossed() throws {
        let now = date("2026-07-20T12:00:00Z")
        let streakDays = (1...8).map { record(id: "day-\($0)", created: date(String(format: "2026-07-%02dT10:00:00Z", $0))) }
        let nightOwls = (0..<10).map { record(id: "night-\($0)", created: date("2026-06-10T02:\(String(format: "%02d", $0)):00Z"), followUps: 1) }
        let snapshot = PickyHubStatisticsSnapshot(
            generatedAt: now,
            records: streakDays + nightOwls,
            usageSamples: [
                usage(day: "2026-07-01", tokens: 600_000),
                usage(day: "2026-07-03", tokens: 500_000),
                usage(day: "2026-07-05", tokens: 900_000)
            ],
            pendingClassificationCount: 0
        )

        let board = PickyHubBadgePolicy.board(snapshot: snapshot, now: now, calendar: calendar)
        let badge = { (kind: PickyHubBadgeKind) in board.badges.first { $0.kind == kind }! }

        #expect(badge(.firstPickle).earnedAt == date("2026-06-10T02:00:00Z"))
        #expect(badge(.nightOwl).earnedAt == date("2026-06-10T02:09:00Z"))
        #expect(badge(.weekStreak).earnedAt == date("2026-07-07T00:00:00Z"))
        #expect(badge(.millionTokens).earnedAt == date("2026-07-03T00:00:00Z"))
        // Progress is capped at the target once earned.
        #expect(badge(.millionTokens).progress == 1_000_000)
        // The streak ended on the 8th, so the 30-day badge shows no live progress.
        #expect(badge(.monthStreak).earnedAt == nil)
        #expect(badge(.monthStreak).progress == 0)
        // Ten night Pickles had follow-ups; the eight daily ones did not.
        #expect(badge(.noFollowUp).progress == 8)
        // The ten night Pickles all started on one day.
        #expect(badge(.busyDay).earnedAt == date("2026-06-10T02:09:00Z"))
        #expect(board.earnedCount == 5)
    }

    @Test func announcesOnlyARecentBadgeAndPointsToTheClosestUnearnedGoal() {
        let records = (0..<4).map { record(id: "p\($0)", created: date("2026-07-1\($0)T10:00:00Z"), project: "project-\($0)") }
        let snapshot = PickyHubStatisticsSnapshot(generatedAt: .distantPast, records: records, usageSamples: [], pendingClassificationCount: 0)

        let fresh = PickyHubBadgePolicy.board(snapshot: snapshot, now: date("2026-07-14T12:00:00Z"), calendar: calendar)
        // The first Pickle on 07-10 is within the seven-day announcement window.
        #expect(fresh.recentlyEarned?.kind == .firstPickle)
        // Four of five projects is the furthest along.
        #expect(fresh.nextGoal?.kind == .explorer)

        let stale = PickyHubBadgePolicy.board(snapshot: snapshot, now: date("2026-08-30T12:00:00Z"), calendar: calendar)
        #expect(stale.recentlyEarned == nil)
    }

    @Test func recordedBadgesStayEarnedAndUnfinishedPicklesDoNotCountAsOneAndDone() {
        let now = date("2026-07-20T12:00:00Z")
        var running = record(id: "running", created: date("2026-07-19T10:00:00Z"))
        running.status = "running"
        var failed = record(id: "failed", created: date("2026-07-19T11:00:00Z"))
        failed.status = "failed"
        var done = record(id: "done", created: date("2026-07-19T12:00:00Z"))
        done.status = "completed"
        let snapshot = PickyHubStatisticsSnapshot(generatedAt: now, records: [running, failed, done], usageSamples: [], pendingClassificationCount: 0)
        let recorded = date("2026-05-01T09:00:00Z")

        let board = PickyHubBadgePolicy.board(snapshot: snapshot, earned: [.explorer: recorded], now: now, calendar: calendar)
        let badge = { (kind: PickyHubBadgeKind) in board.badges.first { $0.kind == kind }! }

        #expect(badge(.noFollowUp).progress == 1)
        // One project today, but explorer was earned before and stays earned at its first date.
        #expect(badge(.explorer).earnedAt == recorded)
        #expect(badge(.explorer).progress == PickyHubBadgeKind.explorer.target)
    }

    @Test func hourPatternPeriodMatchesStartTimeNotLastActivity() {
        let now = date("2026-07-16T12:00:00Z")
        var revived = record(id: "revived", created: date("2026-04-01T02:00:00Z"))
        revived = PickyHubPickleRecord(
            id: revived.id, title: revived.title, project: "picky", cwd: nil,
            createdAt: revived.createdAt, lastActivityAt: date("2026-07-15T10:00:00Z"),
            followUpCount: 0, delegationCount: 0, reviewCount: 0, category: .fix
        )
        let fresh = record(id: "fresh", created: date("2026-07-14T09:00:00Z"))
        let snapshot = PickyHubStatisticsSnapshot(generatedAt: now, records: [revived, fresh], usageSamples: [], pendingClassificationCount: 0)
        let filter = PickyHubStatisticsFilter(period: .lastSevenDays)

        #expect(PickyHubStatisticsAggregator.records(in: snapshot, filter: filter, now: now, calendar: calendar).count == 2)
        #expect(PickyHubStatisticsAggregator.startedRecords(in: snapshot, filter: filter, now: now, calendar: calendar).map(\.id) == ["fresh"])
    }

    // MARK: Hall of fame

    @Test func hallOfFameTotalsThisMonthByStartAndOmitsEmptyRecords() throws {
        let now = date("2026-07-16T12:00:00Z")
        var june = record(id: "june", created: date("2026-06-20T10:00:00Z"))
        june.changedFileCount = 10
        june.toolCallCount = 40
        june.activeDurationMs = 3_600_000
        var julyA = record(id: "july-a", created: date("2026-07-02T10:00:00Z"))
        julyA.changedFileCount = 3
        julyA.artifactCount = 2
        julyA.activeDurationMs = 3_600_000
        var julyB = record(id: "july-b", created: date("2026-07-10T10:00:00Z"), followUps: 4)
        julyB.subagentCount = 5

        let fame = PickyHubHallOfFamePolicy.hallOfFame(records: [june, julyA, julyB], now: now, calendar: calendar)

        #expect(fame.allTime == PickyHubResultTotals(changedFiles: 13, artifacts: 2, toolCalls: 40, subagents: 5))
        #expect(fame.thisMonth == PickyHubResultTotals(changedFiles: 3, artifacts: 2, toolCalls: 0, subagents: 5))
        // Tied durations go to the more recent Pickle; no one used tokens, so that record is absent.
        #expect(fame.awards.map(\.kind) == [.longestWork, .mostChangedFiles, .mostSubagents, .mostFollowUps])
        #expect(fame.awards.map(\.record.id) == ["july-a", "june", "july-b", "july-b"])

        // A record stamped in the future counts neither toward totals nor awards.
        var future = record(id: "future", created: date("2026-08-01T10:00:00Z"))
        future.activeDurationMs = 99_000_000
        let withFuture = PickyHubHallOfFamePolicy.hallOfFame(records: [june, julyA, julyB, future], now: now, calendar: calendar)
        #expect(withFuture.awards.first { $0.kind == .longestWork }?.record.id == "july-a")
    }

    @Test func recordsFromOlderDaemonsDecodeWithoutResultFields() throws {
        let json = """
        {"id":"p","title":"T","project":"picky","createdAt":"2026-07-01T00:00:00Z","lastActivityAt":"2026-07-01T00:00:00Z",
         "followUpCount":1,"delegationCount":0,"reviewCount":0,"category":"fix"}
        """
        let record = try JSONDecoder.pickyAgentProtocolDecoder().decode(PickyHubPickleRecord.self, from: Data(json.utf8))
        #expect(record.followUpCount == 1)
        #expect(record.changedFileCount == 0 && record.activeDurationMs == 0 && record.totalTokens == 0)
    }

    // MARK: Fixtures

    private func record(id: String, created: Date, project: String = "picky", followUps: Int = 0) -> PickyHubPickleRecord {
        PickyHubPickleRecord(
            id: id, title: id, project: project, cwd: nil,
            createdAt: created, lastActivityAt: created,
            followUpCount: followUps, delegationCount: 0, reviewCount: 0, category: .fix
        )
    }

    private func usage(day: String, tokens: Int) -> PickyHubUsageSample {
        PickyHubUsageSample(day: day, provider: "anthropic", model: "m", project: "picky", inputTokens: tokens, outputTokens: 0, cacheTokens: 0)
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
