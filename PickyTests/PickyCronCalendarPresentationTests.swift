import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyCronCalendarPresentationTests {
    @Test func initialHourTargetsUpcomingJobInsteadOfMidnight() throws {
        let now = Date(timeIntervalSince1970: 1_789_696_800)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: now)
        let morning = day.addingTimeInterval(10 * 3600)
        let afternoon = day.addingTimeInterval(15 * 3600)
        let events = [
            PickyCronCalendarOccurrence(job: job(), date: morning, kind: .actual),
            PickyCronCalendarOccurrence(job: job(), date: afternoon, kind: .next)
        ]
        #expect(PickyCronCalendarPresentation.initialHour(occurrences: events, now: day.addingTimeInterval(12 * 3600), calendar: calendar) == 14)
        #expect(PickyCronCalendarPresentation.initialHour(occurrences: [events[0]], now: afternoon, calendar: calendar) == 9)
    }

    @Test func scheduleDescribesCommonRulesWithoutExposingCronSyntax() {
        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyCronCalendarPresentation.schedule(job("30 10,20 * * *")) == "매일 10:30, 20:30")
            #expect(PickyCronCalendarPresentation.schedule(job("0 9 * * 1-5")) == "평일 09:00")
            #expect(PickyCronCalendarPresentation.schedule(job("*/15 * * * *")) == "15분마다 실행")
            #expect(PickyCronCalendarPresentation.schedule(job("0 9 1 * *")) == "사용자 지정 반복")
        }
    }

    @Test func executionStatusComesFromTheOccurrenceNotTheJobsLastResult() {
        let failed = PickyCronCalendarOccurrence(job: job(), date: Date(), kind: .actual,
            execution: .init(date: Date(), exitCode: 1))
        let success = PickyCronCalendarOccurrence(job: job(), date: Date(), kind: .actual,
            execution: .init(date: Date(), exitCode: 0))
        LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyCronCalendarPresentation.status(failed) == "실패")
            #expect(PickyCronCalendarPresentation.status(success) == "완료")
        }
    }

    @Test func groupedExecutionsDoNotHideFailureBehindEarlierSuccess() {
        let date = Date(timeIntervalSince1970: 100)
        let events = [0, 0, 1].enumerated().map { index, code in
            PickyCronCalendarOccurrence(job: job(), date: date.addingTimeInterval(Double(index)), kind: .actual,
                execution: .init(date: date.addingTimeInterval(Double(index)), exitCode: code))
        }
        let groups = PickyCronCalendarPresentation.groups(events)
        #expect(groups.count == 2)
        #expect(groups.map(\.count) == [2, 1])
        #expect(groups[0].occurrences.map { $0.execution?.exitCode } == [0, 0])
        #expect(groups[1].occurrences.map { $0.execution?.exitCode } == [1])
        #expect(groups.map { $0.event.execution?.exitCode } == [0, 1])
    }

    @Test func hourlyGroupsOnlyOfferTheOccurrencesShownInThatCell() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_789_696_800))
        let input = PickyCronCalendarInput(jobs: [job("*/10 * * * *")],
            interval: .init(start: day, duration: 86400), now: day.addingTimeInterval(-1), calendar: calendar)
        let layout = PickyCronCalendarLayout(input)
        let group = try #require(layout.hourGroups[day]?[14]?.first)
        #expect(group.count == 6)
        #expect(group.occurrences.map { calendar.component(.minute, from: $0.date) } == [0, 10, 20, 30, 40, 50])
        #expect(group.occurrences.allSatisfy { calendar.component(.hour, from: $0.date) == 14 })
        #expect(layout.eventsByDay[day]?.count == 144)
    }

    @Test func calendarDataReplacesOccurrencesWhenJobsOrFiltersChange() {
        let day = Calendar.current.startOfDay(for: Date())
        var input = PickyCronCalendarInput(jobs: [job("*/10 * * * *")],
            interval: .init(start: day, duration: 86400), now: day)
        let data = PickyCronCalendarData(input)
        #expect(!data.layout.events.isEmpty)
        input.showsRepeating = false
        data.update(input)
        #expect(data.layout.events.isEmpty)
        input.showsRepeating = true
        data.update(input)
        #expect(!data.layout.events.isEmpty)
        input.jobs = []
        data.update(input)
        #expect(data.layout.events.isEmpty)
        #expect(data.layout.dayGroups.isEmpty)
        #expect(data.layout.hourGroups.isEmpty)
    }

    private func job(_ schedule: String = "0 9 * * *") -> PickyCronJobPresentation {
        .init(id: "test", name: "Calendar job", status: .active, enabled: true, schedule: schedule,
              runAtText: nil, nextRunAt: nil, lastRunAt: nil, completedAt: nil, lastExitCode: 0)
    }
}
