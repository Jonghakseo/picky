import Foundation

/// Calendar-facing policy shared by the week, month and compact agenda.
struct PickyCronCalendarGroup: Identifiable {
    let event: PickyCronCalendarOccurrence
    let count: Int
    let occurrences: [PickyCronCalendarOccurrence]
    var id: String { event.id }
}

/// One status for several occurrences shown as a single mark: a folded
/// recurring-jobs line in the month grid or one cell of the job matrix.
enum PickyCronCalendarDayStatus: Equatable {
    case succeeded, failed, executed, scheduled, projected
}

/// A job row in the job matrix with its occurrences keyed by start of day.
struct PickyCronCalendarJobRow: Identifiable {
    let job: PickyCronJobPresentation
    let occurrencesByDay: [Date: [PickyCronCalendarOccurrence]]
    var id: String { job.id }
}

enum PickyCronCalendarPresentation {
    /// Matches the calendar filter: a job without a rule or marked once is one-time.
    static func isRepeating(_ job: PickyCronJobPresentation) -> Bool {
        job.schedule != nil && job.once != true
    }

    /// Recorded results win over plans. A failure is never hidden behind an
    /// earlier success, and a run without an exit code is not reported as a success.
    static func dayStatus(_ events: [PickyCronCalendarOccurrence]) -> PickyCronCalendarDayStatus? {
        guard !events.isEmpty else { return nil }
        let actual = events.filter { $0.kind == .actual }
        if !actual.isEmpty {
            if actual.contains(where: { ($0.execution?.exitCode).map { $0 != 0 } ?? false }) { return .failed }
            return actual.allSatisfy({ $0.execution?.exitCode == 0 }) ? .succeeded : .executed
        }
        return events.contains { $0.kind == .next } ? .scheduled : .projected
    }

    static func symbol(_ status: PickyCronCalendarDayStatus) -> String {
        switch status {
        case .succeeded: "checkmark.circle.fill"
        case .failed: "exclamationmark.circle.fill"
        case .executed: "clock.arrow.circlepath"
        case .scheduled: "clock"
        case .projected: "repeat"
        }
    }

    static func status(_ status: PickyCronCalendarDayStatus) -> String {
        switch status {
        case .succeeded: L10n.t("hub.calendar.succeeded")
        case .failed: L10n.t("hub.calendar.failed")
        case .executed: L10n.t("hub.calendar.executed")
        case .scheduled: L10n.t("hub.calendar.scheduled")
        case .projected: L10n.t("hub.calendar.estimated")
        }
    }

    /// Repeating jobs first, then one-time jobs; each in order of first occurrence.
    static func jobRows(_ events: [PickyCronCalendarOccurrence], calendar: Calendar) -> [PickyCronCalendarJobRow] {
        var order: [String] = []
        var jobs: [String: PickyCronJobPresentation] = [:]
        var cells: [String: [Date: [PickyCronCalendarOccurrence]]] = [:]
        for event in events.sorted(by: { $0.date < $1.date }) {
            if jobs[event.job.id] == nil { order.append(event.job.id); jobs[event.job.id] = event.job }
            cells[event.job.id, default: [:]][calendar.startOfDay(for: event.date), default: []].append(event)
        }
        let rows = order.map { PickyCronCalendarJobRow(job: jobs[$0]!, occurrencesByDay: cells[$0] ?? [:]) }
        return rows.filter { isRepeating($0.job) } + rows.filter { !isRepeating($0.job) }
    }

    /// The earliest planned run at or after `now` across enabled jobs, independent
    /// of the visible period.
    static func nextRun(jobs: [PickyCronJobPresentation], now: Date) -> (job: PickyCronJobPresentation, date: Date)? {
        jobs.compactMap { job -> (job: PickyCronJobPresentation, date: Date)? in
            guard job.enabled else { return nil }
            let date = job.nextRunAt ?? (job.schedule == nil ? PickyCronJobReader.parseDate(job.runAtText) : nil)
            guard let date, date >= now else { return nil }
            return (job, date)
        }
        .min { $0.date == $1.date ? $0.job.id < $1.job.id : $0.date < $1.date }
    }

    static func groups(_ events: [PickyCronCalendarOccurrence]) -> [PickyCronCalendarGroup] {
        var groups: [String: [PickyCronCalendarOccurrence]] = [:]
        for event in events {
            let outcome: String
            if event.kind == .actual, let code = event.execution?.exitCode {
                outcome = code == 0 ? "success" : "failure"
            } else { outcome = "unknown" }
            groups[event.job.id + ":" + event.kind.rawValue + ":" + outcome, default: []].append(event)
        }
        return groups.values.compactMap { items in
            items.min(by: { $0.date < $1.date }).map { PickyCronCalendarGroup(event: $0, count: items.count, occurrences: items.sorted { $0.date < $1.date }) }
        }.sorted { $0.event.date == $1.event.date ? $0.id < $1.id : $0.event.date < $1.event.date }
    }

    static func initialHour(occurrences: [PickyCronCalendarOccurrence], now: Date, calendar: Calendar = .current) -> Int {
        let today = occurrences.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let target = today.first(where: { $0.date >= now }) ?? today.last ?? occurrences.first
        return max(0, calendar.component(.hour, from: target?.date ?? now) - 1)
    }

    static func schedule(_ job: PickyCronJobPresentation) -> String {
        guard let expression = job.schedule, job.once != true else { return L10n.t("hub.calendar.once") }
        let fields = expression.split(whereSeparator: \.isWhitespace)
        guard fields.count == 5 else { return L10n.t("hub.calendar.customSchedule") }
        if fields[0] == "*", fields.dropFirst().allSatisfy({ $0 == "*" }) {
            return L10n.t("hub.calendar.everyMinute")
        }
        if fields[0].hasPrefix("*/"), let step = Int(fields[0].dropFirst(2)), (1...59).contains(step),
           fields.dropFirst().allSatisfy({ $0 == "*" }) {
            return L10n.t("hub.calendar.everyMinutes", Int64(step))
        }
        guard let minute = Int(fields[0]), (0...59).contains(minute), fields[2] == "*", fields[3] == "*" else {
            return L10n.t("hub.calendar.customSchedule")
        }
        if fields[1] == "*", fields[4] == "*" { return L10n.t("hub.calendar.hourlyAt", Int64(minute)) }
        let hours = fields[1].split(separator: ",").compactMap { Int($0) }
        guard !hours.isEmpty, hours.count == fields[1].split(separator: ",").count, hours.allSatisfy({ (0...23).contains($0) }) else {
            return L10n.t("hub.calendar.customSchedule")
        }
        let times = hours.map { String(format: "%02d:%02d", $0, minute) }.joined(separator: ", ")
        switch fields[4] {
        case "*": return L10n.t("hub.calendar.dailyAt", times)
        case "1-5": return L10n.t("hub.calendar.weekdaysAt", times)
        case "0,6", "6,0": return L10n.t("hub.calendar.weekendsAt", times)
        default: return L10n.t("hub.calendar.customSchedule")
        }
    }

    static func symbol(_ event: PickyCronCalendarOccurrence) -> String {
        guard event.kind == .actual else { return event.kind == .next ? "clock" : "repeat" }
        guard let code = event.execution?.exitCode else { return "clock.arrow.circlepath" }
        return code == 0 ? "checkmark.circle.fill" : "exclamationmark.circle.fill"
    }

    static func status(_ event: PickyCronCalendarOccurrence) -> String {
        switch event.kind {
        case .next: return L10n.t("hub.calendar.scheduled")
        case .projected: return L10n.t("hub.calendar.estimated")
        case .actual:
            guard let code = event.execution?.exitCode else { return L10n.t("hub.calendar.executed") }
            return L10n.t(code == 0 ? "hub.calendar.succeeded" : "hub.calendar.failed")
        }
    }
}
