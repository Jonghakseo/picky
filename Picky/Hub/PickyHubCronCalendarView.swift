import SwiftUI

/// Start-time markers only: the job index does not provide planned durations or
/// a complete execution journal. Overflow opens the day's full projected list.
struct PickyHubCronCalendarView: View {
    let jobs: [PickyCronJobPresentation]
    var now: Date = Date()
    @State private var anchor = Date()
    @State private var showsMonth = false
    @State private var showsRepeating = true
    @State private var showsOnce = true
    @State private var showsHistory = true
    @State private var selection: PickyCronCalendarOccurrence?
    @State private var selectedDay: CalendarDay?

    init(jobs: [PickyCronJobPresentation], now: Date = Date()) {
        self.jobs = jobs
        self.now = now
        _anchor = State(initialValue: now)
    }

    private struct CalendarDay: Identifiable {
        let date: Date
        var id: Date { date }
    }

    private var calendar: Calendar {
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        return calendar
    }

    private var interval: DateInterval {
        let unit: Calendar.Component = showsMonth ? .month : .weekOfYear
        return calendar.dateInterval(of: unit, for: anchor)!
    }

    private var days: [Date] {
        let start = showsMonth ? calendar.dateInterval(of: .weekOfYear, for: interval.start)!.start : interval.start
        let end = showsMonth ? calendar.dateInterval(of: .weekOfYear, for: interval.end.addingTimeInterval(-1))!.end : interval.end
        return stride(from: 0, to: calendar.dateComponents([.day], from: start, to: end).day ?? 7, by: 1)
            .compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    private var visibleInterval: DateInterval {
        DateInterval(start: days.first ?? interval.start, end: calendar.date(byAdding: .day, value: 1, to: days.last ?? interval.start)!)
    }

    private var filteredJobs: [PickyCronJobPresentation] {
        jobs.filter { $0.once == true || $0.schedule == nil ? showsOnce : showsRepeating }
    }

    var body: some View {
        let projection = PickyCronCalendarProjection.occurrences(jobs: filteredJobs, interval: visibleInterval, now: now)
        let occurrences = projection.occurrences.filter { showsHistory || $0.kind != .actual }
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            filters
            VStack(spacing: 0) {
                toolbar
                if showsMonth {
                    HStack(spacing: 0) {
                        ForEach(Array(days.prefix(7)), id: \.self) { day in
                            Text(day, format: .dateTime.weekday(.abbreviated))
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .padding(.vertical, PickyHubTheme.Spacing.related)
                    monthGrid(occurrences)
                } else {
                    weekGrid(occurrences)
                }
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    Text("hub.calendar.startsOnly")
                    Spacer(minLength: 0)
                    Text(calendar.timeZone.identifier)
                }
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .padding(PickyHubTheme.Spacing.related)
            }
            .pickyHubCard(fill: PickyHubTheme.Colors.canvas)
            if projection.truncated {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.calendar.truncated"))
            }
            if !projection.unsupportedJobIDs.isEmpty {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.calendar.unsupportedRules"))
            }
            if occurrences.isEmpty {
                Text("hub.calendar.noOccurrences")
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
            unscheduledJobs(unsupported: projection.unsupportedJobIDs)
            Text("hub.calendar.history.note")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
        }
        .popover(item: $selection) { occurrence in
            PickyHubCronOccurrenceDetail(occurrence: occurrence)
        }
        .popover(item: $selectedDay) { day in
            dayDetails(day.date, occurrences: occurrences)
        }
    }

    private var filters: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PickyHubTheme.Spacing.field) { filterControls }
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) { filterControls }
        }
        .toggleStyle(.checkbox)
        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
    }

    @ViewBuilder private var filterControls: some View {
        Toggle("hub.calendar.repeating", isOn: $showsRepeating)
        Toggle("hub.calendar.once", isOn: $showsOnce)
        Toggle("hub.calendar.history", isOn: $showsHistory)
    }

    private var toolbar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                periodTitle
                periodControls
                Spacer(minLength: 0)
                modePicker
            }
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                periodTitle
                HStack { periodControls; Spacer(minLength: 0); modePicker }
            }
        }
        .padding(PickyHubTheme.Spacing.field)
    }

    private var periodTitle: some View {
        Group {
            if showsMonth {
                Text(anchor, format: .dateTime.year().month(.wide))
            } else {
                Text(interval.start.formatted(.dateTime.month().day()) + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day()))
            }
        }
        .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
        .fixedSize()
    }

    private var periodControls: some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }
                .accessibilityLabel(Text("hub.calendar.previous"))
            Button { move(1) } label: { Image(systemName: "chevron.right") }
                .accessibilityLabel(Text("hub.calendar.next"))
            Button("hub.calendar.today") { anchor = now }
        }
        .buttonStyle(.borderless)
    }

    private var modePicker: some View {
        Picker("hub.calendar.view", selection: $showsMonth) {
            Text("hub.calendar.week").tag(false)
            Text("hub.calendar.month").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 100)
    }

    private func move(_ value: Int) {
        anchor = calendar.date(byAdding: showsMonth ? .month : .weekOfYear, value: value, to: anchor) ?? anchor
    }

    private func weekGrid(_ occurrences: [PickyCronCalendarOccurrence]) -> some View {
        GeometryReader { viewport in
            ScrollView(.horizontal) {
                VStack(spacing: 0) {
                HStack(spacing: 0) {
                    Color.clear.frame(width: 44)
                    ForEach(days, id: \.self) { day in dayHeading(day).frame(maxWidth: .infinity) }
                }
                .frame(height: 64)
                Divider()
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        LazyVStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                hourRow(hour, occurrences: occurrences).id(hour)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 360)
                    .onAppear { proxy.scrollTo(8, anchor: .top) }
                }
            }
                .frame(width: max(660, viewport.size.width))
            }
        }
        .frame(height: 425)
    }

    private func hourRow(_ hour: Int, occurrences: [PickyCronCalendarOccurrence]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .frame(width: 44)
                .padding(.top, PickyHubTheme.Spacing.related)
            ForEach(days, id: \.self) { day in
                let matches = occurrences.filter {
                    calendar.isDate($0.date, inSameDayAs: day) && calendar.component(.hour, from: $0.date) == hour
                }
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    ForEach(Array(matches.prefix(3))) { event in eventButton(event) }
                    if matches.count > 3 { moreButton(day, count: matches.count - 3) }
                }
                .padding(DS.Spacing.space1)
                .frame(maxWidth: .infinity, minHeight: 64, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.actionTint : Color.clear)
                .overlay(alignment: .leading) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(width: 1) }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func monthGrid(_ occurrences: [PickyCronCalendarOccurrence]) -> some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
            ForEach(days, id: \.self) { day in
                let matches = occurrences.filter { calendar.isDate($0.date, inSameDayAs: day) }
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    Button { selectedDay = CalendarDay(date: day) } label: {
                        Text(day, format: .dateTime.day())
                            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                            .foregroundColor(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textPrimary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    ForEach(Array(matches.prefix(2))) { event in eventButton(event) }
                    if matches.count > 2 { moreButton(day, count: matches.count - 2) }
                    Spacer(minLength: 0)
                }
                .padding(DS.Spacing.space1)
                .frame(maxWidth: .infinity, minHeight: 132, maxHeight: 132, alignment: .topLeading)
                .background(calendar.isDate(day, equalTo: anchor, toGranularity: .month) ? PickyHubTheme.Colors.canvas : PickyHubTheme.Colors.surface)
                .overlay { Rectangle().stroke(PickyHubTheme.Colors.borderSoft, lineWidth: 0.5) }
            }
        }
    }

    private func dayHeading(_ day: Date) -> some View {
        VStack(spacing: DS.Spacing.space1) {
            Text(day, format: .dateTime.weekday(.abbreviated))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            Text(day, format: .dateTime.day())
                .pickyFont(size: PickyHubTheme.Typography.sectionTitle, weight: .medium)
        }
        .foregroundColor(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
    }

    private func eventButton(_ event: PickyCronCalendarOccurrence) -> some View {
        Button { selection = event } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: event.kind == .actual ? statusSymbol(event.job) : "clock")
                    Text(event.date, format: .dateTime.hour().minute())
                }
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                Text(event.job.name)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                    .lineLimit(1)
            }
            .foregroundColor(event.kind == .actual && event.job.lastExitCode.map({ $0 != 0 }) == true ? DS.Colors.destructiveText : PickyHubTheme.Colors.textPrimary)
            .padding(DS.Spacing.space1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(event.kind == .projected ? PickyHubTheme.Colors.canvas : PickyHubTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
            .overlay {
                RoundedRectangle(cornerRadius: DS.CornerRadius.compact)
                    .stroke(PickyHubTheme.Colors.border, style: StrokeStyle(lineWidth: 1, dash: event.kind == .projected ? [3, 2] : []))
            }
        }
        .buttonStyle(.plain)
        .help(event.job.name + " · " + event.date.formatted(date: .abbreviated, time: .shortened))
        .accessibilityLabel(event.job.name + ", " + event.date.formatted(date: .complete, time: .shortened) + ", " + eventKindLabel(event))
    }

    private func moreButton(_ day: Date, count: Int) -> some View {
        Button(L10n.t("hub.calendar.more", Int64(count))) { selectedDay = CalendarDay(date: day) }
            .buttonStyle(.borderless)
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
    }

    private func dayDetails(_ day: Date, occurrences: [PickyCronCalendarOccurrence]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                Text(day.formatted(date: .complete, time: .omitted))
                    .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                ForEach(occurrences.filter { calendar.isDate($0.date, inSameDayAs: day) }) { occurrence in
                    PickyHubCronOccurrenceDetail(occurrence: occurrence)
                    Divider()
                }
            }
            .padding(PickyHubTheme.Spacing.field)
        }
        .frame(width: 360, height: 440)
    }

    @ViewBuilder private func unscheduledJobs(unsupported: Set<String>) -> some View {
        let unscheduled = jobs.filter { !$0.enabled || ($0.nextRunAt == nil && $0.schedule == nil) || unsupported.contains($0.id) }
        if !unscheduled.isEmpty {
            DisclosureGroup("hub.calendar.otherJobs") {
                ForEach(unscheduled) { job in
                    HStack {
                        VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                            Text(job.name)
                            if let rule = job.scheduleText {
                                Text(rule).monospaced().foregroundColor(PickyHubTheme.Colors.textTertiary)
                            }
                        }
                        Spacer()
                        Label(statusTitle(job), systemImage: statusSymbol(job))
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    }
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                    .padding(.vertical, DS.Spacing.space1)
                }
            }
        }
    }
}

private func statusSymbol(_ job: PickyCronJobPresentation) -> String {
    switch job.status {
    case .running: "arrow.triangle.2.circlepath"
    case .failed: "exclamationmark.circle"
    case .completed: "checkmark.circle"
    case .disabled: "pause.circle"
    case .active: job.lastExitCode == 0 ? "checkmark.circle" : "clock"
    }
}

private func statusTitle(_ job: PickyCronJobPresentation) -> String {
    let key: String
    switch job.status {
    case .running: key = "running"
    case .failed: key = "failed"
    case .completed: key = "completed"
    case .disabled: key = "disabled"
    case .active: key = "active"
    }
    return L10n.t("extensions.cron.jobs.status." + key)
}

private func eventKindLabel(_ event: PickyCronCalendarOccurrence) -> String {
    switch event.kind {
    case .actual: L10n.t("hub.calendar.history")
    case .next: L10n.t("extensions.cron.jobs.nextRun")
    case .projected: L10n.t("hub.calendar.projected")
    }
}

struct PickyHubCronOccurrenceDetail: View {
    let occurrence: PickyCronCalendarOccurrence

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            Text(occurrence.job.name)
                .pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                .fixedSize(horizontal: false, vertical: true)
            Text(eventKindLabel(occurrence))
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
            Label(statusTitle(occurrence.job), systemImage: statusSymbol(occurrence.job))
            Text(occurrence.date.formatted(date: .complete, time: .shortened))
            if let schedule = occurrence.job.scheduleText { Text(schedule).monospaced().textSelection(.enabled) }
            Text(TimeZone.current.identifier).foregroundColor(PickyHubTheme.Colors.textSecondary)
            if let timezone = occurrence.job.timezone {
                Text(L10n.t("hub.calendar.scheduleTimezone", timezone))
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
            }
            Text("hub.calendar.startsOnly")
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
            Divider()
            if let date = occurrence.job.lastRunAt ?? occurrence.job.completedAt {
                Text("extensions.cron.jobs.lastRun")
                Text(date.formatted(date: .abbreviated, time: .shortened))
            }
            if let code = occurrence.job.lastExitCode {
                Text(code == 0 ? L10n.t("extensions.cron.jobs.exit.success") : L10n.t("extensions.cron.jobs.exit.code", Int64(code)))
                    .foregroundColor(code == 0 ? PickyHubTheme.Colors.success : DS.Colors.destructiveText)
            }
            Text("hub.calendar.history.note")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
        }
        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
        .padding(PickyHubTheme.Spacing.cardInset)
        .frame(width: 320, alignment: .leading)
    }
}
