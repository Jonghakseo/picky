//
//  PickyHubStatisticsHighlights.swift
//  Picky
//
//  Pure policies behind the Statistics tabs that go beyond plain totals:
//  activity rhythm (streaks, daily calendar, hour pattern), badges, and the
//  Pickle hall of fame. Everything derives from the daemon snapshot, so
//  badge dates need no separate persistence and survive reinstalls.
//

import Foundation

// MARK: - Rhythm

struct PickyHubActivityDay: Equatable, Identifiable {
    let date: Date
    let count: Int

    var id: Date { date }
}

/// Daily Pickle starts laid out as calendar weeks, plus streaks. Streaks and
/// the calendar ignore the page filter: they describe the whole habit.
struct PickyHubActivityCalendar: Equatable {
    /// Oldest first. Each week holds seven slots starting at the calendar's
    /// first weekday; slots after today are `nil`.
    let weeks: [[PickyHubActivityDay?]]
    let currentStreak: Int
    let longestStreak: Int
    let pickleCount: Int
    let activeDayCount: Int
    let maximumDailyCount: Int

    /// 0 for no activity, then 1...4 relative to the busiest day shown.
    func level(for day: PickyHubActivityDay) -> Int {
        guard day.count > 0, maximumDailyCount > 0 else { return 0 }
        return min(4, max(1, Int((Double(day.count) / Double(maximumDailyCount) * 4).rounded(.up))))
    }
}

/// Hour-of-day pattern for the filtered records.
struct PickyHubHourPattern: Equatable {
    static let peakWindowLength = 3
    /// Hours treated as late night (00:00 to 04:59).
    static let lateNightHours = 0..<5

    let hourCounts: [Int]
    let total: Int
    /// First hour of the busiest three-hour window, `nil` without records.
    let peakStartHour: Int?
    let peakCount: Int
    let lateNightCount: Int
    let weekendCount: Int

    func share(_ count: Int) -> Int {
        total == 0 ? 0 : Int((Double(count) / Double(total) * 100).rounded())
    }
}

enum PickyHubRhythmPolicy {
    static func activityCalendar(
        records: [PickyHubPickleRecord],
        weekCount: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PickyHubActivityCalendar {
        let today = calendar.startOfDay(for: now)
        var countsByDay: [Date: Int] = [:]
        for record in records where record.createdAt <= now {
            countsByDay[calendar.startOfDay(for: record.createdAt), default: 0] += 1
        }

        let weekCount = max(1, weekCount)
        let currentWeekStart = calendar.dateInterval(of: .weekOfYear, for: today)?.start ?? today
        let firstWeekStart = calendar.date(byAdding: .weekOfYear, value: -(weekCount - 1), to: currentWeekStart) ?? currentWeekStart
        var weeks: [[PickyHubActivityDay?]] = []
        var shownCount = 0
        var shownDays = 0
        var maximum = 0
        for week in 0..<weekCount {
            guard let weekStart = calendar.date(byAdding: .weekOfYear, value: week, to: firstWeekStart) else { continue }
            weeks.append((0..<7).map { offset in
                guard let date = calendar.date(byAdding: .day, value: offset, to: weekStart), date <= today else { return nil }
                let count = countsByDay[date] ?? 0
                shownCount += count
                if count > 0 { shownDays += 1 }
                maximum = max(maximum, count)
                return PickyHubActivityDay(date: date, count: count)
            })
        }

        let streaks = streaks(activeDays: Set(countsByDay.keys), today: today, calendar: calendar)
        return PickyHubActivityCalendar(
            weeks: weeks,
            currentStreak: streaks.current,
            longestStreak: streaks.longest,
            pickleCount: shownCount,
            activeDayCount: shownDays,
            maximumDailyCount: maximum
        )
    }

    /// A streak still counts when today has no Pickle yet but yesterday did.
    static func streaks(activeDays: Set<Date>, today: Date, calendar: Calendar) -> (current: Int, longest: Int) {
        var longest = 0
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = day
        }

        var current = 0
        var cursor = activeDays.contains(today) ? today : calendar.date(byAdding: .day, value: -1, to: today)
        while let day = cursor, activeDays.contains(day) {
            current += 1
            cursor = calendar.date(byAdding: .day, value: -1, to: day)
        }
        return (current, longest)
    }

    static func hourPattern(records: [PickyHubPickleRecord], calendar: Calendar = .current) -> PickyHubHourPattern {
        var hours = Array(repeating: 0, count: 24)
        var weekend = 0
        for record in records {
            let hour = calendar.component(.hour, from: record.createdAt)
            hours[hour] += 1
            if calendar.isDateInWeekend(record.createdAt) { weekend += 1 }
        }
        let total = hours.reduce(0, +)
        var peakStart: Int?
        var peakCount = 0
        if total > 0 {
            for start in 0...(24 - PickyHubHourPattern.peakWindowLength) {
                let count = hours[start..<(start + PickyHubHourPattern.peakWindowLength)].reduce(0, +)
                if count > peakCount {
                    peakCount = count
                    peakStart = start
                }
            }
        }
        return PickyHubHourPattern(
            hourCounts: hours,
            total: total,
            peakStartHour: peakStart,
            peakCount: peakCount,
            lateNightCount: PickyHubHourPattern.lateNightHours.reduce(0) { $0 + hours[$1] },
            weekendCount: weekend
        )
    }
}

// MARK: - Badges

enum PickyHubBadgeKind: String, CaseIterable, Identifiable {
    case firstPickle
    case weekStreak
    case nightOwl
    case millionTokens
    case busyDay
    case noFollowUp
    case explorer
    case monthStreak

    var id: String { rawValue }

    var target: Int {
        switch self {
        case .firstPickle: 1
        case .weekStreak: 7
        case .nightOwl: 10
        case .millionTokens: 1_000_000
        case .busyDay: 10
        case .noFollowUp: 25
        case .explorer: 5
        case .monthStreak: 30
        }
    }

    var systemImage: String {
        switch self {
        case .firstPickle: "sparkles"
        case .weekStreak: "flame.fill"
        case .nightOwl: "moon.stars.fill"
        case .millionTokens: "bolt.fill"
        case .busyDay: "square.stack.3d.up.fill"
        case .noFollowUp: "checkmark.seal.fill"
        case .explorer: "map.fill"
        case .monthStreak: "flame"
        }
    }
}

struct PickyHubBadge: Equatable, Identifiable {
    let kind: PickyHubBadgeKind
    /// When the threshold was first crossed, `nil` while still in progress.
    let earnedAt: Date?
    /// Current value toward `kind.target`, capped at the target.
    let progress: Int

    var id: PickyHubBadgeKind { kind }
    var isEarned: Bool { earnedAt != nil }
    var fraction: Double { min(1, Double(progress) / Double(kind.target)) }
}

struct PickyHubBadgeBoard: Equatable {
    /// How long a newly earned badge stays announced.
    static let recentWindow: TimeInterval = 7 * 24 * 60 * 60

    let badges: [PickyHubBadge]
    let recentlyEarned: PickyHubBadge?
    /// The unearned badge closest to completion.
    let nextGoal: PickyHubBadge?

    var earnedCount: Int { badges.filter(\.isEarned).count }
}

enum PickyHubBadgePolicy {
    static func board(
        snapshot: PickyHubStatisticsSnapshot,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PickyHubBadgeBoard {
        let records = snapshot.records.filter { $0.createdAt <= now }.sorted { $0.createdAt < $1.createdAt }
        let activeDays = Set(records.map { calendar.startOfDay(for: $0.createdAt) })
        let today = calendar.startOfDay(for: now)
        let currentStreak = PickyHubRhythmPolicy.streaks(activeDays: activeDays, today: today, calendar: calendar).current

        let badges = PickyHubBadgeKind.allCases.map { kind -> PickyHubBadge in
            switch kind {
            case .firstPickle:
                return badge(kind, events: records.map(\.createdAt))
            case .weekStreak, .monthStreak:
                return PickyHubBadge(
                    kind: kind,
                    earnedAt: firstStreakCompletion(length: kind.target, activeDays: activeDays, calendar: calendar),
                    progress: min(kind.target, currentStreak)
                )
            case .nightOwl:
                return badge(kind, events: records.map(\.createdAt).filter {
                    PickyHubHourPattern.lateNightHours.contains(calendar.component(.hour, from: $0))
                })
            case .millionTokens:
                return millionTokens(snapshot: snapshot, now: now, calendar: calendar)
            case .busyDay:
                return busyDay(records: records, calendar: calendar)
            case .noFollowUp:
                return badge(kind, events: records.filter { $0.followUpCount == 0 }.map(\.lastActivityAt).filter { $0 <= now }.sorted())
            case .explorer:
                var seen = Set<String>()
                let firsts = records.compactMap { record -> Date? in
                    seen.insert(record.project).inserted ? record.createdAt : nil
                }
                return badge(kind, events: firsts)
            }
        }

        let recent = badges
            .filter { badge in
                guard let earnedAt = badge.earnedAt else { return false }
                return now.timeIntervalSince(earnedAt) <= PickyHubBadgeBoard.recentWindow
            }
            .max { lhs, rhs in lhs.earnedAt! < rhs.earnedAt! }
        let next = badges
            .filter { !$0.isEarned }
            .max { lhs, rhs in
                lhs.fraction != rhs.fraction
                    ? lhs.fraction < rhs.fraction
                    : order(lhs.kind) > order(rhs.kind)
            }
        return PickyHubBadgeBoard(badges: badges, recentlyEarned: recent, nextGoal: next)
    }

    /// `events` must be chronological; the badge is earned at the target-th event.
    private static func badge(_ kind: PickyHubBadgeKind, events: [Date]) -> PickyHubBadge {
        PickyHubBadge(
            kind: kind,
            earnedAt: events.count >= kind.target ? events[kind.target - 1] : nil,
            progress: min(kind.target, events.count)
        )
    }

    private static func firstStreakCompletion(length: Int, activeDays: Set<Date>, calendar: Calendar) -> Date? {
        var run = 0
        var previous: Date?
        for day in activeDays.sorted() {
            if let previous, calendar.date(byAdding: .day, value: 1, to: previous) == day {
                run += 1
            } else {
                run = 1
            }
            if run >= length { return day }
            previous = day
        }
        return nil
    }

    private static func millionTokens(snapshot: PickyHubStatisticsSnapshot, now: Date, calendar: Calendar) -> PickyHubBadge {
        let kind = PickyHubBadgeKind.millionTokens
        let endDay = PickyHubStatisticsAggregator.dayString(now, calendar: calendar)
        var byDay: [String: Int] = [:]
        for sample in snapshot.usageSamples where sample.day <= endDay {
            byDay[sample.day, default: 0] += sample.inputTokens + sample.outputTokens + sample.cacheTokens
        }
        var total = 0
        var earnedAt: Date?
        for day in byDay.keys.sorted() {
            total += byDay[day] ?? 0
            if earnedAt == nil, total >= kind.target {
                earnedAt = PickyHubStatisticsAggregator.date(fromDay: day, calendar: calendar)
            }
        }
        return PickyHubBadge(kind: kind, earnedAt: earnedAt, progress: min(kind.target, total))
    }

    private static func busyDay(records: [PickyHubPickleRecord], calendar: Calendar) -> PickyHubBadge {
        let kind = PickyHubBadgeKind.busyDay
        var counts: [Date: Int] = [:]
        var earnedAt: Date?
        for record in records {
            let day = calendar.startOfDay(for: record.createdAt)
            counts[day, default: 0] += 1
            if earnedAt == nil, counts[day] == kind.target { earnedAt = record.createdAt }
        }
        return PickyHubBadge(kind: kind, earnedAt: earnedAt, progress: min(kind.target, counts.values.max() ?? 0))
    }

    private static func order(_ kind: PickyHubBadgeKind) -> Int {
        PickyHubBadgeKind.allCases.firstIndex(of: kind) ?? .max
    }
}

// MARK: - Hall of fame

struct PickyHubResultTotals: Equatable {
    var changedFiles = 0
    var artifacts = 0
    var toolCalls = 0
    var subagents = 0

    var isEmpty: Bool { changedFiles + artifacts + toolCalls + subagents == 0 }

    mutating func add(_ record: PickyHubPickleRecord) {
        changedFiles += record.changedFileCount
        artifacts += record.artifactCount
        toolCalls += record.toolCallCount
        subagents += record.subagentCount
    }
}

enum PickyHubAwardKind: String, CaseIterable, Identifiable {
    case longestWork
    case mostChangedFiles
    case mostSubagents
    case mostFollowUps
    case mostTokens

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .longestWork: "timer"
        case .mostChangedFiles: "doc.on.doc"
        case .mostSubagents: "person.3"
        case .mostFollowUps: "bubble.left.and.bubble.right"
        case .mostTokens: "bolt"
        }
    }

    func value(of record: PickyHubPickleRecord) -> Int {
        switch self {
        case .longestWork: record.activeDurationMs
        case .mostChangedFiles: record.changedFileCount
        case .mostSubagents: record.subagentCount
        case .mostFollowUps: record.followUpCount
        case .mostTokens: record.totalTokens
        }
    }
}

struct PickyHubAward: Equatable, Identifiable {
    let kind: PickyHubAwardKind
    let record: PickyHubPickleRecord
    let value: Int

    var id: PickyHubAwardKind { kind }
}

struct PickyHubHallOfFame: Equatable {
    let allTime: PickyHubResultTotals
    /// Results from Pickles started this calendar month.
    let thisMonth: PickyHubResultTotals
    /// All-time leaders. A category without any nonzero value is omitted.
    let awards: [PickyHubAward]
}

enum PickyHubHallOfFamePolicy {
    static func hallOfFame(
        records: [PickyHubPickleRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> PickyHubHallOfFame {
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
        var allTime = PickyHubResultTotals()
        var thisMonth = PickyHubResultTotals()
        for record in records where record.createdAt <= now {
            allTime.add(record)
            if record.createdAt >= monthStart { thisMonth.add(record) }
        }
        let awards = PickyHubAwardKind.allCases.compactMap { kind -> PickyHubAward? in
            let leader = records.max { lhs, rhs in
                let l = kind.value(of: lhs)
                let r = kind.value(of: rhs)
                if l != r { return l < r }
                if lhs.lastActivityAt != rhs.lastActivityAt { return lhs.lastActivityAt < rhs.lastActivityAt }
                return lhs.id > rhs.id
            }
            guard let leader, kind.value(of: leader) > 0 else { return nil }
            return PickyHubAward(kind: kind, record: leader, value: kind.value(of: leader))
        }
        return PickyHubHallOfFame(allTime: allTime, thisMonth: thisMonth, awards: awards)
    }
}
