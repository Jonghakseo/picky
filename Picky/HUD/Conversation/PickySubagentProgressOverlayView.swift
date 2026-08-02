//
//  PickySubagentProgressOverlayView.swift
//  Picky
//
//  Read-only HUD projection for live runs reported by Pi's subagent extension.
//

import SwiftUI

private struct PickySubagentProgressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(PickyHUDInteractionStateLayer.fill(isHovered: hovered, isPressed: configuration.isPressed, isFocused: false))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: configuration.isPressed)
            .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.fast), value: hovered)
    }
}

struct PickySubagentProgressOverlayView: View {
    static let minimumCardWidth: CGFloat = 280
    static let maximumCardWidth: CGFloat = 700

    let presentation: PickySubagentProgressPresentation
    let isSessionRunning: Bool
    @Binding var isExpanded: Bool
    let isRunExpanded: (Int) -> Bool
    let toggleRunExpanded: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if isExpanded {
                Group {
                    if presentation.runningCount > 0 {
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            expandedCard(now: context.date)
                        }
                    } else {
                        expandedCard(now: Date())
                    }
                }
                .transition(expandedTransition)
            } else {
                Button { isExpanded = true } label: {
                    HStack(spacing: DS.Spacing.xs) {
                        progressRing(side: 16, lineWidth: 2)
                        Text(presentation.pillText)
                            .font(PickyHUDTypography.statusMonospacedMedium)
                    }
                    .foregroundColor(toneColor)
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .contentShape(Capsule(style: .continuous))
                }
                .buttonStyle(PickySubagentProgressButtonStyle())
                .background(pillBackground)
                .clipShape(Capsule(style: .continuous))
                .help(L10n.t("hud.subagent.show"))
                .accessibilityLabel(L10n.t("hud.subagent.show"))
                .accessibilityValue(presentation.pillText)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: DS.Animation.normal), value: isExpanded)
    }

    private func expandedCard(now: Date) -> some View {
        let _ = PickyPerf.event("subagent_progress_overlay_expanded")
        return VStack(alignment: .leading, spacing: 0) {
            Button { isExpanded = false } label: {
                HStack(spacing: DS.Spacing.sm) {
                    progressRing(side: 19, lineWidth: 2.4)
                    Text(presentation.headerText)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                    Spacer(minLength: DS.Spacing.sm)
                    Image(systemName: "chevron.down")
                        .pickyFont(size: 9.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                .padding(.horizontal, DS.Spacing.md)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(PickySubagentProgressButtonStyle())
            .help(L10n.t("hud.subagent.collapse"))
            .accessibilityLabel("\(presentation.headerText), \(L10n.t("hud.subagent.collapse"))")

            Divider().overlay(DS.Colors.borderSubtle.opacity(0.65))
            ScrollView(.vertical, showsIndicators: presentation.runs.count > 5) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(presentation.groups) { group in
                        if let label = group.label {
                            Text(label)
                                .font(PickyHUDTypography.metaMonospacedMedium)
                                .foregroundColor(DS.Colors.textTertiary)
                                .padding(.horizontal, DS.Spacing.md)
                                .padding(.top, DS.Spacing.sm)
                        }
                        ForEach(group.runs) { run in
                            runRow(run, now: now, indented: group.label != nil)
                        }
                    }
                }
            }
            .frame(maxHeight: 300)
        }
        .frame(minWidth: Self.minimumCardWidth, maxWidth: Self.maximumCardWidth, alignment: .trailing)
        .background(cardBackground)
        .accessibilityElement(children: .contain)
    }

    private func runRow(_ run: PickySubagentRun, now: Date, indented: Bool) -> some View {
        let expanded = isRunExpanded(run.runId)
        return Button { toggleRunExpanded(run.runId) } label: {
            VStack(alignment: .leading, spacing: DS.Spacing.xs) {
                HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.sm) {
                    runMarker(run).frame(width: 14, height: 14).accessibilityHidden(true)
                    Text(run.agent).font(PickyHUDTypography.statusMonospacedMedium).foregroundColor(runColor(run))
                    Text("#\(run.runId)").font(PickyHUDTypography.metaMonospacedMedium).foregroundColor(DS.Colors.textTertiary)
                    Text(rowText(run)).font(PickyHUDTypography.supporting).foregroundColor(run.status == .error ? DS.Colors.destructiveText : DS.Colors.textSecondary).lineLimit(1)
                    Spacer(minLength: DS.Spacing.xs)
                    Text(presentation.elapsedText(for: run, now: now)).font(PickyHUDTypography.metaMonospacedMedium).foregroundColor(DS.Colors.textTertiary)
                }
                if expanded, let preview = run.status == .error ? (run.resultPreview ?? run.errorClass) : run.resultPreview, !preview.isEmpty {
                    Text(preview).font(PickyHUDTypography.supporting).foregroundColor(run.status == .error ? DS.Colors.destructiveText : DS.Colors.textSecondary).lineLimit(8).fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 22)
                }
            }
            .padding(.leading, indented ? DS.Spacing.lg : 0)
            .padding(.horizontal, DS.Spacing.md)
            .padding(.vertical, DS.Spacing.sm)
            .contentShape(Rectangle())
        }
        .buttonStyle(PickySubagentProgressButtonStyle())
        .accessibilityLabel("\(run.agent) #\(run.runId): \(rowText(run))")
        .accessibilityValue(accessibilityStatus(run.status))
    }

    @ViewBuilder private func runMarker(_ run: PickySubagentRun) -> some View {
        switch run.status {
        case .done: Image(systemName: "checkmark.circle.fill").pickyFont(size: 13, weight: .semibold).foregroundColor(DS.Colors.successText)
        case .error: Image(systemName: "xmark.circle.fill").pickyFont(size: 13, weight: .semibold).foregroundColor(DS.Colors.destructiveText)
        case .running:
            if isSessionRunning && !reduceMotion { ProgressView().controlSize(.small).tint(DS.Colors.info) }
            else { Circle().trim(from: 0, to: 0.72).stroke(DS.Colors.info, style: StrokeStyle(lineWidth: 1.6, lineCap: .round)).rotationEffect(.degrees(-90)).frame(width: 12, height: 12) }
        }
    }

    private func rowText(_ run: PickySubagentRun) -> String { run.status == .error ? (run.errorClass ?? run.resultPreview?.components(separatedBy: .newlines).first ?? run.displayTask ?? run.task) : (run.displayTask ?? run.task) }
    private func accessibilityStatus(_ status: PickySubagentRunStatus) -> String { L10n.t("hud.subagent.status.\(status.rawValue)") }
    private func runColor(_ run: PickySubagentRun) -> Color { run.status == .running ? DS.Colors.info : (run.status == .done ? DS.Colors.successText : DS.Colors.destructiveText) }
    private var toneColor: Color { presentation.tone == .running ? DS.Colors.info : (presentation.tone == .success ? DS.Colors.successText : DS.Colors.destructiveText) }
    private var pillBackground: some View { Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.97)).overlay(Capsule(style: .continuous).stroke(toneColor.opacity(0.5), lineWidth: 0.8)) }
    private var cardBackground: some View { RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous).fill(DS.Colors.surface1.opacity(0.98)).overlay(RoundedRectangle(cornerRadius: DS.CornerRadius.extraLarge, style: .continuous).stroke(DS.Colors.borderSubtle.opacity(0.75), lineWidth: 0.8)).shadow(color: .black.opacity(0.18), radius: 12, y: 8) }
    private var expandedTransition: AnyTransition { reduceMotion ? .opacity : .scale(scale: 0.97, anchor: .top).combined(with: .opacity) }
    private func progressRing(side: CGFloat, lineWidth: CGFloat) -> some View { ZStack { Circle().stroke(DS.Colors.borderSubtle.opacity(0.7), lineWidth: lineWidth); if presentation.fraction > 0 { Circle().trim(from: 0, to: presentation.fraction).stroke(toneColor, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)).rotationEffect(.degrees(-90)) } }.frame(width: side, height: side).accessibilityHidden(true) }
}
