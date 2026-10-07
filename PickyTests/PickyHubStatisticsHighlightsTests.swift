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
        #expect(board.earnedCount == 6)
        #expect(badge(.weekdayCollector).earnedAt == date("2026-07-07T10:00:00Z"))
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

    @Test func timeBadgesUseLocalHoursAndExcludeFutureStarts() {
        var local = calendar
        local.timeZone = TimeZone(secondsFromGMT: 9 * 60 * 60)!
        let now = date("2026-07-18T05:00:00Z") // Saturday, 14:00 in the local calendar.
        let starts = ["2026-07-17T19:59:00Z", // 04:59, neither morning nor lunch.
                      "2026-07-17T20:00:00Z", // 05:00
                      "2026-07-17T23:59:00Z", // 08:59
                      "2026-07-18T00:00:00Z", // 09:00, outside the morning range.
                      "2026-07-18T02:59:00Z", // 11:59
                      "2026-07-18T03:00:00Z", // 12:00
                      "2026-07-18T04:59:00Z", // 13:59
                      "2026-07-18T05:00:00Z", // 14:00, outside the lunch range.
                      "2026-07-19T03:00:00Z"] // Tomorrow, ignored even though it is a weekend.
        let records = starts.enumerated().map { record(id: "time-\($0.offset)", created: date($0.element)) }
        let board = PickyHubBadgePolicy.board(snapshot: snapshot(records, now: now), now: now, calendar: local)
        #expect(board.badges.first { $0.kind == .earlyBird }?.progress == 2)
        #expect(board.badges.first { $0.kind == .lunchBreak }?.progress == 2)
        #expect(board.badges.first { $0.kind == .weekend }?.progress == 8)
        #expect(board.badges.first { $0.kind == .earlyBird }?.isEarned == false)
    }

    @Test func timeBadgesEarnOnTheTenthMatchingStart() {
        let now = date("2026-07-20T12:00:00Z")
        let mornings = (0..<10).map { record(id: "morning-\($0)", created: date("2026-07-18T05:\(String(format: "%02d", $0)):00Z")) }
        let lunches = (0..<10).map { record(id: "lunch-\($0)", created: date("2026-07-18T12:\(String(format: "%02d", $0)):00Z")) }
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(mornings.prefix(9)), now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .earlyBird }?.progress == 9)
        #expect(before.badges.first { $0.kind == .weekend }?.isEarned == false)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot((mornings + lunches).reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .earlyBird }?.earnedAt == mornings.last?.createdAt)
        #expect(after.badges.first { $0.kind == .lunchBreak }?.earnedAt == lunches.last?.createdAt)
        #expect(after.badges.first { $0.kind == .weekend }?.earnedAt == mornings.last?.createdAt)
    }

    @Test func pickleJarCountsAllStartsButRegularSpotCountsOneProject() {
        let start = date("2026-07-01T10:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        let records = (0..<100).map { record(id: "jar-\($0)", created: start.addingTimeInterval(Double($0) * 60), project: $0.isMultiple(of: 2) ? "a" : "b") }
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(records.prefix(98)), now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .hundredPickles }?.progress == 98)
        #expect(before.badges.first { $0.kind == .hundredPickles }?.isEarned == false)
        #expect(before.badges.first { $0.kind == .homeGround }?.progress == 49)
        #expect(before.badges.first { $0.kind == .homeGround }?.isEarned == false)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot(records.reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .hundredPickles }?.earnedAt == records[99].createdAt)
        #expect(after.badges.first { $0.kind == .homeGround }?.earnedAt == records[98].createdAt)
    }

    @Test func collectorsCountDistinctHoursAndWeekdaysNotRepeatedPickles() {
        let now = date("2026-07-20T12:00:00Z")
        let hours = (0..<24).map { record(id: "hour-\($0)", created: date("2026-07-13T\(String(format: "%02d", $0)):00:00Z")) }
        let repeated = (0..<30).map { record(id: "repeat-\($0)", created: date("2026-07-13T10:30:00Z")) }
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(hours.prefix(23)) + repeated, now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .aroundTheClock }?.progress == 23)
        #expect(before.badges.first { $0.kind == .aroundTheClock }?.isEarned == false)
        #expect(before.badges.first { $0.kind == .weekdayCollector }?.progress == 1)
        let days = (14...19).map { record(id: "weekday-\($0)", created: date("2026-07-\($0)T10:00:00Z")) }
        let after = PickyHubBadgePolicy.board(snapshot: snapshot((hours + repeated + days).reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .aroundTheClock }?.earnedAt == hours.last?.createdAt)
        #expect(after.badges.first { $0.kind == .weekdayCollector }?.earnedAt == days.last?.createdAt)
    }

    @Test func singlePickleBadgesDoNotSumAcrossPicklesOrBackdateResults() {
        let start = date("2026-07-01T10:00:00Z")
        let finished = date("2026-07-02T11:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        func result(_ id: String, followUps: Int, subagents: Int, tools: Int, files: Int, at: Date) -> PickyHubPickleRecord {
            var record = PickyHubPickleRecord(
                id: id, title: id, project: "picky", cwd: nil, createdAt: start, lastActivityAt: at,
                followUpCount: followUps, delegationCount: 0, reviewCount: 0, category: .fix
            )
            record.status = "completed"
            record.subagentCount = subagents
            record.toolCallCount = tools
            record.changedFileCount = files
            return record
        }
        let partials = (0..<2).map { result("partial-\($0)", followUps: 9, subagents: 4, tools: 99, files: 19, at: start) }
        let future = result("future", followUps: 99, subagents: 99, tools: 999, files: 99, at: now.addingTimeInterval(60))
        let kinds: [PickyHubBadgeKind] = [.conversation, .team, .toolMaster, .renovator]
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(partials + [future], now: now), now: now, calendar: calendar)
        for (kind, progress) in zip(kinds, [9, 4, 99, 19]) {
            #expect(before.badges.first { $0.kind == kind }?.progress == progress)
            #expect(before.badges.first { $0.kind == kind }?.isEarned == false)
        }
        let winner = result("winner", followUps: 10, subagents: 5, tools: 100, files: 20, at: finished)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot([future, winner] + partials, now: now), now: now, calendar: calendar)
        for kind in kinds {
            #expect(after.badges.first { $0.kind == kind }?.earnedAt == finished)
            #expect(after.badges.first { $0.kind == kind }?.progress == kind.target)
        }
    }

    @Test func resultBadgesRequireCompletedPicklesAndCountArtifactPicklesNotArtifacts() {
        let now = date("2026-07-20T12:00:00Z")
        let records = (0..<10).map { index -> PickyHubPickleRecord in
            var record = record(id: "treasure-\(index)", created: date("2026-07-01T10:00:00Z").addingTimeInterval(Double(index) * 60))
            record.status = "completed"
            record.artifactCount = 100
            return record
        }
        var running = record(id: "running-result", created: date("2026-07-01T11:00:00Z"))
        running.status = "running"
        running.artifactCount = 100
        running.changedFileCount = 20
        var failed = running
        failed.status = "failed"
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(records.prefix(9)) + [running, failed], now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .treasureHunter }?.progress == 9)
        #expect(before.badges.first { $0.kind == .treasureHunter }?.isEarned == false)
        #expect(before.badges.first { $0.kind == .renovator }?.progress == 0)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot(records, now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .treasureHunter }?.earnedAt == records.last?.lastActivityAt)
        #expect(after.badges.first { $0.kind == .treasureHunter }?.progress == 10)
    }

    @Test func pickleMasterCountsOnlyFinishedPicklesAndEarnsOnTheFiveHundredthCompletion() {
        let start = date("2026-07-01T10:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        let completed = (0..<501).map { index -> PickyHubPickleRecord in
            var record = PickyHubPickleRecord(
                id: "master-\(index)", title: "Done", project: "picky", cwd: nil,
                createdAt: start, lastActivityAt: start.addingTimeInterval(Double(index + 1) * 60),
                followUpCount: 0, delegationCount: 0, reviewCount: 0, category: .fix
            )
            record.status = "completed"
            return record
        }
        let excluded = ["running", "failed", "aborted", "completed"].enumerated().map { index, status -> PickyHubPickleRecord in
            var record = record(id: "excluded-\(index)", created: start)
            record.status = status
            if status == "completed" {
                record = PickyHubPickleRecord(
                    id: record.id, title: record.title, project: record.project, cwd: nil,
                    createdAt: start, lastActivityAt: now.addingTimeInterval(60),
                    followUpCount: 0, delegationCount: 0, reviewCount: 0, category: .fix, status: status
                )
            }
            return record
        }
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(completed.prefix(499)) + excluded, now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .pickleMaster }?.progress == 499)
        #expect(before.badges.first { $0.kind == .pickleMaster }?.isEarned == false)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot(completed.reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .pickleMaster }?.earnedAt == completed[499].lastActivityAt)
        #expect(after.badges.first { $0.kind == .pickleMaster }?.progress == 500)
    }

    @Test func hundredDaysCountsDistinctDaysWithoutRequiringAStreak() {
        let start = date("2026-01-01T10:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        let days = (0..<100).map { record(id: "hundred-day-\($0)", created: calendar.date(byAdding: .day, value: $0 * 2, to: start)!) }
        let sameDay = (0..<100).map { record(id: "same-day-\($0)", created: start.addingTimeInterval(Double($0))) }
        let future = record(id: "future-day", created: date("2026-07-21T10:00:00Z"))
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(days.prefix(99)) + sameDay + [future], now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .hundredDays }?.progress == 99)
        #expect(before.badges.first { $0.kind == .hundredDays }?.isEarned == false)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot((days + sameDay).reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .hundredDays }?.earnedAt == calendar.startOfDay(for: days[99].createdAt))
        #expect(after.badges.first { $0.kind == .hundredDays }?.progress == 100)
        #expect(after.badges.first { $0.kind == .monthStreak }?.isEarned == false)
    }

    @Test func worldExplorerNeedsTwentyDistinctProjectsAndTheBoardContainsTwentyFourBadges() {
        let start = date("2026-07-01T10:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        let projects = (0..<20).map { record(id: "explore-\($0)", created: start.addingTimeInterval(Double($0) * 60), project: "project-\($0)") }
        let repeats = (0..<30).map { record(id: "repeat-project-\($0)", created: start, project: "project-0") }
        let future = record(id: "future-project", created: now.addingTimeInterval(60), project: "future")
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(Array(projects.prefix(19)) + repeats + [future], now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .worldExplorer }?.progress == 19)
        #expect(before.badges.first { $0.kind == .worldExplorer }?.isEarned == false)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot((projects + repeats).reversed(), now: now), now: now, calendar: calendar)
        #expect(after.badges.count == 24)
        #expect(after.badges.first { $0.kind == .worldExplorer }?.earnedAt == projects[19].createdAt)
        #expect(after.badges.first { $0.kind == .worldExplorer }?.progress == 20)
    }

    @Test func majorRenovationRequiresOneCompletedPickleWithOneHundredChangedFiles() {
        let start = date("2026-07-01T10:00:00Z")
        let finished = date("2026-07-02T11:00:00Z")
        let now = date("2026-07-20T12:00:00Z")
        func result(_ id: String, files: Int, status: String, at: Date) -> PickyHubPickleRecord {
            PickyHubPickleRecord(
                id: id, title: id, project: "picky", cwd: nil, createdAt: start, lastActivityAt: at,
                followUpCount: 0, delegationCount: 0, reviewCount: 0, category: .fix,
                status: status, changedFileCount: files
            )
        }
        let partials = [result("partial-a", files: 99, status: "completed", at: start),
                        result("partial-b", files: 99, status: "completed", at: finished)]
        let excluded = [result("running", files: 1000, status: "running", at: start),
                        result("failed", files: 1000, status: "failed", at: start),
                        result("future", files: 1000, status: "completed", at: now.addingTimeInterval(60))]
        let before = PickyHubBadgePolicy.board(snapshot: snapshot(partials + excluded, now: now), now: now, calendar: calendar)
        #expect(before.badges.first { $0.kind == .majorRenovation }?.progress == 99)
        #expect(before.badges.first { $0.kind == .majorRenovation }?.isEarned == false)
        let winner = result("winner", files: 100, status: "completed", at: finished)
        let after = PickyHubBadgePolicy.board(snapshot: snapshot([winner] + partials + excluded, now: now), now: now, calendar: calendar)
        #expect(after.badges.first { $0.kind == .majorRenovation }?.earnedAt == finished)
        #expect(after.badges.first { $0.kind == .majorRenovation }?.progress == 100)
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

    private func snapshot(_ records: [PickyHubPickleRecord], now: Date) -> PickyHubStatisticsSnapshot {
        PickyHubStatisticsSnapshot(generatedAt: now, records: records, usageSamples: [], pendingClassificationCount: 0)
    }

    private func usage(day: String, tokens: Int) -> PickyHubUsageSample {
        PickyHubUsageSample(day: day, provider: "anthropic", model: "m", project: "picky", inputTokens: tokens, outputTokens: 0, cacheTokens: 0)
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
