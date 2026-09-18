import Combine
import Foundation

/// Calendar data changes independently from scrolling, hover and popover state.
struct PickyCronCalendarInput: Equatable {
    var jobs: [PickyCronJobPresentation]
    let interval: DateInterval
    let now: Date
    var showsRepeating = true
    var showsOnce = true
    var showsHistory = true
    var calendar = Calendar.current
}

struct PickyCronCalendarLayout {
    let result: PickyCronCalendarProjectionResult
    let events: [PickyCronCalendarOccurrence]
    let eventsByDay: [Date: [PickyCronCalendarOccurrence]]
    let dayGroups: [Date: [PickyCronCalendarGroup]]
    let hourGroups: [Date: [Int: [PickyCronCalendarGroup]]]

    init(_ input: PickyCronCalendarInput) {
        result = PickyCronCalendarProjection.occurrences(
            jobs: input.jobs.filter { $0.once == true || $0.schedule == nil ? input.showsOnce : input.showsRepeating },
            interval: input.interval, now: input.now, schedulerTimeZone: input.calendar.timeZone
        )
        events = result.occurrences.filter { input.showsHistory || $0.kind != .actual }
        eventsByDay = Dictionary(grouping: events) { input.calendar.startOfDay(for: $0.date) }
        dayGroups = eventsByDay.mapValues(PickyCronCalendarPresentation.groups)
        hourGroups = eventsByDay.mapValues { day in
            Dictionary(grouping: day) { input.calendar.component(.hour, from: $0.date) }
                .mapValues(PickyCronCalendarPresentation.groups)
        }
    }
}

@MainActor
final class PickyCronCalendarData: ObservableObject {
    @Published private(set) var layout: PickyCronCalendarLayout
    private var input: PickyCronCalendarInput

    init(_ input: PickyCronCalendarInput) {
        self.input = input
        layout = PickyCronCalendarLayout(input)
    }

    func update(_ input: PickyCronCalendarInput) {
        guard self.input != input else { return }
        self.input = input
        layout = PickyPerf.interval("cron_calendar_layout") { PickyCronCalendarLayout(input) }
    }
}
