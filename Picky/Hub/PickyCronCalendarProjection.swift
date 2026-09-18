import Foundation

struct PickyCronCalendarOccurrence: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case actual, next, projected
    }

    let job: PickyCronJobPresentation
    let date: Date
    let kind: Kind
    var execution: PickyCronExecution? = nil

    var id: String { "\(job.id):\(kind.rawValue):\(date.timeIntervalSince1970)" }
}

struct PickyCronCalendarProjectionResult: Equatable {
    let occurrences: [PickyCronCalendarOccurrence]
    let truncated: Bool
    let unsupportedJobIDs: Set<String>
}

enum PickyCronCalendarProjection {
    /// Intervals are half-open. Only recorded executions appear in the past.
    static func occurrences(
        jobs: [PickyCronJobPresentation],
        interval: DateInterval,
        now: Date,
        limit: Int = 500,
        schedulerTimeZone: TimeZone = .current
    ) -> PickyCronCalendarProjectionResult {
        let cap = max(0, min(limit, 10_000))
        var heads: [Head] = []
        var unsupported: Set<String> = []
        var truncated = false
        var calendar = Calendar(identifier: .gregorian)
        // Cron schedule.ts uses local getters/setters, not the stored timezone.
        calendar.timeZone = schedulerTimeZone
        func visible(_ date: Date) -> Bool { date >= interval.start && date < interval.end }

        for job in jobs {
            var actuals = job.executions
            let linkedStart = job.lastRunLog.flatMap { path -> Date? in
                let url = URL(fileURLWithPath: path)
                guard url.deletingLastPathComponent().lastPathComponent == job.id,
                      url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "runs" else { return nil }
                return PickyCronJobReader.runDate(filename: url.lastPathComponent)
            }
            if let latest = linkedStart ?? job.lastRunAt ?? job.completedAt,
               !actuals.contains(where: { $0.date == latest }) {
                actuals.append(.init(date: latest, exitCode: job.lastExitCode, promptFile: job.lastRunPromptFile))
            }
            var seen: Set<Date> = []
            for actual in actuals where visible(actual.date) && seen.insert(actual.date).inserted {
                heads.append(Head(occurrence: .init(job: job, date: actual.date, kind: .actual, execution: actual)))
            }
            guard job.enabled else { continue }
            let next = job.nextRunAt ?? (job.schedule == nil ? PickyCronJobReader.parseDate(job.runAtText) : nil)
            if let next, visible(next), next != job.lastRunAt {
                heads.append(Head(occurrence: .init(job: job, date: next, kind: .next)))
            }
            guard let schedule = job.schedule else { continue }
            guard let rule = Rule(schedule) else {
                unsupported.insert(job.id)
                continue
            }
            guard job.once != true else { continue }
            let lowerBound = max(now, next ?? now)
            var cursor = Recurrence(
                rule: rule, day: calendar.startOfDay(for: max(interval.start, lowerBound)),
                lowerBound: lowerBound
            )
            if let date = cursor.advance(calendar: calendar, interval: interval) {
                heads.append(Head(occurrence: .init(job: job, date: date, kind: .projected), cursor: cursor))
            }
            truncated = truncated || cursor.hitDayLimit
        }

        // One recurrence head per job, rather than cap + 1 occurrences per job.
        // A linear head selection keeps storage O(jobs + cap) and generates only
        // jobs + cap recurrence dates, including the lookahead for truncation.
        var entries: [PickyCronCalendarOccurrence] = []
        while entries.count < cap, let index = heads.indices.min(by: {
            let left = heads[$0].occurrence
            let right = heads[$1].occurrence
            if left.kind != right.kind {
                if left.kind == .next { return true }
                if right.kind == .next { return false }
                return left.kind == .actual
            }
            if left.kind == .actual, left.date != right.date { return left.date > right.date }
            return precedes(left, right)
        }) {
            let occurrence = heads[index].occurrence
            entries.append(occurrence)
            if var cursor = heads[index].cursor {
                if let date = cursor.advance(calendar: calendar, interval: interval) {
                    heads[index] = Head(
                        occurrence: .init(job: occurrence.job, date: date, kind: .projected), cursor: cursor
                    )
                } else {
                    heads.remove(at: index)
                }
                truncated = truncated || cursor.hitDayLimit
            } else {
                heads.remove(at: index)
            }
        }
        return .init(occurrences: entries.sorted(by: precedes), truncated: truncated || !heads.isEmpty, unsupportedJobIDs: unsupported)
    }

    private static func precedes(_ lhs: PickyCronCalendarOccurrence, _ rhs: PickyCronCalendarOccurrence) -> Bool {
        if lhs.date != rhs.date { return lhs.date < rhs.date }
        if lhs.job.id != rhs.job.id { return lhs.job.id < rhs.job.id }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    private struct Head {
        let occurrence: PickyCronCalendarOccurrence
        var cursor: Recurrence?
    }

    private struct Recurrence {
        let rule: Rule
        var day: Date
        let lowerBound: Date
        var slot = 0
        var days = 0
        var hitDayLimit = false

        mutating func advance(calendar: Calendar, interval: DateInterval) -> Date? {
            while day < interval.end && days < 3_660 {
                guard let followingDay = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
                let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
                if rule.days.contains(parts.day ?? 0), rule.months.contains(parts.month ?? 0),
                   rule.weekdays.contains((parts.weekday ?? 0) - 1) {
                    while slot < rule.hours.count * rule.minutes.count {
                        let hour = rule.hours[slot / rule.minutes.count]
                        let minute = rule.minutes[slot % rule.minutes.count]
                        slot += 1
                        let components = DateComponents(hour: hour, minute: minute, second: 0)
                        // Strict matching skips spring gaps; first skips the repeated fall hour.
                        if let date = calendar.nextDate(
                            after: day.addingTimeInterval(-1), matching: components,
                            matchingPolicy: .strict, repeatedTimePolicy: .first
                        ), date < followingDay, date > lowerBound,
                           date >= interval.start, date < interval.end {
                            return date
                        }
                    }
                }
                day = followingDay
                days += 1
                slot = 0
            }
            hitDayLimit = day < interval.end && days == 3_660
            return nil
        }
    }

    /// Plugin syntax: five numeric fields, lists/ranges/steps; DOM and DOW are ANDed.
    private struct Rule {
        let minutes: [Int]
        let hours: [Int]
        let days: [Int]
        let months: [Int]
        let weekdays: [Int]

        init?(_ expression: String) {
            let fields = expression.split(whereSeparator: \.isWhitespace)
            guard fields.count == 5,
                  let minutes = Self.field(fields[0], bounds: 0...59),
                  let hours = Self.field(fields[1], bounds: 0...23),
                  let days = Self.field(fields[2], bounds: 1...31),
                  let months = Self.field(fields[3], bounds: 1...12),
                  let weekdays = Self.field(fields[4], bounds: 0...6) else { return nil }
            self.minutes = minutes
            self.hours = hours
            self.days = days
            self.months = months
            self.weekdays = weekdays
        }

        private static func field(_ field: Substring, bounds: ClosedRange<Int>) -> [Int]? {
            var values: Set<Int> = []
            for part in field.split(separator: ",", omittingEmptySubsequences: false) {
                let pieces = part.split(separator: "/", omittingEmptySubsequences: false)
                guard (1...2).contains(pieces.count) else { return nil }
                let step: Int
                if pieces.count == 2 {
                    guard let parsed = Int(pieces[1]), parsed > 0 else { return nil }
                    step = parsed
                } else { step = 1 }
                let range: ClosedRange<Int>
                if pieces[0] == "*" {
                    range = bounds
                } else {
                    let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
                    guard (1...2).contains(ends.count), let lo = Int(ends[0]),
                          let hi = Int(ends.last!), bounds.contains(lo), bounds.contains(hi), lo <= hi else { return nil }
                    range = lo...hi
                }
                // Filtering a small range avoids overflow for unusually large step values.
                values.formUnion(range.filter { ($0 - range.lowerBound) % step == 0 })
            }
            return values.isEmpty ? nil : values.sorted()
        }
    }
}
