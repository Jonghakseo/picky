import SwiftUI

/// Job-by-day matrix: one row per job, one column per day of the visible month grid.
/// Shows whether recurring jobs ran on schedule without repeating their names every day.
struct PickyHubCronCalendarJobsView: View {
    let rows: [PickyCronCalendarJobRow]
    let days: [Date]
    let month: Date
    let now: Date
    let calendar: Calendar
    let open: (Date, [PickyCronCalendarOccurrence]) -> Void
    @Environment(\.pickyAppFontScale) private var fontScale

    static func height(rows: [PickyCronCalendarJobRow], fontScale: CGFloat) -> CGFloat {
        guard !rows.isEmpty else { return 120 * fontScale }
        let sections = Set(rows.map { PickyCronCalendarPresentation.isRepeating($0.job) }).count
        return (headerHeight + CGFloat(sections) * sectionHeight + CGFloat(rows.count) * rowHeight) * fontScale
    }
    private static let headerHeight: CGFloat = 44
    private static let sectionHeight: CGFloat = 26
    private static let rowHeight: CGFloat = 40

    var body: some View {
        GeometryReader { proxy in
            let nameWidth = min(184 * fontScale, proxy.size.width * 0.28)
            VStack(spacing: 0) {
                if rows.isEmpty {
                    Text("hub.calendar.noOccurrences")
                        .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    header(nameWidth: nameWidth)
                    let repeating = rows.filter { PickyCronCalendarPresentation.isRepeating($0.job) }
                    let oneTime = rows.filter { !PickyCronCalendarPresentation.isRepeating($0.job) }
                    if !repeating.isEmpty {
                        section(L10n.t("hub.calendar.repeatingSection", Int64(repeating.count)), repeating, nameWidth: nameWidth)
                    }
                    if !oneTime.isEmpty {
                        section(L10n.t("hub.calendar.oneTimeSection", Int64(oneTime.count)), oneTime, nameWidth: nameWidth)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .accessibilityIdentifier("cron-job-matrix")
    }

    private func header(nameWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            Text("hub.calendar.jobColumn")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .medium)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .padding(.leading, PickyHubTheme.Spacing.field)
                .frame(width: nameWidth, alignment: .leading)
            ForEach(days, id: \.self) { day in
                let isToday = calendar.isDate(day, inSameDayAs: now)
                VStack(spacing: 2) {
                    Text(day, format: .dateTime.weekday(.narrow))
                        .pickyFont(size: 9, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    Text(verbatim: String(calendar.component(.day, from: day)))
                        .pickyFont(size: 10, weight: isToday ? .bold : .regular)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundColor(dayColor(day, isToday: isToday))
                        .frame(minWidth: 16 * fontScale, minHeight: 15 * fontScale)
                        .background { if isToday { Capsule().fill(PickyHubTheme.Colors.action) } }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(column(day))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(day.formatted(Date.FormatStyle(date: .complete, time: .omitted).locale(LocaleManager.nonisolatedEffectiveLocale)))
            }
            Color.clear.frame(width: DS.Spacing.space2)
        }
        .frame(height: Self.headerHeight * fontScale)
    }

    private func dayColor(_ day: Date, isToday: Bool) -> Color {
        if isToday { return PickyHubTheme.Colors.textOnAction }
        return calendar.isDate(day, equalTo: month, toGranularity: .month)
            ? PickyHubTheme.Colors.textSecondary : PickyHubTheme.Colors.textTertiary
    }

    private func column(_ day: Date) -> some View {
        Rectangle()
            .fill(calendar.isDate(day, inSameDayAs: now) ? PickyHubTheme.Colors.actionTint : Color.clear)
            .overlay(alignment: .leading) {
                if calendar.component(.weekday, from: day) == calendar.firstWeekday {
                    Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(width: 1)
                }
            }
    }

    private func section(_ title: String, _ rows: [PickyCronCalendarJobRow], nameWidth: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text(title)
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .semibold)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, PickyHubTheme.Spacing.field)
                .frame(height: Self.sectionHeight * fontScale)
                .background(PickyHubTheme.Colors.surface)
                .overlay(alignment: .top) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(height: 1) }
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in jobRow(row, nameWidth: nameWidth) }
        }
    }

    private func jobRow(_ row: PickyCronCalendarJobRow, nameWidth: CGFloat) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.job.name)
                    .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Text(subtitle(row))
                    .pickyFont(size: 11, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                    .lineLimit(1)
            }
            .padding(.leading, PickyHubTheme.Spacing.field)
            .padding(.trailing, DS.Spacing.space2)
            .frame(width: nameWidth, alignment: .leading)
            .help(row.job.name)
            ForEach(days, id: \.self) { day in
                cell(row, day: day)
            }
            Color.clear.frame(width: DS.Spacing.space2)
        }
        .frame(height: Self.rowHeight * fontScale)
        .overlay(alignment: .top) { Rectangle().fill(PickyHubTheme.Colors.borderSoft).frame(height: 0.5) }
    }

    private func subtitle(_ row: PickyCronCalendarJobRow) -> String {
        let schedule = PickyCronCalendarPresentation.schedule(row.job)
        guard !PickyCronCalendarPresentation.isRepeating(row.job),
              let first = row.occurrencesByDay.values.flatMap({ $0 }).map(\.date).min() else { return schedule }
        return schedule + " · " + first.formatted(.dateTime.month().day().hour().minute().locale(LocaleManager.nonisolatedEffectiveLocale))
    }

    @ViewBuilder private func cell(_ row: PickyCronCalendarJobRow, day: Date) -> some View {
        let events = row.occurrencesByDay[day] ?? []
        if let status = PickyCronCalendarPresentation.dayStatus(events) {
            let label = row.job.name + ", "
                + day.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(LocaleManager.nonisolatedEffectiveLocale))
                + ", " + PickyCronCalendarPresentation.status(status)
                + (events.count > 1 ? ", " + L10n.t("hub.calendar.runTimes", Int64(events.count)) : "")
            Button { open(day, events) } label: {
                PickyCronCalendarStatusMark(status: status)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(column(day))
            .help(label)
            .accessibilityLabel(label)
        } else {
            Circle().fill(PickyHubTheme.Colors.borderSoft).frame(width: 3, height: 3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(column(day))
                .accessibilityHidden(true)
        }
    }
}

/// Square status mark used by the job matrix cells and its legend.
struct PickyCronCalendarStatusMark: View {
    let status: PickyCronCalendarDayStatus
    @Environment(\.pickyAppFontScale) private var fontScale

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        ZStack {
            switch status {
            case .succeeded: shape.fill(PickyHubTheme.Colors.success)
            case .failed: shape.fill(PickyHubTheme.Colors.danger)
            case .executed: shape.fill(PickyHubTheme.Colors.muted)
            case .scheduled: shape.stroke(PickyHubTheme.Colors.action, lineWidth: 1.5)
            case .projected: shape.stroke(PickyHubTheme.Colors.muted, style: StrokeStyle(lineWidth: 1, dash: [2, 1.5]))
            }
        }
        .frame(width: 11 * fontScale, height: 11 * fontScale)
    }
}
