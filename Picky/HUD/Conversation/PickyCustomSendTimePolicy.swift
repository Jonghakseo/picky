//
//  PickyCustomSendTimePolicy.swift
//  Picky
//
//  "Custom time" editor behind the send-timing menu: a day picked from a short
//  list (or a month grid) plus a time that is either typed or picked from
//  15-minute slots. Pure value logic; the view only renders and forwards input.
//

import Foundation

/// Editor state while the custom-time screen is open.
struct PickyCustomSendTimeDraft: Equatable {
    /// Start of the selected day.
    var day: Date
    /// Exactly what the time field shows; parsed on every change.
    var timeText: String
    /// First day of the month shown in the grid.
    var displayedMonth: Date
    var isCalendarVisible = false
    /// Set when the user commits text that cannot be read as a time. Cleared as
    /// soon as the text changes, so a half-typed "3:" never flashes red.
    var showsTimeError = false
}

enum PickyCustomSendTimeResolution: Equatable {
    case valid(Date)
    case invalidTime
    case past
}

struct PickyCustomSendTimeCalendarDay: Equatable, Identifiable {
    let date: Date
    let dayNumber: Int
    let isInDisplayedMonth: Bool
    let isToday: Bool
    let isSelectable: Bool

    var id: Date { date }
}

enum PickyCustomSendTimePolicy {
    /// Days listed directly in the date menu (today + 13). Farther days go
    /// through "Other date…" and the month grid.
    static let listedDayCount = 14
    static let slotMinutes = 15
    /// Upper bound of the month grid. The delayed-action extension re-arms past
    /// setTimeout's limit, so this is a UI sanity bound, not a delivery limit.
    static let maxDaysAhead = 365

    // MARK: Draft

    /// Opens on today at the next full hour, the time most people reach for.
    static func makeDraft(now: Date, calendar: Calendar, locale: Locale) -> PickyCustomSendTimeDraft {
        let nextHour = calendar.nextDate(
            after: now,
            matching: DateComponents(minute: 0, second: 0),
            matchingPolicy: .nextTime
        ) ?? now.addingTimeInterval(3600)
        let day = calendar.startOfDay(for: nextHour)
        return PickyCustomSendTimeDraft(
            day: day,
            timeText: timeText(for: nextHour, calendar: calendar, locale: locale),
            displayedMonth: startOfMonth(for: day, calendar: calendar)
        )
    }

    static func resolve(_ draft: PickyCustomSendTimeDraft, now: Date, calendar: Calendar) -> PickyCustomSendTimeResolution {
        guard let date = date(forTimeText: draft.timeText, on: draft.day, now: now, calendar: calendar) else {
            return .invalidTime
        }
        return date > now ? .valid(date) : .past
    }

    /// Enter / focus loss: normalize readable text ("1507" -> "오후 3:07") or
    /// flag unreadable text.
    static func commitTimeText(_ draft: inout PickyCustomSendTimeDraft, now: Date, calendar: Calendar, locale: Locale) {
        if let date = date(forTimeText: draft.timeText, on: draft.day, now: now, calendar: calendar) {
            draft.timeText = timeText(for: date, calendar: calendar, locale: locale)
            draft.showsTimeError = false
        } else {
            draft.showsTimeError = true
        }
    }

    /// Changing the day keeps the typed time; an ambiguous "3:00" is re-read
    /// against the new day when it resolves.
    static func selectDay(_ day: Date, in draft: inout PickyCustomSendTimeDraft, calendar: Calendar) {
        draft.day = calendar.startOfDay(for: day)
        draft.displayedMonth = startOfMonth(for: draft.day, calendar: calendar)
        draft.isCalendarVisible = false
    }

    static func selectSlot(_ slot: Date, in draft: inout PickyCustomSendTimeDraft, calendar: Calendar, locale: Locale) {
        draft.day = calendar.startOfDay(for: slot)
        draft.timeText = timeText(for: slot, calendar: calendar, locale: locale)
        draft.showsTimeError = false
    }

    // MARK: Lists

    static func listedDays(now: Date, calendar: Calendar) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0..<listedDayCount).compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
    }

    /// 15-minute slots on `day`; today starts at the first slot still ahead.
    static func timeSlots(on day: Date, now: Date, calendar: Calendar) -> [Date] {
        let start = calendar.startOfDay(for: day)
        let slotsPerDay = 24 * 60 / slotMinutes
        return (0..<slotsPerDay).compactMap { index in
            calendar.date(byAdding: .minute, value: index * slotMinutes, to: start)
        }
        .filter { calendar.isDate($0, inSameDayAs: start) && $0 > now }
    }

    // MARK: Month grid

    static func startOfMonth(for date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
    }

    static func lastSelectableDay(now: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .day, value: maxDaysAhead, to: calendar.startOfDay(for: now)) ?? now
    }

    static func isSelectable(_ day: Date, now: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: day)
        return start >= calendar.startOfDay(for: now) && start <= lastSelectableDay(now: now, calendar: calendar)
    }

    static func canShowMonth(offsetBy offset: Int, from month: Date, now: Date, calendar: Calendar) -> Bool {
        guard let target = calendar.date(byAdding: .month, value: offset, to: month) else { return false }
        let first = startOfMonth(for: now, calendar: calendar)
        let last = startOfMonth(for: lastSelectableDay(now: now, calendar: calendar), calendar: calendar)
        return target >= first && target <= last
    }

    /// Six full weeks so the grid height never jumps between months.
    static func monthGrid(for month: Date, selectedDay: Date, now: Date, calendar: Calendar) -> [PickyCustomSendTimeCalendarDay] {
        let first = startOfMonth(for: month, calendar: calendar)
        let weekday = calendar.component(.weekday, from: first)
        let leading = (weekday - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -leading, to: first) else { return [] }
        return (0..<42).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: gridStart) else { return nil }
            let inMonth = calendar.isDate(date, equalTo: first, toGranularity: .month)
            return PickyCustomSendTimeCalendarDay(
                date: date,
                dayNumber: calendar.component(.day, from: date),
                isInDisplayedMonth: inMonth,
                isToday: calendar.isDate(date, inSameDayAs: now),
                isSelectable: inMonth && isSelectable(date, now: now, calendar: calendar)
            )
        }
    }

    /// Weekday initials in calendar order, starting at `firstWeekday`.
    static func weekdaySymbols(calendar: Calendar, locale: Locale) -> [String] {
        var localized = calendar
        localized.locale = locale
        let symbols = localized.veryShortStandaloneWeekdaySymbols
        let shift = calendar.firstWeekday - 1
        return Array(symbols[shift...] + symbols[..<shift])
    }

    // MARK: Formatting

    static func timeText(for date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(style(locale: locale, calendar: calendar, base: Date.FormatStyle(date: .omitted, time: .shortened)))
    }

    /// "10월 4일 (일)" / "Sun, Oct 4".
    static func dateText(for date: Date, calendar: Calendar, locale: Locale) -> String {
        date.formatted(style(locale: locale, calendar: calendar, base: Date.FormatStyle()).month(.abbreviated).day().weekday(.abbreviated))
    }

    static func monthTitle(for month: Date, calendar: Calendar, locale: Locale) -> String {
        month.formatted(style(locale: locale, calendar: calendar, base: Date.FormatStyle()).year().month(.wide))
    }

    /// "오늘 · 10월 3일", "내일 · 10월 4일", "월요일 · 10월 5일".
    static func dayTitle(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let monthDay = day.formatted(style(locale: locale, calendar: calendar, base: Date.FormatStyle()).month(.abbreviated).day())
        let name: String
        if calendar.isDate(day, inSameDayAs: now) {
            name = L10n.t("hud.composer.sendTiming.custom.today")
        } else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
                  calendar.isDate(day, inSameDayAs: tomorrow) {
            name = L10n.t("hud.composer.sendTiming.custom.tomorrow")
        } else {
            name = day.formatted(style(locale: locale, calendar: calendar, base: Date.FormatStyle()).weekday(.wide))
        }
        return L10n.t("hud.composer.sendTiming.custom.dayTitle", name, monthDay)
    }

    /// Shorter form for the narrow day chip: weekday names do not fit next to
    /// the time chip, so days past tomorrow show "10월 23일 (금)".
    static func chipTitle(for day: Date, now: Date, calendar: Calendar, locale: Locale) -> String {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))
        if calendar.isDate(day, inSameDayAs: now) || tomorrow.map({ calendar.isDate(day, inSameDayAs: $0) }) == true {
            return dayTitle(for: day, now: now, calendar: calendar, locale: locale)
        }
        return dateText(for: day, calendar: calendar, locale: locale)
    }

    private static func style(locale: Locale, calendar: Calendar, base: Date.FormatStyle) -> Date.FormatStyle {
        var style = base.locale(locale)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return style
    }

    // MARK: Parsing

    /// Reads "15:30", "3:07", "1530", "15", "오후 3시", "3시 반", "3:30pm".
    /// Without 오전/오후/am/pm, an hour from 1 to 11 means the first of
    /// h:mm or (h+12):mm that is still ahead on `day`.
    static func date(forTimeText text: String, on day: Date, now: Date, calendar: Calendar) -> Date? {
        guard let parsed = parseTime(text) else { return nil }
        let start = calendar.startOfDay(for: day)
        func at(_ hour: Int) -> Date? {
            calendar.date(bySettingHour: hour, minute: parsed.minute, second: 0, of: start)
        }
        if let hour = parsed.hour {
            return at(hour)
        }
        let candidates = [parsed.ambiguousHour, parsed.ambiguousHour + 12].compactMap(at)
        return candidates.first { $0 > now } ?? candidates.first
    }

    private struct ParsedTime {
        /// Unambiguous 24-hour value, or `nil` when `ambiguousHour` applies.
        let hour: Int?
        let ambiguousHour: Int
        let minute: Int
    }

    private static func parseTime(_ raw: String) -> ParsedTime? {
        var text = raw.lowercased().replacingOccurrences(of: " ", with: "")
        var isPM: Bool?
        for (token, pm) in [("오전", false), ("오후", true), ("a.m.", false), ("p.m.", true), ("am", false), ("pm", true)]
        where text.contains(token) {
            guard isPM == nil else { return nil }
            isPM = pm
            text = text.replacingOccurrences(of: token, with: "")
        }
        text = text.replacingOccurrences(of: "시반", with: "시30분")

        let hour: Int
        let minute: Int
        if let match = text.wholeMatch(of: #/(\d{1,2})(?::(\d{2}))?/#) {
            hour = Int(match.1) ?? -1
            minute = match.2.flatMap { Int($0) } ?? 0
        } else if let match = text.wholeMatch(of: #/(\d{1,2})시(?:(\d{1,2})분?)?/#) {
            hour = Int(match.1) ?? -1
            minute = match.2.flatMap { Int($0) } ?? 0
        } else if let match = text.wholeMatch(of: #/(\d{1,2})(\d{2})/#) {
            hour = Int(match.1) ?? -1
            minute = Int(match.2) ?? -1
        } else {
            return nil
        }
        guard (0...59).contains(minute) else { return nil }

        if let isPM {
            guard (1...12).contains(hour) else { return nil }
            return ParsedTime(hour: hour % 12 + (isPM ? 12 : 0), ambiguousHour: hour, minute: minute)
        }
        guard (0...23).contains(hour) else { return nil }
        if (1...11).contains(hour) {
            return ParsedTime(hour: nil, ambiguousHour: hour, minute: minute)
        }
        return ParsedTime(hour: hour, ambiguousHour: hour, minute: minute)
    }
}
