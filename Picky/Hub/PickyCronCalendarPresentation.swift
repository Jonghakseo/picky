import Foundation

/// Calendar-facing policy shared by the week, month and compact agenda.
struct PickyCronCalendarGroup: Identifiable {
    let event: PickyCronCalendarOccurrence
    let count: Int
    let occurrences: [PickyCronCalendarOccurrence]
    var id: String { event.id }
}

enum PickyCronCalendarPresentation {
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
