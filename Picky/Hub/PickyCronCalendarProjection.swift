import Foundation

struct PickyCronCalendarOccurrence: Identifiable, Equatable {
    enum Kind: String, Equatable {
        case actual, next, projected
    }

    let job: PickyCronJobPresentation
    let date: Date
    let kind: Kind

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
        var entries: [PickyCronCalendarOccurrence] = []
        var unsupported: Set<String> = []
        var truncated = false
        func visible(_ date: Date) -> Bool { date >= interval.start && date < interval.end }

        for job in jobs {
            if let actual = job.lastRunAt ?? job.completedAt, visible(actual) {
                entries.append(.init(job: job, date: actual, kind: .actual))
            }
            guard job.enabled else { continue }
            let next = job.nextRunAt ?? (job.schedule == nil ? PickyCronJobReader.parseDate(job.runAtText) : nil)
            if let next, visible(next), next != job.lastRunAt {
                entries.append(.init(job: job, date: next, kind: .next))
            }
            guard let schedule = job.schedule else { continue }
            guard let rule = Rule(schedule) else {
                unsupported.insert(job.id)
                continue
            }
            guard job.once != true else { continue }
            var calendar = Calendar(identifier: .gregorian)
            // Cron schedule.ts uses Date local getters/setters, not the stored timezone.
            calendar.timeZone = schedulerTimeZone
            let lowerBound = max(now, next ?? now)
            var day = calendar.startOfDay(for: max(interval.start, lowerBound))
            var count = 0
            var days = 0
            // The UI requests a week/month. Bound even accidental multi-century requests.
            while day < interval.end && count <= cap && days < 3_660 {
                days += 1
                guard let followingDay = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                let parts = calendar.dateComponents([.day, .month, .weekday], from: day)
                if rule.days.contains(parts.day ?? 0), rule.months.contains(parts.month ?? 0),
                   rule.weekdays.contains((parts.weekday ?? 0) - 1) {
                    var candidates: Set<Date> = []
                    for hour in rule.hours {
                        for minute in rule.minutes {
                            let components = DateComponents(hour: hour, minute: minute, second: 0)
                            // JavaScript local setMinutes skips the repeated fall-back hour.
                            if let date = calendar.nextDate(
                                after: day.addingTimeInterval(-1), matching: components,
                                matchingPolicy: .strict, repeatedTimePolicy: .first
                            ), date < followingDay, date > lowerBound, visible(date) {
                                candidates.insert(date)
                            }
                        }
                    }
                    for date in candidates.sorted() {
                        entries.append(.init(job: job, date: date, kind: .projected))
                        count += 1
                        if count > cap { break }
                    }
                }
                day = followingDay
            }
            if day < interval.end && days == 3_660 { truncated = true }
        }
        entries.sort {
            if $0.date != $1.date { return $0.date < $1.date }
            if $0.job.id != $1.job.id { return $0.job.id < $1.job.id }
            return $0.kind.rawValue < $1.kind.rawValue
        }
        return .init(
            occurrences: Array(entries.prefix(cap)),
            truncated: truncated || entries.count > cap,
            unsupportedJobIDs: unsupported
        )
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
