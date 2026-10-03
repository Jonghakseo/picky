//
//  PickyCustomSendTimeView.swift
//  Picky
//
//  "Custom time" screen that replaces the send-timing list inside the same
//  popover. The day chip opens a native menu (next two weeks + "Other date…"
//  for a month grid); the time chip accepts typing and opens 15-minute slots.
//

import AppKit
import SwiftUI

struct PickyCustomSendTimeView: View {
    @Binding var draft: PickyCustomSendTimeDraft
    var calendar: Calendar = .current
    var locale: Locale = LocaleManager.nonisolatedEffectiveLocale
    /// Injected for deterministic renders; production reads the clock.
    var fixedNow: Date?
    let onBack: () -> Void
    let onCancel: () -> Void
    let onSchedule: (Date) -> Void

    @FocusState private var isTimeFieldFocused: Bool

    private var now: Date { fixedNow ?? Date() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            HStack(spacing: DS.Spacing.space2) {
                dayChip
                timeChip
                    .frame(width: Self.timeChipWidth)
            }
            .padding(.horizontal, DS.Spacing.space3)
            .padding(.top, DS.Spacing.space1)
            if draft.isCalendarVisible {
                PickyCustomSendTimeMonthGrid(
                    draft: $draft,
                    now: now,
                    calendar: calendar,
                    locale: locale
                )
                .padding(.horizontal, DS.Spacing.space3)
                .padding(.top, DS.Spacing.space2)
            }
            footer
        }
        .onChange(of: isTimeFieldFocused) { _, focused in
            if !focused { commitTime() }
        }
    }

    // MARK: Header

    private var header: some View {
        Button(action: onBack) {
            HStack(spacing: DS.Spacing.space1) {
                Image(systemName: "chevron.left")
                    .font(PickyHUDTypography.minimumSemibold)
                    .foregroundColor(DS.Colors.textSecondary)
                Text(L10n.t("hud.composer.sendTiming.custom"))
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.top, DS.Spacing.space2)
        .padding(.bottom, DS.Spacing.space1)
        .accessibilityLabel(L10n.t("hud.composer.sendTiming.custom.back"))
    }

    // MARK: Chips

    private var dayChip: some View {
        PickyNativeMenuButton(makeMenuItems: dayMenuItems) {
            HStack(spacing: DS.Spacing.space1) {
                Text(PickyCustomSendTimePolicy.chipTitle(for: draft.day, now: now, calendar: calendar, locale: locale))
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Self.chevron
            }
            .modifier(PickyCustomSendTimeChipChrome(stroke: draft.isCalendarVisible ? DS.Colors.accent : nil))
        }
        .accessibilityLabel(L10n.t("hud.composer.sendTiming.custom.day"))
        .accessibilityValue(PickyCustomSendTimePolicy.dayTitle(for: draft.day, now: now, calendar: calendar, locale: locale))
    }

    private var timeChip: some View {
        HStack(spacing: 2) {
            TextField("", text: timeTextBinding)
                .textFieldStyle(.plain)
                .font(PickyHUDTypography.bodyCompact)
                .foregroundColor(draft.showsTimeError ? DS.Colors.destructiveText : DS.Colors.textPrimary)
                .focused($isTimeFieldFocused)
                .onSubmit(submitFromTimeField)
                .accessibilityLabel(L10n.t("hud.composer.sendTiming.custom.time"))
            PickyNativeMenuButton(makeMenuItems: slotMenuItems) {
                Self.chevron
                    .frame(width: 16, height: 20)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(L10n.t("hud.composer.sendTiming.custom.timeSlots"))
        }
        .modifier(PickyCustomSendTimeChipChrome(stroke: timeChipStroke, trailingPadding: DS.Spacing.space1))
    }

    private var timeChipStroke: Color? {
        if draft.showsTimeError { return DS.Colors.destructiveText }
        return isTimeFieldFocused ? DS.Colors.accent : nil
    }

    private var timeTextBinding: Binding<String> {
        Binding(
            get: { draft.timeText },
            set: { text in
                guard text != draft.timeText else { return }
                draft.timeText = text
                draft.showsTimeError = false
            }
        )
    }

    private static var chevron: some View {
        Image(systemName: "chevron.up.chevron.down")
            .font(PickyHUDTypography.minimumSemibold)
            .foregroundColor(DS.Colors.textTertiary)
    }

    private func dayMenuItems() -> [PickyNativeMenuItem] {
        let days = PickyCustomSendTimePolicy.listedDays(now: now, calendar: calendar)
        var items = days.map { day in
            PickyNativeMenuItem(
                title: PickyCustomSendTimePolicy.dayTitle(for: day, now: now, calendar: calendar, locale: locale),
                isChecked: calendar.isDate(day, inSameDayAs: draft.day)
            ) {
                PickyCustomSendTimePolicy.selectDay(day, in: &draft, calendar: calendar)
            }
        }
        items.append(.separator)
        items.append(PickyNativeMenuItem(title: L10n.t("hud.composer.sendTiming.custom.otherDate")) {
            draft.displayedMonth = PickyCustomSendTimePolicy.startOfMonth(for: draft.day, calendar: calendar)
            draft.isCalendarVisible = true
        })
        return items
    }

    private func slotMenuItems() -> [PickyNativeMenuItem] {
        let current: Date? = if case .valid(let date) = resolution { date } else { nil }
        return PickyCustomSendTimePolicy.timeSlots(on: draft.day, now: now, calendar: calendar).map { slot in
            PickyNativeMenuItem(
                title: PickyCustomSendTimePolicy.timeText(for: slot, calendar: calendar, locale: locale),
                isChecked: slot == current,
                isPositioned: current.map { abs(slot.timeIntervalSince($0)) < Double(PickyCustomSendTimePolicy.slotMinutes * 30) } ?? false
            ) {
                PickyCustomSendTimePolicy.selectSlot(slot, in: &draft, calendar: calendar, locale: locale)
            }
        }
    }

    // MARK: Footer

    private var resolution: PickyCustomSendTimeResolution {
        PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar)
    }

    private var footer: some View {
        HStack(spacing: DS.Spacing.space2) {
            footerStatus
                .lineLimit(1)
            Spacer(minLength: 0)
            Button(L10n.t("common.cancel"), action: onCancel)
                .controlSize(.small)
            Button(L10n.t("hud.composer.sendTiming.custom.schedule"), action: schedule)
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!isSchedulable)
        }
        .padding(DS.Spacing.space3)
    }

    @ViewBuilder
    private var footerStatus: some View {
        switch resolution {
        case .valid(let date):
            Text(PickyScheduledMessagesPresentation.relativeTitle(from: now, to: date))
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textTertiary)
        case .past:
            Text(L10n.t("hud.composer.sendTiming.custom.past"))
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.destructiveText)
        case .invalidTime:
            if draft.showsTimeError {
                Text(L10n.t("hud.composer.sendTiming.custom.timeExample"))
                    .font(PickyHUDTypography.status)
                    .foregroundColor(DS.Colors.destructiveText)
            }
        }
    }

    private var isSchedulable: Bool {
        if case .valid = resolution { return true }
        return false
    }

    private func commitTime() {
        PickyCustomSendTimePolicy.commitTimeText(&draft, now: now, calendar: calendar, locale: locale)
    }

    /// Enter in the time field sends when the time is readable and ahead, the
    /// same as pressing Schedule; otherwise it only shows what is wrong.
    private func submitFromTimeField() {
        commitTime()
        schedule()
    }

    private func schedule() {
        guard case .valid(let date) = PickyCustomSendTimePolicy.resolve(draft, now: now, calendar: calendar) else { return }
        onSchedule(date)
    }

    static let timeChipWidth: CGFloat = 96
}

// MARK: - Month grid

struct PickyCustomSendTimeMonthGrid: View {
    @Binding var draft: PickyCustomSendTimeDraft
    let now: Date
    let calendar: Calendar
    let locale: Locale

    var body: some View {
        VStack(spacing: DS.Spacing.space1) {
            HStack {
                Text(PickyCustomSendTimePolicy.monthTitle(for: draft.displayedMonth, calendar: calendar, locale: locale))
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Spacer()
                monthButton(offset: -1, symbol: "chevron.left", label: "hud.composer.sendTiming.custom.previousMonth")
                monthButton(offset: 1, symbol: "chevron.right", label: "hud.composer.sendTiming.custom.nextMonth")
            }
            .padding(.horizontal, Self.monthHeaderInset)
            HStack(spacing: 0) {
                ForEach(Array(PickyCustomSendTimePolicy.weekdaySymbols(calendar: calendar, locale: locale).enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: Self.cell)
                }
            }
            let days = PickyCustomSendTimePolicy.monthGrid(
                for: draft.displayedMonth,
                selectedDay: draft.day,
                now: now,
                calendar: calendar
            )
            VStack(spacing: 0) {
                ForEach(0..<(days.count / 7), id: \.self) { row in
                    HStack(spacing: 0) {
                        ForEach(days[(row * 7)..<(row * 7 + 7)]) { day in
                            dayCell(day)
                        }
                    }
                }
            }
        }
        .padding(DS.Spacing.space2)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface1.opacity(0.6))
        )
    }

    private func monthButton(offset: Int, symbol: String, label: String) -> some View {
        let enabled = PickyCustomSendTimePolicy.canShowMonth(offsetBy: offset, from: draft.displayedMonth, now: now, calendar: calendar)
        return Button {
            if let month = calendar.date(byAdding: .month, value: offset, to: draft.displayedMonth) {
                draft.displayedMonth = month
            }
        } label: {
            Image(systemName: symbol)
                .font(PickyHUDTypography.minimumSemibold)
                .foregroundColor(enabled ? DS.Colors.textSecondary : DS.Colors.textTertiary.opacity(0.5))
                .frame(width: 22, height: 22)
                .background(Circle().fill(enabled ? DS.Colors.surface3 : Color.clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(L10n.t(label))
    }

    private func dayCell(_ day: PickyCustomSendTimeCalendarDay) -> some View {
        let isSelected = day.isInDisplayedMonth && calendar.isDate(day.date, inSameDayAs: draft.day)
        return Button {
            PickyCustomSendTimePolicy.selectDay(day.date, in: &draft, calendar: calendar)
        } label: {
            ZStack {
                if isSelected {
                    Circle().fill(DS.Colors.accent)
                }
                Text("\(day.dayNumber)")
                    .font(isSelected || day.isToday ? PickyHUDTypography.supportingSemibold : PickyHUDTypography.supporting)
                    .monospacedDigit()
                    .foregroundColor(foreground(day, isSelected: isSelected))
                if day.isToday, !isSelected {
                    Circle()
                        .fill(DS.Colors.accentText)
                        .frame(width: 3.5, height: 3.5)
                        .offset(y: 9)
                }
            }
            .frame(width: Self.cell, height: Self.cell)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!day.isSelectable)
        .accessibilityLabel(PickyCustomSendTimePolicy.dateText(for: day.date, calendar: calendar, locale: locale))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func foreground(_ day: PickyCustomSendTimeCalendarDay, isSelected: Bool) -> Color {
        if isSelected { return .white }
        if !day.isSelectable { return DS.Colors.textTertiary.opacity(0.55) }
        if day.isToday { return DS.Colors.accentText }
        return DS.Colors.textPrimary
    }

    static let cell: CGFloat = 28
    /// Lines the month title and arrows up with the day grid's first and last
    /// cell, whose glyphs sit slightly inside the 28pt cell edge.
    static let monthHeaderInset: CGFloat = 2
}

// MARK: - Chip chrome

private struct PickyCustomSendTimeChipChrome: ViewModifier {
    let stroke: Color?
    var trailingPadding: CGFloat = DS.Spacing.space2

    func body(content: Content) -> some View {
        content
            .padding(.leading, DS.Spacing.space2)
            .padding(.trailing, trailingPadding)
            .frame(height: 28)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small + 1, style: .continuous)
                    .fill(DS.Colors.surface3)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.small + 1, style: .continuous)
                    .stroke(stroke ?? .clear, lineWidth: 1.5)
            )
    }
}

// MARK: - Native menu button

struct PickyNativeMenuItem {
    let title: String
    var isChecked = false
    /// The item the menu opens over, so a long slot list starts at the
    /// current value instead of midnight.
    var isPositioned = false
    var isSeparator = false
    var action: () -> Void = {}

    init(title: String, isChecked: Bool = false, isPositioned: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.isChecked = isChecked
        self.isPositioned = isPositioned
        self.action = action
    }

    private init(separator: Void) {
        title = ""
        isSeparator = true
    }

    static let separator = PickyNativeMenuItem(separator: ())
}

/// Custom-drawn label that opens a native NSMenu under itself. SwiftUI's
/// `Menu` cannot keep a custom chip background on macOS, and a nested popover
/// would count as an outside click for the transient send-timing popover.
private struct PickyNativeMenuButton<Label: View>: View {
    let makeMenuItems: () -> [PickyNativeMenuItem]
    @ViewBuilder let label: Label
    @State private var anchor = PickyNativeMenuAnchor()

    var body: some View {
        Button {
            anchor.popUp(makeMenuItems())
        } label: {
            label.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(PickyNativeMenuAnchorView(anchor: anchor))
    }
}

@MainActor
private final class PickyNativeMenuAnchor {
    weak var view: NSView?

    func popUp(_ items: [PickyNativeMenuItem]) {
        guard let view else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        var positioned: NSMenuItem?
        for item in items {
            if item.isSeparator {
                menu.addItem(.separator())
                continue
            }
            let menuItem = PickyClosureMenuItem(title: item.title, handler: item.action)
            menuItem.state = item.isChecked ? .on : .off
            menu.addItem(menuItem)
            if item.isPositioned || (positioned == nil && item.isChecked) { positioned = menuItem }
        }
        let below = view.isFlipped ? view.bounds.height + 4 : -4
        menu.popUp(positioning: positioned, at: NSPoint(x: 0, y: positioned == nil ? below : view.bounds.midY), in: view)
    }
}

private struct PickyNativeMenuAnchorView: NSViewRepresentable {
    let anchor: PickyNativeMenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PickyNativeMenuAnchorNSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}

private final class PickyNativeMenuAnchorNSView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PickyClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    @objc private func fire() { handler() }
}
