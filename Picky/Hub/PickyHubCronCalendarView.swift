import SwiftUI

/// Calendar presentations. The job matrix and month grid share the month period.
enum PickyCronCalendarMode: Hashable, CaseIterable {
    case jobs, month, week
    var showsMonthPeriod: Bool { self != .week }
}

struct PickyHubCronCalendarView: View {
    let jobs: [PickyCronJobPresentation]
    let now: Date
    let readPrompt: (PickyCronCalendarOccurrence) -> PickyCronInstructions
    let loadedHistoryInterval: DateInterval?
    let onVisibleIntervalChange: (DateInterval) -> Void
    @StateObject private var data: PickyCronCalendarData
    @State private var anchor: Date
    @State private var mode: PickyCronCalendarMode
    @State private var showsRepeating = true
    @State private var showsOnce = true
    @State private var showsHistory = true
    @State private var scrollHour: Int?
    @State private var needsEventFocus = false
    @State private var selection: PickyCronCalendarOccurrence?
    @State private var selectedDay: Date?
    @State private var selectedEventIDs: Set<String>?
    @State private var prompt = PickyCronInstructions(result: .missing)
    @Environment(\.pickyAppFontScale) private var fontScale

    init(jobs: [PickyCronJobPresentation], now: Date = Date(), mode: PickyCronCalendarMode = .jobs,
         readPrompt: @escaping (PickyCronCalendarOccurrence) -> PickyCronInstructions = { _ in .init(result: .missing) },
         loadedHistoryInterval: DateInterval? = nil,
         onVisibleIntervalChange: @escaping (DateInterval) -> Void = { _ in }) {
        self.jobs = jobs
        self.now = now
        self.readPrompt = readPrompt
        self.loadedHistoryInterval = loadedHistoryInterval
        self.onVisibleIntervalChange = onVisibleIntervalChange
        _anchor = State(initialValue: now)
        _mode = State(initialValue: mode)
        let showsMonth = mode.showsMonthPeriod
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let period = calendar.dateInterval(of: showsMonth ? .month : .weekOfYear, for: now)!
        let first = calendar.dateInterval(of: .weekOfYear, for: period.start)!.start
        let end = calendar.dateInterval(of: .weekOfYear, for: period.end.addingTimeInterval(-1))!.end
        let initialInterval = DateInterval(start: first, end: end)
        _data = StateObject(wrappedValue: PickyCronCalendarData(.init(
            jobs: jobs, interval: initialInterval, now: now, calendar: calendar
        )))
        // The target must exist before the first scroll layout; an onChange-only
        // target is overwritten by the scroll view's initial position update.
        let initialEvents = PickyCronCalendarProjection.occurrences(jobs: jobs, interval: initialInterval, now: now).occurrences
        _scrollHour = State(initialValue: PickyCronCalendarPresentation.initialHour(occurrences: initialEvents, now: now))
    }

    private var calendar: Calendar {
        var value = Calendar.current
        value.firstWeekday = 2
        return value
    }
    private var showsMonth: Bool { mode.showsMonthPeriod }
    private var interval: DateInterval { calendar.dateInterval(of: showsMonth ? .month : .weekOfYear, for: anchor)! }
    private var days: [Date] {
        let first = showsMonth ? calendar.dateInterval(of: .weekOfYear, for: interval.start)!.start : interval.start
        let end = showsMonth ? calendar.dateInterval(of: .weekOfYear, for: interval.end.addingTimeInterval(-1))!.end : interval.end
        return (0..<(calendar.dateComponents([.day], from: first, to: end).day ?? 7))
            .compactMap { calendar.date(byAdding: .day, value: $0, to: first) }
    }
    private var visibleInterval: DateInterval {
        .init(start: days.first!, end: calendar.date(byAdding: .day, value: 1, to: days.last!)!)
    }
    private var input: PickyCronCalendarInput {
        .init(jobs: jobs, interval: visibleInterval, now: now, showsRepeating: showsRepeating,
              showsOnce: showsOnce, showsHistory: showsHistory, calendar: calendar)
    }

    var body: some View {
        let result = data.layout.result
        let events = data.layout.events
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            VStack(spacing: 0) {
                toolbar(events)
                summary(events)
                GeometryReader { viewport in
                    if viewport.size.width < 660 * fontScale {
                        agenda(events)
                    } else {
                        switch mode {
                        case .jobs:
                            PickyHubCronCalendarJobsView(rows: data.layout.jobRows, days: days, month: anchor,
                                                         now: now, calendar: calendar, open: openEvents)
                        case .month: monthGrid()
                        case .week: weekGrid()
                        }
                    }
                }
                .frame(height: gridHeight)
                legend
            }
            .pickyHubCard(fill: PickyHubTheme.Colors.canvas)
            if jobs.contains(where: \.historyTruncated) {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.calendar.historyTruncated"))
            }
            if result.truncated {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.calendar.truncated"))
            }
            if !result.unsupportedJobIDs.isEmpty {
                PickyHubInlineStatus(tone: .warning, message: L10n.t("hub.calendar.unsupportedRules"))
            }
            inactiveJobs
        }
        .onChange(of: input) { _, value in data.update(value) }
        .onChange(of: visibleInterval, initial: true) { _, range in
            data.update(input)
            needsEventFocus = data.layout.events.isEmpty
            onVisibleIntervalChange(range)
            focusSchedule(data.layout.events)
        }
        .pickyInstantPopover(isPresented: Binding(
            get: { selection != nil || selectedDay != nil },
            set: { if !$0 { selection = nil; selectedDay = nil } }
        ), presentationIdentity: {
            if let selection { return AnyHashable(selection.id) }
            return selectedDay.map(AnyHashable.init)
        }) {
            if let selection {
                PickyHubCronOccurrenceDetail(occurrence: currentSelection(selection, events: events), prompt: prompt.result, isHistoricalPrompt: prompt.isHistorical)
            } else if let selectedDay {
                dayList(selectedDay)
            }
        }
        .onChange(of: loadedHistoryInterval) { _, _ in
            data.update(input)
            focusSchedule(data.layout.events)
            needsEventFocus = false
        }
        .onChange(of: jobs) { _, _ in
            data.update(input)
            if needsEventFocus, !data.layout.events.isEmpty {
                focusSchedule(data.layout.events)
                needsEventFocus = false
            }
            if let day = selectedDay, listedEvents(day).isEmpty {
                selectedDay = nil
                selectedEventIDs = nil
            }
            if let selected = selection {
                if data.layout.events.contains(where: { $0.id == selected.id }) {
                    prompt = readPrompt(currentSelection(selected, events: data.layout.events))
                } else {
                    selection = nil
                    prompt = .init(result: .missing)
                }
            }
        }
    }

    private var gridHeight: CGFloat {
        switch mode {
        case .jobs: PickyHubCronCalendarJobsView.height(rows: data.layout.jobRows, fontScale: fontScale)
        case .month: CGFloat(days.count / 7) * monthRowHeight + 32
        case .week: 425
        }
    }

    private func openEvents(_ day: Date, _ events: [PickyCronCalendarOccurrence]) {
        if events.count == 1, let event = events.first {
            select(event)
        } else {
            selectedEventIDs = Set(events.map(\.id))
            selectedDay = day
        }
    }

    /// Next planned run across all jobs plus the number of recorded runs in the shown period.
    private func summary(_ events: [PickyCronCalendarOccurrence]) -> some View {
        let runs = events.filter { $0.kind == .actual && interval.contains($0.date) }.count
        return TimelineView(.everyMinute) { context in
            let clock = max(now, context.date)
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Image(systemName: "clock").foregroundColor(PickyHubTheme.Colors.action)
                    .accessibilityHidden(true)
                Text("hub.calendar.nextRun").pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                if let next = PickyCronCalendarPresentation.nextRun(jobs: jobs, now: clock) {
                    let locale = LocaleManager.nonisolatedEffectiveLocale
                    let when = calendar.isDate(next.date, inSameDayAs: clock)
                        ? next.date.formatted(.dateTime.hour().minute().locale(locale))
                        : next.date.formatted(.dateTime.month().day().hour().minute().locale(locale))
                    Text(when + " · " + next.job.name)
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .lineLimit(1).truncationMode(.middle)
                    Text(next.date.formatted(Date.RelativeFormatStyle(presentation: .named, locale: locale)))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                        .lineLimit(1).fixedSize()
                } else {
                    Text("hub.calendar.noUpcoming")
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                }
                Spacer(minLength: PickyHubTheme.Spacing.related)
                Text(L10n.t("hub.calendar.periodRuns", Int64(runs)))
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1).fixedSize()
            }
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            .padding(.horizontal, PickyHubTheme.Spacing.field)
            .frame(minHeight: 40 * fontScale)
            .background(PickyHubTheme.Colors.surface)
            .overlay(alignment: .top) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(height: 1) }
        }
    }

    private func currentSelection(_ selected: PickyCronCalendarOccurrence, events: [PickyCronCalendarOccurrence]) -> PickyCronCalendarOccurrence {
        events.first { $0.id == selected.id } ?? selected
    }

    private func select(_ event: PickyCronCalendarOccurrence) {
        prompt = readPrompt(event)
        selection = event
    }

    private var hasActiveFilters: Bool { !showsRepeating || !showsOnce || !showsHistory }

    private var filterMenu: some View {
        Menu {
            Toggle("hub.calendar.repeating", isOn: $showsRepeating)
            Toggle("hub.calendar.once", isOn: $showsOnce)
            Toggle("hub.calendar.history", isOn: $showsHistory)
            Divider()
            Button("hub.calendar.showAll") {
                showsRepeating = true
                showsOnce = true
                showsHistory = true
            }
            .disabled(!hasActiveFilters)
        } label: {
            Image(systemName: hasActiveFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                .foregroundStyle(hasActiveFilters ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary)
                .frame(width: PickyHubTheme.Control.minimumHeight * fontScale,
                       height: PickyHubTheme.Control.minimumHeight * fontScale)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Text("hub.calendar.filters"))
        .accessibilityLabel(Text("hub.calendar.filters"))
        .accessibilityValue(Text(hasActiveFilters ? "hub.calendar.filtersActive" : "hub.calendar.showAll"))
    }

    private func toolbar(_ events: [PickyCronCalendarOccurrence]) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: PickyHubTheme.Spacing.related) {
                periodTitle
                periodControls(events)
                Spacer(minLength: 0)
                filterMenu
                modePicker
            }
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                periodTitle
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    periodControls(events)
                    Spacer(minLength: 0)
                    filterMenu
                    modePicker
                }
            }
        }
        .padding(PickyHubTheme.Spacing.field)
    }
    private var periodTitle: some View {
        Group {
            if showsMonth { Text(anchor, format: .dateTime.year().month(.wide)) }
            else { Text(interval.start.formatted(.dateTime.month().day().locale(LocaleManager.nonisolatedEffectiveLocale)) + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day().locale(LocaleManager.nonisolatedEffectiveLocale))) }
        }
        .pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
        .fixedSize()
    }
    private func periodControls(_ events: [PickyCronCalendarOccurrence]) -> some View {
        HStack(spacing: PickyHubTheme.Spacing.related) {
            Button { move(-1) } label: { Image(systemName: "chevron.left") }.accessibilityLabel(Text("hub.calendar.previous"))
            Button { move(1) } label: { Image(systemName: "chevron.right") }.accessibilityLabel(Text("hub.calendar.next"))
            Button("hub.calendar.today") { anchor = now; focusSchedule(events) }
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }
    private var modePicker: some View {
        Picker("hub.calendar.view", selection: $mode) {
            Text("hub.calendar.jobs").tag(PickyCronCalendarMode.jobs)
            Text("hub.calendar.month").tag(PickyCronCalendarMode.month)
            Text("hub.calendar.week").tag(PickyCronCalendarMode.week)
        }.pickerStyle(.segmented).labelsHidden().fixedSize()
    }
    private func move(_ value: Int) { anchor = calendar.date(byAdding: showsMonth ? .month : .weekOfYear, value: value, to: anchor) ?? anchor }
    private func focusSchedule(_ events: [PickyCronCalendarOccurrence]) {
        scrollHour = PickyCronCalendarPresentation.initialHour(occurrences: events, now: now)
    }

    private func weekGrid() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 48)
                ForEach(days, id: \.self) { dayHeading($0).frame(maxWidth: .infinity) }
            }.frame(height: 64)
            Divider()
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { hour in
                        VStack(spacing: 0) {
                            hourRow(hour)
                            Divider()
                        }.id(hour)
                    }
                }.scrollTargetLayout()
            }
            .scrollPosition(id: $scrollHour, anchor: .top)
            .frame(height: 360)
            .accessibilityIdentifier("cron-week-timeline")
        }
    }

    private func hourRow(_ hour: Int) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .frame(width: 48).padding(.top, DS.Spacing.space2)
            ForEach(days, id: \.self) { day in
                let groups = data.layout.hourGroups[day]?[hour] ?? []
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    ForEach(Array(groups.prefix(3)), id: \.id) { group in
                        eventButton(group)
                    }
                    if groups.count > 3 { moreButton(day, count: groups.count - 3) }
                }
                .padding(DS.Spacing.space1)
                .frame(maxWidth: .infinity, minHeight: 72 * fontScale, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.actionTint : Color.clear)
                .overlay(alignment: .leading) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(width: 1) }
            }
        }.fixedSize(horizontal: false, vertical: true)
    }

    private var monthRowHeight: CGFloat { 148 * fontScale }
    private func monthGrid() -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(day, format: .dateTime.weekday(.abbreviated))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, DS.Spacing.space3)
                }
            }
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .frame(height: 32)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in monthCell(day) }
            }
        }
    }

    /// One-time jobs are listed; recurring jobs fold into one line so they do not crowd the month.
    private func monthCell(_ day: Date) -> some View {
        let groups = data.layout.oneTimeDayGroups[day] ?? []
        let repeating = data.layout.repeatingByDay[day] ?? []
        let isToday = calendar.isDate(day, inSameDayAs: now)
        let inMonth = calendar.isDate(day, equalTo: anchor, toGranularity: .month)
        return VStack(alignment: .leading, spacing: DS.Spacing.space1) {
            Button { openDay(day) } label: {
                HStack(spacing: DS.Spacing.space1) {
                    Text(verbatim: String(calendar.component(.day, from: day)))
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: isToday ? .bold : .medium)
                        .monospacedDigit()
                        .foregroundColor(isToday ? PickyHubTheme.Colors.textOnAction
                                         : (inMonth ? PickyHubTheme.Colors.textSecondary : PickyHubTheme.Colors.textTertiary))
                        .frame(minWidth: 22 * fontScale, minHeight: 22 * fontScale)
                        .background { if isToday { Circle().fill(PickyHubTheme.Colors.action) } }
                    if calendar.component(.day, from: day) == 1 {
                        Text(day, format: .dateTime.month(.abbreviated))
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    }
                    if isToday {
                        Text("hub.calendar.today").fontWeight(.semibold).foregroundColor(PickyHubTheme.Colors.action)
                    }
                }
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(LocaleManager.nonisolatedEffectiveLocale)))
            ForEach(Array(groups.prefix(2)), id: \.id) { group in eventButton(group, nameLines: 1) }
            if groups.count > 2 { moreButton(day, count: groups.count - 2) }
            if !repeating.isEmpty { repeatingLine(day, events: repeating) }
            Spacer(minLength: 0)
        }
        .padding(DS.Spacing.space1)
        .frame(maxWidth: .infinity, minHeight: monthRowHeight, maxHeight: monthRowHeight, alignment: .topLeading)
        .background(isToday ? PickyHubTheme.Colors.actionTint : (inMonth ? PickyHubTheme.Colors.canvas : PickyHubTheme.Colors.surface))
        .overlay { Rectangle().stroke(PickyHubTheme.Colors.borderSoft, lineWidth: 0.5) }
    }

    private func repeatingLine(_ day: Date, events: [PickyCronCalendarOccurrence]) -> some View {
        let jobCount = Set(events.map(\.job.id)).count
        let status = PickyCronCalendarPresentation.dayStatus(events) ?? .projected
        let title = L10n.t("hub.calendar.repeatingCount", Int64(jobCount))
        return Button { openEvents(day, events) } label: {
            HStack(spacing: DS.Spacing.space1) {
                Image(systemName: PickyCronCalendarPresentation.symbol(status)).foregroundColor(statusColor(status))
                Text(title).lineLimit(1)
                Spacer(minLength: 0)
            }
            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textTertiary)
            .padding(.horizontal, DS.Spacing.space1)
            .frame(minHeight: 20 * fontScale)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(Set(events.map(\.job.name)).sorted().joined(separator: "\n"))
        .accessibilityLabel(title + ", " + PickyCronCalendarPresentation.status(status))
    }

    private func statusColor(_ status: PickyCronCalendarDayStatus) -> Color {
        switch status {
        case .succeeded: PickyHubTheme.Colors.success
        case .failed: DS.Colors.destructiveText
        case .scheduled: PickyHubTheme.Colors.action
        case .executed, .projected: PickyHubTheme.Colors.textTertiary
        }
    }

    private func eventButton(_ group: PickyCronCalendarGroup, nameLines: Int = 2) -> some View {
        let event = group.event
        let count = group.count
        return Button {
            if count > 1 {
                selectedEventIDs = Set(group.occurrences.map(\.id))
                selectedDay = calendar.startOfDay(for: event.date)
            } else { select(event) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: PickyCronCalendarPresentation.symbol(event)).foregroundColor(eventColor(event))
                    Text(event.date, format: .dateTime.hour().minute()).lineLimit(1)
                }.pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space1) {
                    Text(event.job.name).pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium).lineLimit(nameLines)
                    if count > 1 {
                        Text(L10n.t("hub.calendar.runTimes", Int64(count)))
                            .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                            .foregroundColor(PickyHubTheme.Colors.textTertiary)
                            .fixedSize()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.space1)
        }
        .buttonStyle(PickyCronCalendarEventButtonStyle(isProjected: event.kind == .projected))
        .help(event.job.name + " · " + PickyCronCalendarPresentation.status(event))
        .accessibilityLabel(event.job.name + ", " + event.date.formatted(Date.FormatStyle(date: .complete, time: .shortened).locale(LocaleManager.nonisolatedEffectiveLocale)) + ", " + PickyCronCalendarPresentation.status(event))
    }
    private func eventColor(_ event: PickyCronCalendarOccurrence) -> Color {
        if event.kind == .next { return PickyHubTheme.Colors.action }
        guard event.kind == .actual, let code = event.execution?.exitCode else { return PickyHubTheme.Colors.textSecondary }
        return code == 0 ? PickyHubTheme.Colors.success : DS.Colors.destructiveText
    }
    private func openDay(_ day: Date) {
        selectedEventIDs = nil
        selectedDay = day
    }
    private func moreButton(_ day: Date, count: Int) -> some View {
        Button(L10n.t("hub.calendar.more", Int64(count))) { openDay(day) }
            .buttonStyle(.borderless).pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
    }
    private func dayHeading(_ day: Date) -> some View {
        VStack(spacing: DS.Spacing.space1) {
            Text(day, format: .dateTime.weekday(.abbreviated)).pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            Text(day, format: .dateTime.day()).pickyFont(size: PickyHubTheme.Typography.sectionTitle, weight: .medium)
        }.foregroundColor(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.action : PickyHubTheme.Colors.textSecondary)
    }
    private func agenda(_ events: [PickyCronCalendarOccurrence]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                Text("hub.calendar.compactAgenda").foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                ForEach(days, id: \.self) { day in
                    let groups = data.layout.dayGroups[day] ?? []
                    if !groups.isEmpty {
                        Text(day, format: .dateTime.month().day().weekday()).pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                        ForEach(groups, id: \.id) { group in eventButton(group) }
                    }
                }
                if events.isEmpty { Text("hub.calendar.noOccurrences") }
            }.padding(PickyHubTheme.Spacing.field)
        }
    }
    private func listedEvents(_ day: Date) -> [PickyCronCalendarOccurrence] {
        (data.layout.eventsByDay[day] ?? []).filter { selectedEventIDs?.contains($0.id) ?? true }
    }
    private func dayList(_ day: Date) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                Text(day, format: .dateTime.month().day().weekday()).pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                ForEach(listedEvents(day)) { event in
                    Button { selectedDay = nil; select(event) } label: {
                        HStack {
                            Image(systemName: PickyCronCalendarPresentation.symbol(event)).foregroundColor(eventColor(event))
                            Text(event.date, format: .dateTime.hour().minute()).monospacedDigit()
                            Text(event.job.name).lineLimit(2)
                        }.frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
                    }.buttonStyle(.borderless)
                }
            }.padding(PickyHubTheme.Spacing.cardInset)
        }.frame(width: 400, height: 440)
    }
    private var legend: some View {
        HStack(spacing: PickyHubTheme.Spacing.field) {
            ForEach([PickyCronCalendarDayStatus.succeeded, .failed, .executed, .scheduled, .projected], id: \.self) { status in
                HStack(spacing: DS.Spacing.space1) {
                    if mode == .jobs {
                        PickyCronCalendarStatusMark(status: status)
                    } else {
                        Image(systemName: PickyCronCalendarPresentation.symbol(status)).foregroundColor(statusColor(status))
                    }
                    Text(status == .projected && mode != .jobs ? L10n.t("hub.calendar.estimatedLegend")
                         : PickyCronCalendarPresentation.status(status))
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            switch mode {
            case .jobs: Text("hub.calendar.cellHint").lineLimit(1)
            case .month: Text("hub.calendar.repeatingHint").lineLimit(1)
            case .week: EmptyView()
            }
        }
        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
        .foregroundColor(PickyHubTheme.Colors.textTertiary)
        .padding(.horizontal, PickyHubTheme.Spacing.field)
        .padding(.vertical, PickyHubTheme.Spacing.related)
        .overlay(alignment: .top) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(height: 1) }
    }
    @ViewBuilder private var inactiveJobs: some View {
        let inactive = jobs.filter { !$0.enabled && $0.status != .completed }
        if !inactive.isEmpty {
            DisclosureGroup("hub.calendar.otherJobs") {
                ForEach(inactive) { job in
                    HStack { Text(job.name); Spacer(); Text("extensions.cron.jobs.status.disabled") }
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                }
            }
        }
    }
}

private struct PickyCronCalendarEventButtonStyle: ButtonStyle {
    let isProjected: Bool
    @State private var isHovering = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundColor(PickyHubTheme.Colors.textPrimary)
            .background(isHovering || configuration.isPressed ? PickyHubTheme.Colors.navHighlight : PickyHubTheme.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.compact))
            .overlay {
                RoundedRectangle(cornerRadius: DS.CornerRadius.compact)
                    .stroke(PickyHubTheme.Colors.border, style: StrokeStyle(lineWidth: 1, dash: isProjected ? [3, 2] : []))
            }
            .onHover { isHovering = $0 }
    }
}
