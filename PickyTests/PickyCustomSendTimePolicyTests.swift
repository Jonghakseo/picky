//
//  PickyCustomSendTimePolicyTests.swift
//  PickyTests
//
//  Contract for the send-timing "custom time" editor: what typed times mean,
//  which days and slots are offered, and when Schedule is allowed.
//

import Foundation
import Testing
@testable import Picky

@MainActor
struct PickyCustomSendTimePolicyTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Seoul")!
        calendar.firstWeekday = 1
        return calendar
    }()
    private let locale = Locale(identifier: "ko_KR")

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0, month: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Saturday 2026-10-03 14:29.
    private var now: Date { date(3, 14, 29) }

    private func resolve(_ text: String, on day: Date? = nil) -> PickyCustomSendTimeResolution {
        var draft = PickyCustomSendTimePolicy.makeDraft(now: now, calendar: calendar, locale: locale)
        draft.day = calendar.startOfDay(for: day ?? now)
        draft.timeText = text
        return PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar)
    }

    @Test func acceptsCommonWaysOfTypingATime() {
        #expect(resolve("15:30") == .valid(date(3, 15, 30)))
        #expect(resolve("1530") == .valid(date(3, 15, 30)))
        #expect(resolve("오후 3시") == .valid(date(3, 15, 0)))
        #expect(resolve("3시 반") == .valid(date(3, 15, 30)))
        #expect(resolve("3:30pm") == .valid(date(3, 15, 30)))
        #expect(resolve("오후 3:07") == .valid(date(3, 15, 7)))
        #expect(resolve("23") == .valid(date(3, 23, 0)))
    }

    @Test func rejectsTextThatIsNotATime() {
        for text in ["", "abc", "25:00", "3:70", "오후 13시", "오전 오후 3시", "3:7"] {
            #expect(resolve(text) == .invalidTime, "\(text)")
        }
    }

    /// Without 오전/오후, "3:07" at 14:29 means this afternoon, not 3am.
    @Test func hourWithoutMeridiemPicksTheNextOccurrenceOnTheChosenDay() {
        #expect(resolve("3:07") == .valid(date(3, 15, 7)))
        #expect(resolve("9") == .valid(date(3, 21, 0)))
        // On a future day the earlier reading is already ahead.
        #expect(resolve("9", on: date(4, 0)) == .valid(date(4, 9, 0)))
        // 12 stays noon; 0 is midnight.
        #expect(resolve("12:30", on: date(4, 0)) == .valid(date(4, 12, 30)))
        #expect(resolve("0:15", on: date(4, 0)) == .valid(date(4, 0, 15)))
    }

    @Test func aTimeAlreadyBehindNowCannotBeScheduled() {
        #expect(resolve("오전 9시") == .past)
        #expect(resolve("14:29") == .past)
        #expect(resolve("14:30") == .valid(date(3, 14, 30)))
    }

    @Test func committingNormalizesReadableTextAndFlagsTheRest() {
        var draft = PickyCustomSendTimePolicy.makeDraft(now: now, calendar: calendar, locale: locale)
        draft.timeText = "1507"
        PickyCustomSendTimePolicy.commitTimeText(&draft, now: now, calendar: calendar, locale: locale)
        #expect(draft.timeText == PickyCustomSendTimePolicy.timeText(for: date(3, 15, 7), calendar: calendar, locale: locale))
        #expect(!draft.showsTimeError)

        draft.timeText = "25:70"
        PickyCustomSendTimePolicy.commitTimeText(&draft, now: now, calendar: calendar, locale: locale)
        #expect(draft.showsTimeError)
        #expect(draft.timeText == "25:70")

        // Picking a slot replaces the bad text and clears the error.
        PickyCustomSendTimePolicy.selectSlot(date(3, 16, 15), in: &draft, calendar: calendar, locale: locale)
        #expect(!draft.showsTimeError)
        #expect(PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar) == .valid(date(3, 16, 15)))
    }

    @Test func editorOpensOnTheNextFullHour() {
        let draft = PickyCustomSendTimePolicy.makeDraft(now: now, calendar: calendar, locale: locale)
        #expect(PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar) == .valid(date(3, 15, 0)))

        let lateNight = date(3, 23, 30)
        let overnight = PickyCustomSendTimePolicy.makeDraft(now: lateNight, calendar: calendar, locale: locale)
        #expect(overnight.day == date(4, 0))
        #expect(PickyCustomSendTimePolicy.resolve(overnight, now: lateNight, calendar: calendar) == .valid(date(4, 0, 0)))
    }

    @Test func changingTheDayKeepsTheTypedTime() {
        var draft = PickyCustomSendTimePolicy.makeDraft(now: now, calendar: calendar, locale: locale)
        draft.timeText = "오후 3:00"
        draft.isCalendarVisible = true
        PickyCustomSendTimePolicy.selectDay(date(23, 11), in: &draft, calendar: calendar)

        #expect(PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar) == .valid(date(23, 15, 0)))
        #expect(!draft.isCalendarVisible)
        #expect(draft.displayedMonth == date(1, 0))
    }

    @Test func dateMenuListsTwoWeeksStartingToday() {
        let days = PickyCustomSendTimePolicy.listedDays(now: now, calendar: calendar)
        #expect(days.count == 14)
        #expect(days.first == date(3, 0))
        #expect(days.last == date(16, 0))
    }

    @Test func slotsOnlyOfferTimesStillAhead() {
        let today = PickyCustomSendTimePolicy.timeSlots(on: now, now: now, calendar: calendar)
        #expect(today.first == date(3, 14, 30))
        #expect(today.last == date(3, 23, 45))
        #expect(PickyCustomSendTimePolicy.timeSlots(on: date(4, 0), now: now, calendar: calendar).count == 96)
    }

    @Test func monthGridKeepsSixWeeksAndOnlyFutureDaysOfTheMonthSelectable() {
        let grid = PickyCustomSendTimePolicy.monthGrid(for: date(1, 0), selectedDay: date(3, 0), now: now, calendar: calendar)
        #expect(grid.count == 42)
        // October 2026 starts on Thursday; the Sunday-first grid opens on Sep 27.
        #expect(grid.first?.date == date(27, 0, month: 9))
        let selectable = grid.filter(\.isSelectable).map(\.dayNumber)
        #expect(selectable == Array(3...31))
        #expect(grid.filter(\.isToday).map(\.dayNumber) == [3])
    }

    @Test func monthNavigationStaysWithinTheSelectableYear() {
        let october = date(1, 0)
        #expect(!PickyCustomSendTimePolicy.canShowMonth(offsetBy: -1, from: october, now: now, calendar: calendar))
        #expect(PickyCustomSendTimePolicy.canShowMonth(offsetBy: 1, from: october, now: now, calendar: calendar))
        #expect(PickyCustomSendTimePolicy.canShowMonth(offsetBy: 12, from: october, now: now, calendar: calendar))
        #expect(!PickyCustomSendTimePolicy.canShowMonth(offsetBy: 13, from: october, now: now, calendar: calendar))
    }

    @Test func dayTitlesNameTodayTomorrowThenTheWeekday() throws {
        try LocaleManager.shared.withTemporaryChoiceForTesting(.korean) {
            #expect(PickyCustomSendTimePolicy.dayTitle(for: date(3, 0), now: now, calendar: calendar, locale: locale) == "오늘 · 10월 3일")
            #expect(PickyCustomSendTimePolicy.dayTitle(for: date(4, 0), now: now, calendar: calendar, locale: locale) == "내일 · 10월 4일")
            #expect(PickyCustomSendTimePolicy.dayTitle(for: date(5, 0), now: now, calendar: calendar, locale: locale) == "월요일 · 10월 5일")
            // The day chip keeps today/tomorrow but drops long weekday names.
            #expect(PickyCustomSendTimePolicy.chipTitle(for: date(4, 0), now: now, calendar: calendar, locale: locale) == "내일 · 10월 4일")
            #expect(PickyCustomSendTimePolicy.chipTitle(for: date(23, 0), now: now, calendar: calendar, locale: locale)
                == PickyCustomSendTimePolicy.dateText(for: date(23, 0), calendar: calendar, locale: locale))
        }
    }
}
