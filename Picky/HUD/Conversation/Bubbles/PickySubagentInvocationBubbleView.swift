//
//  PickySubagentInvocationBubbleView.swift
//  Picky
//
//  Conversation-local presentation for a single subagent tool invocation.
//

import SwiftUI

struct PickySubagentInvocationBubbleView: View {
    let presentation: PickySubagentInvocationPresentation
    private let persistedIsExpanded: Bool
    let setExpanded: (Bool) -> Void
    let onOpenRunResponse: (PickySubagentInvocationRow) -> Void
    @State private var expansionState: PickySubagentInvocationExpansionState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(
        presentation: PickySubagentInvocationPresentation,
        isExpanded: Bool,
        setExpanded: @escaping (Bool) -> Void,
        onOpenRunResponse: @escaping (PickySubagentInvocationRow) -> Void
    ) {
        self.presentation = presentation
        persistedIsExpanded = isExpanded
        self.setExpanded = setExpanded
        self.onOpenRunResponse = onOpenRunResponse
        _expansionState = State(initialValue: PickySubagentInvocationExpansionState(isExpanded: isExpanded))
    }

    var body: some View {
        Group {
            if isExpanded, !presentation.isComplete || presentation.runningCount > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    content(now: context.date)
                }
            } else {
                content(now: Date())
            }
        }
        .accessibilityElement(children: .contain)
        .onChange(of: persistedIsExpanded) { _, nextValue in
            expansionState = PickySubagentInvocationExpansionState(isExpanded: nextValue)
        }
    }

    private var isExpanded: Bool { expansionState.isExpanded }

    private func content(now: Date) -> some View {
        let _ = PickyPerf.event("subagent_invocation_bubble")
        return VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Button(action: toggleExpanded) {
                header(now: now)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PickySubagentInvocationButtonStyle())
            .accessibilityIdentifier("picky.subagent.invocation.\(presentation.invocation.invocationId).disclosure")
            .accessibilityLabel(accessibilityHeader)
            .accessibilityValue(presentation.isComplete && !isExpanded ? presentation.collapsedText : presentation.statusText)
            .help(isExpanded ? L10n.t("hud.subagent.collapse") : L10n.t("hud.subagent.show"))

            if isExpanded {
                Divider().overlay(DS.Colors.borderSubtle.opacity(0.65))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.rows) { row in
                        rowView(row, now: now)
                    }
                }
                .accessibilityIdentifier("picky.subagent.invocation.\(presentation.invocation.invocationId).expanded")
                .transition(.opacity)
            }
        }
        .padding(DS.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                .fill(DS.Colors.surface2)
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous)
                        .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                )
        )
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.normal), value: isExpanded)
    }

    @ViewBuilder private func header(now: Date) -> some View {
        if presentation.isComplete && !isExpanded {
            let collapsedTone = presentation.collapsedTone
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Image(systemName: collapsedTone == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(color(for: collapsedTone))
                    .accessibilityHidden(true)
                Text(presentation.collapsedText)
                    .font(PickyHUDTypography.statusMonospacedMedium)
                    .foregroundColor(color(for: collapsedTone))
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                elapsedAndChevron(now: now)
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Image(systemName: "diamond.fill")
                    .pickyFont(size: 9.75, weight: .semibold)
                    .foregroundColor(DS.Colors.floatingGradientPurple)
                    .accessibilityHidden(true)
                Text(presentation.headerLabel)
                    .font(PickyHUDTypography.statusMonospacedMedium)
                    .foregroundColor(DS.Colors.floatingGradientPurple)
                    .lineLimit(1)
                Text(presentation.statusText)
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundColor(toneColor)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                elapsedAndChevron(now: now)
            }
            .overlay(alignment: .bottomLeading) {
                if let agents = presentation.chainAgentsText {
                    Text(agents)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .lineLimit(1)
                        .offset(y: DS.Spacing.md)
                }
            }
            .padding(.bottom, presentation.chainAgentsText == nil ? 0 : DS.Spacing.md)
        }
    }

    private func elapsedAndChevron(now: Date) -> some View {
        HStack(spacing: DS.Spacing.xs) {
            Text(presentation.elapsedText(now: now))
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(1)
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .pickyFont(size: 12, weight: .semibold)
                .foregroundColor(DS.Colors.textTertiary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private func rowView(_ row: PickySubagentInvocationRow, now: Date) -> some View {
        if row.hasResponseText && (row.status == .done || row.status == .error) {
            Button { onOpenRunResponse(row) } label: {
                rowContent(row, now: now)
                    .contentShape(Rectangle())
            }
            .buttonStyle(PickySubagentInvocationButtonStyle())
            .help("\(L10n.t("hud.subagent.row.openResponse"))\n\(taskText(for: row))")
            .accessibilityLabel("\(accessibilityRow(row)), \(taskText(for: row)), \(L10n.t("hud.subagent.row.openResponse"))")
        } else {
            rowContent(row, now: now)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityRow(row))
        }
    }

    private func rowContent(_ row: PickySubagentInvocationRow, now: Date) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                Image(systemName: symbolName(for: row.status))
                    .pickyFont(size: 10.5, weight: .semibold)
                    .foregroundColor(color(for: row.status))
                    .frame(width: DS.Spacing.lg, alignment: .center)
                    .accessibilityHidden(true)
                if let planIndex = row.planIndex, presentation.invocation.action == .chain {
                    Text("\(planIndex + 1).")
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(row.agent)
                    .font(PickyHUDTypography.statusMonospacedMedium)
                    .foregroundColor(color(for: row.status))
                    .lineLimit(1)
                if let runIDText = row.runIDText {
                    Text(runIDText)
                        .font(PickyHUDTypography.metaMonospacedMedium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                Text(row.displayText)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(row.status == .error ? DS.Colors.destructiveText : DS.Colors.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: DS.Spacing.xs)
                if let usage = presentation.contextUsage(for: row) {
                    PickySubagentContextUsageView(usage: usage)
                }
                Text(presentation.elapsedText(for: row, now: now))
                    .font(PickyHUDTypography.metaMonospacedMedium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            if presentation.hasActivityRowContent(for: row) {
                HStack(spacing: DS.Spacing.sm) {
                    Image(systemName: "arrow.right.circle.fill")
                        .pickyFont(size: 9.75, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: DS.Spacing.lg, alignment: .center)
                        .accessibilityHidden(true)
                    if let activity = presentation.activityText(for: row) {
                        Text(activity)
                            .font(PickyHUDTypography.metaMonospacedMedium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: DS.Spacing.xs)
                    if let toolCount = presentation.toolCountText(for: row) {
                        Text(toolCount)
                            .font(PickyHUDTypography.metaMonospacedMedium)
                            .foregroundColor(DS.Colors.textTertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
    }

    private func toggleExpanded() {
        expansionState = expansionState.toggled()
        setExpanded(expansionState.isExpanded)
    }

    private var accessibilityHeader: String {
        [presentation.headerLabel, presentation.chainAgentsText].compactMap { $0 }.joined(separator: ", ")
    }

    private func accessibilityRow(_ row: PickySubagentInvocationRow) -> String {
        [
            markerDescription(for: row.status),
            row.agent,
            row.runIDText,
            row.displayText,
            presentation.activityText(for: row),
            presentation.toolCountText(for: row),
            presentation.contextUsage(for: row).flatMap { ContextUsageBatteryDisplay(usage: $0)?.tooltip },
        ]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    private func taskText(for row: PickySubagentInvocationRow) -> String {
        L10n.t("hud.subagent.row.task", row.displayTask)
    }

    private var toneColor: Color { color(for: presentation.tone) }

    private func color(for tone: PickySubagentInvocationPresentation.Tone) -> Color {
        switch tone {
        case .running: DS.Colors.info
        case .success: DS.Colors.successText
        case .error: DS.Colors.destructiveText
        case .pending: DS.Colors.textTertiary
        }
    }

    private func color(for status: PickySubagentInvocationRow.Status) -> Color {
        switch status {
        case .pending: DS.Colors.textTertiary
        case .running: DS.Colors.info
        case .done: DS.Colors.successText
        case .error: DS.Colors.destructiveText
        }
    }

    private func symbolName(for status: PickySubagentInvocationRow.Status) -> String {
        switch status {
        case .pending: "circle"
        case .running: "arrow.triangle.2.circlepath"
        case .done: "checkmark.circle.fill"
        case .error: "xmark.circle.fill"
        }
    }

    private func markerDescription(for status: PickySubagentInvocationRow.Status) -> String {
        switch status {
        case .pending: L10n.t("hud.subagent.status.pending")
        case .running: L10n.t("hud.subagent.status.running")
        case .done: L10n.t("hud.subagent.status.done")
        case .error: L10n.t("hud.subagent.status.error")
        }
    }
}

private struct PickySubagentContextUsageView: View {
    let display: ContextUsageBatteryDisplay

    init?(usage: PickyContextUsage) {
        guard let display = ContextUsageBatteryDisplay(usage: usage) else { return nil }
        self.display = display
    }

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            ZStack {
                Circle()
                    .stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: 1.5)
                Circle()
                    .trim(from: 0, to: CGFloat(display.fraction))
                    .stroke(display.barColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 12, height: 12)
            Text(display.label)
                .font(PickyHUDTypography.metaMonospacedMedium)
                .fontWeight(.bold)
                .foregroundColor(display.textColor.opacity(0.9))
                .lineLimit(1)
        }
        .help(display.tooltip)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Context usage")
        .accessibilityValue(display.label)
    }
}

private struct PickySubagentInvocationButtonStyle: ButtonStyle {
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(PickyHUDInteractionStateLayer.fill(isHovered: hovered, isPressed: configuration.isPressed, isFocused: false))
            .onHover { hovered = $0 }
    }
}
