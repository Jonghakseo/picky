import SwiftUI

struct PickyHubCronCalendarView: View {
    let jobs: [PickyCronJobPresentation]
    let now: Date
    let readPrompt: (PickyCronCalendarOccurrence) -> PickyCronInstructions
    let loadedHistoryInterval: DateInterval?
    let onVisibleIntervalChange: (DateInterval) -> Void
    @State private var anchor: Date
    @State private var showsMonth: Bool
    @State private var showsRepeating = true
    @State private var showsOnce = true
    @State private var showsHistory = true
    @State private var scrollHour: Int?
    @State private var needsEventFocus = false
    @State private var selection: PickyCronCalendarOccurrence?
    @State private var selectedDay: Date?
    @State private var prompt = PickyCronInstructions(result: .missing)
    @Environment(\.pickyAppFontScale) private var fontScale

    init(jobs: [PickyCronJobPresentation], now: Date = Date(), showsMonth: Bool = false,
         readPrompt: @escaping (PickyCronCalendarOccurrence) -> PickyCronInstructions = { _ in .init(result: .missing) },
         loadedHistoryInterval: DateInterval? = nil,
         onVisibleIntervalChange: @escaping (DateInterval) -> Void = { _ in }) {
        self.jobs = jobs
        self.now = now
        self.readPrompt = readPrompt
        self.loadedHistoryInterval = loadedHistoryInterval
        self.onVisibleIntervalChange = onVisibleIntervalChange
        _anchor = State(initialValue: now)
        _showsMonth = State(initialValue: showsMonth)
        var calendar = Calendar.current
        calendar.firstWeekday = 2
        let interval = calendar.dateInterval(of: .weekOfYear, for: now)!
        let occurrences = PickyCronCalendarProjection.occurrences(jobs: jobs, interval: interval, now: now).occurrences
        _scrollHour = State(initialValue: PickyCronCalendarPresentation.initialHour(occurrences: occurrences, now: now))
    }

    private var calendar: Calendar {
        var value = Calendar.current
        value.firstWeekday = 2
        return value
    }
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
    private var projection: PickyCronCalendarProjectionResult {
        PickyCronCalendarProjection.occurrences(
            jobs: jobs.filter { $0.once == true || $0.schedule == nil ? showsOnce : showsRepeating },
            interval: visibleInterval, now: now
        )
    }

    var body: some View {
        let result = projection
        let events = result.occurrences.filter { showsHistory || $0.kind != .actual }
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            VStack(spacing: 0) {
                toolbar(events)
                GeometryReader { viewport in
                    if viewport.size.width < 660 * fontScale {
                        agenda(events)
                    } else if showsMonth {
                        monthGrid(events)
                    } else {
                        weekGrid(events)
                    }
                }
                .frame(height: showsMonth ? CGFloat(days.count / 7) * monthRowHeight + 32 : 425)
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
        .onChange(of: visibleInterval, initial: true) { _, range in
            needsEventFocus = events.isEmpty
            onVisibleIntervalChange(range)
            focusSchedule(events)
        }
        .popover(isPresented: Binding(
            get: { selection != nil || selectedDay != nil },
            set: { if !$0 { selection = nil; selectedDay = nil } }
        )) {
            if let selection {
                PickyHubCronOccurrenceDetail(occurrence: currentSelection(selection, events: events), prompt: prompt.result, isHistoricalPrompt: prompt.isHistorical)
            } else if let selectedDay {
                dayList(selectedDay, events: events)
            }
        }
        .onChange(of: loadedHistoryInterval) { _, _ in
            focusSchedule(events)
            needsEventFocus = false
        }
        .onChange(of: jobs) { _, _ in
            if needsEventFocus, !events.isEmpty {
                focusSchedule(events)
                needsEventFocus = false
            }
            if let selected = selection {
                if jobs.contains(where: { $0.id == selected.job.id }) {
                    prompt = readPrompt(currentSelection(selected, events: events))
                } else {
                    selection = nil
                    prompt = .init(result: .missing)
                }
            }
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
            else { Text(interval.start.formatted(.dateTime.month().day()) + " – " + interval.end.addingTimeInterval(-1).formatted(.dateTime.month().day())) }
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
        Picker("hub.calendar.view", selection: $showsMonth) {
            Text("hub.calendar.week").tag(false)
            Text("hub.calendar.month").tag(true)
        }.pickerStyle(.segmented).labelsHidden().frame(width: 112)
    }
    private func move(_ value: Int) { anchor = calendar.date(byAdding: showsMonth ? .month : .weekOfYear, value: value, to: anchor) ?? anchor }
    private func focusSchedule(_ events: [PickyCronCalendarOccurrence]) {
        scrollHour = PickyCronCalendarPresentation.initialHour(occurrences: events, now: now)
    }

    private func weekGrid(_ events: [PickyCronCalendarOccurrence]) -> some View {
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
                            hourRow(hour, events: events)
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

    private func hourRow(_ hour: Int, events: [PickyCronCalendarOccurrence]) -> some View {
        HStack(alignment: .top, spacing: 0) {
            Text(String(format: "%02d:00", hour))
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .frame(width: 48).padding(.top, DS.Spacing.space2)
            ForEach(days, id: \.self) { day in
                let matches = events.filter { calendar.isDate($0.date, inSameDayAs: day) && calendar.component(.hour, from: $0.date) == hour }
                let groups = PickyCronCalendarPresentation.groups(matches)
                VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                    ForEach(Array(groups.prefix(3)), id: \.id) { group in
                        eventButton(group.event, count: group.count, day: day)
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

    private var monthRowHeight: CGFloat { 192 * fontScale }
    private func monthGrid(_ events: [PickyCronCalendarOccurrence]) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(days.prefix(7)), id: \.self) { day in
                    Text(day, format: .dateTime.weekday(.abbreviated)).frame(maxWidth: .infinity)
                }
            }.pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular).frame(height: 32)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 0) {
                ForEach(days, id: \.self) { day in
                    let groups = PickyCronCalendarPresentation.groups(events.filter { calendar.isDate($0.date, inSameDayAs: day) })
                    VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                        Button { selectedDay = day } label: {
                            Text(day, format: .dateTime.day()).frame(minWidth: 32, minHeight: 32)
                        }.buttonStyle(.borderless).accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                        ForEach(Array(groups.prefix(2)), id: \.id) { group in eventButton(group.event, count: group.count, day: day) }
                        if groups.count > 2 { moreButton(day, count: groups.count - 2) }
                        Spacer(minLength: 0)
                    }
                    .padding(DS.Spacing.space1)
                    .frame(maxWidth: .infinity, minHeight: monthRowHeight, maxHeight: monthRowHeight, alignment: .topLeading)
                    .background(calendar.isDate(day, equalTo: anchor, toGranularity: .month) ? PickyHubTheme.Colors.canvas : PickyHubTheme.Colors.surface)
                    .overlay { Rectangle().stroke(PickyHubTheme.Colors.borderSoft, lineWidth: 0.5) }
                }
            }
        }
    }

    private func eventButton(_ event: PickyCronCalendarOccurrence, count: Int = 1, day: Date? = nil) -> some View {
        Button {
            if count > 1, let day { selectedDay = day } else { select(event) }
        } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                HStack(spacing: DS.Spacing.space1) {
                    Image(systemName: PickyCronCalendarPresentation.symbol(event)).foregroundColor(eventColor(event))
                    Text(event.date, format: .dateTime.hour().minute())
                    if count > 1 { Text("×\(count)") }
                }.pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                Text(event.job.name).pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DS.Spacing.space1)
        }
        .buttonStyle(PickyCronCalendarEventButtonStyle(isProjected: event.kind == .projected))
        .help(event.job.name + " · " + PickyCronCalendarPresentation.status(event))
        .accessibilityLabel(event.job.name + ", " + event.date.formatted(date: .complete, time: .shortened) + ", " + PickyCronCalendarPresentation.status(event))
    }
    private func eventColor(_ event: PickyCronCalendarOccurrence) -> Color {
        guard event.kind == .actual, let code = event.execution?.exitCode else { return PickyHubTheme.Colors.textSecondary }
        return code == 0 ? PickyHubTheme.Colors.success : DS.Colors.destructiveText
    }
    private func moreButton(_ day: Date, count: Int) -> some View {
        Button(L10n.t("hub.calendar.more", Int64(count))) { selectedDay = day }
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
                    let groups = PickyCronCalendarPresentation.groups(events.filter { calendar.isDate($0.date, inSameDayAs: day) })
                    if !groups.isEmpty {
                        Text(day, format: .dateTime.month().day().weekday()).pickyFont(size: PickyHubTheme.Typography.body, weight: .semibold)
                        ForEach(groups, id: \.id) { group in eventButton(group.event, count: group.count, day: day) }
                    }
                }
                if events.isEmpty { Text("hub.calendar.noOccurrences") }
            }.padding(PickyHubTheme.Spacing.field)
        }
    }
    private func dayList(_ day: Date, events: [PickyCronCalendarOccurrence]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
                Text(day, format: .dateTime.month().day().weekday()).pickyFont(size: PickyHubTheme.Typography.cardTitle, weight: .semibold)
                ForEach(events.filter { calendar.isDate($0.date, inSameDayAs: day) }) { event in
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
            Label("hub.calendar.scheduled", systemImage: "clock")
            Label("hub.calendar.executed", systemImage: "checkmark.circle")
            Spacer(minLength: 0)
            Text("hub.calendar.estimatedLegend")
        }.pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
            .foregroundColor(PickyHubTheme.Colors.textTertiary).padding(PickyHubTheme.Spacing.related)
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
