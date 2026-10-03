//
//  PickyCronJobsView.swift
//  Picky
//
//  Read-only Cron job details. Prompt files, cwd, and run logs are deliberately excluded.
//

import SwiftUI

struct PickyCronJobsView: View {
    let onBack: () -> Void
    private let reader: PickyCronJobReader
    @State private var result: PickyCronJobReadResult?

    init(onBack: @escaping () -> Void, reader: PickyCronJobReader = PickyCronJobReader()) {
        self.onBack = onBack
        self.reader = reader
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space4) {
            header

            Text("extensions.cron.jobs.description")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            content
        }
        .task { refresh() }
    }

    private var header: some View {
        HStack(spacing: DS.Spacing.space2) {
            Button(action: onBack) {
                Label(L10n.t("extensions.cron.jobs.back"), systemImage: "chevron.left")
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .help(L10n.t("extensions.cron.jobs.back"))

            Text("extensions.cron.jobs.title")
                .font(PickyHUDTypography.title)
                .foregroundColor(DS.Colors.textPrimary)

            Spacer(minLength: DS.Spacing.space2)

            Button(action: refresh) {
                Label(L10n.t("extensions.cron.jobs.refresh"), systemImage: "arrow.clockwise")
                    .font(PickyHUDTypography.labelSemibold)
                    .foregroundColor(DS.Colors.accentText)
            }
            .buttonStyle(.plain)
            .help(L10n.t("extensions.cron.jobs.refresh.help"))
        }
    }

    @ViewBuilder
    private var content: some View {
        switch result {
        case nil:
            stateMessage(
                symbol: "arrow.clockwise",
                title: L10n.t("extensions.cron.jobs.loading"),
                detail: nil,
                color: DS.Colors.info,
                showsProgress: true
            )
        case .missing:
            stateMessage(
                symbol: "calendar.badge.exclamationmark",
                title: L10n.t("extensions.cron.jobs.missing.title"),
                detail: L10n.t("extensions.cron.jobs.missing.description"),
                color: DS.Colors.textTertiary
            )
        case .empty:
            stateMessage(
                symbol: "calendar",
                title: L10n.t("extensions.cron.jobs.empty.title"),
                detail: L10n.t("extensions.cron.jobs.empty.description"),
                color: DS.Colors.textTertiary
            )
        case .malformed:
            stateMessage(
                symbol: "exclamationmark.triangle",
                title: L10n.t("extensions.cron.jobs.malformed.title"),
                detail: L10n.t("extensions.cron.jobs.malformed.description"),
                color: DS.Colors.destructiveText
            )
        case .unsupportedVersion(let version):
            stateMessage(
                symbol: "exclamationmark.triangle",
                title: L10n.t("extensions.cron.jobs.unsupported.title"),
                detail: L10n.t("extensions.cron.jobs.unsupported.description", Int64(version)),
                color: DS.Colors.warningText
            )
        case .unreadable:
            stateMessage(
                symbol: "exclamationmark.triangle",
                title: L10n.t("extensions.cron.jobs.unreadable.title"),
                detail: L10n.t("extensions.cron.jobs.unreadable.description"),
                color: DS.Colors.destructiveText
            )
        case .jobs(let jobs):
            VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                ForEach(jobs) { job in
                    jobRow(job)
                }
            }
        }
    }

    private func stateMessage(
        symbol: String,
        title: String,
        detail: String?,
        color: Color,
        showsProgress: Bool = false
    ) -> some View {
        HStack(alignment: .top, spacing: DS.Spacing.space3) {
            if showsProgress {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: symbol)
                    .font(PickyHUDTypography.supportingSemibold)
                    .foregroundColor(color)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                Text(title)
                    .font(PickyHUDTypography.bodyCompactSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                if let detail {
                    Text(detail)
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(DS.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(DS.Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func jobRow(_ job: PickyCronJobPresentation) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.space2) {
            HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
                Text(job.name)
                    .font(PickyHUDTypography.bodyCompactSemibold)
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(2)

                Spacer(minLength: DS.Spacing.space2)

                statusLabel(job.status)
            }

            if let schedule = job.scheduleText {
                Text(schedule)
                    .font(PickyHUDTypography.supportingMonospacedMedium)
                    .foregroundColor(DS.Colors.textSecondary)
                    .textSelection(.enabled)
            }

            VStack(alignment: .leading, spacing: DS.Spacing.space1) {
                metadataRow(
                    label: L10n.t("extensions.cron.jobs.nextRun"),
                    value: formatted(job.nextRunAt)
                )
                metadataRow(
                    label: L10n.t("extensions.cron.jobs.lastRun"),
                    value: formatted(job.lastRunAt ?? job.completedAt)
                )
                metadataRow(
                    label: L10n.t("extensions.cron.jobs.lastResult"),
                    value: exitResult(job.lastExitCode)
                )
            }
        }
        .padding(DS.Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 1)
        )
    }

    private func statusLabel(_ status: PickyCronJobStatus) -> some View {
        let presentation = statusPresentation(status)
        return Label(presentation.text, systemImage: presentation.symbol)
            .font(PickyHUDTypography.statusSemibold)
            .foregroundColor(presentation.color)
            .fixedSize()
    }

    private func statusPresentation(_ status: PickyCronJobStatus) -> (text: String, symbol: String, color: Color) {
        switch status {
        case .running:
            (L10n.t("extensions.cron.jobs.status.running"), "arrow.triangle.2.circlepath", DS.Colors.info)
        case .failed:
            (L10n.t("extensions.cron.jobs.status.failed"), "xmark.circle.fill", DS.Colors.destructiveText)
        case .completed:
            (L10n.t("extensions.cron.jobs.status.completed"), "checkmark.circle.fill", DS.Colors.successText)
        case .active:
            (L10n.t("extensions.cron.jobs.status.active"), "checkmark.circle", DS.Colors.successText)
        case .disabled:
            (L10n.t("extensions.cron.jobs.status.disabled"), "pause.circle", DS.Colors.textTertiary)
        }
    }

    private func metadataRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DS.Spacing.space2) {
            Text(label)
                .font(PickyHUDTypography.meta)
                .foregroundColor(DS.Colors.textTertiary)
            Spacer(minLength: DS.Spacing.space2)
            Text(value)
                .font(PickyHUDTypography.metaMonospacedMedium)
                .foregroundColor(DS.Colors.textSecondary)
                .multilineTextAlignment(.trailing)
        }
    }

    private func formatted(_ date: Date?) -> String {
        guard let date else { return L10n.t("extensions.cron.jobs.value.none") }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func exitResult(_ exitCode: Int?) -> String {
        guard let exitCode else { return L10n.t("extensions.cron.jobs.value.none") }
        if exitCode == 0 { return L10n.t("extensions.cron.jobs.exit.success") }
        return L10n.t("extensions.cron.jobs.exit.code", Int64(exitCode))
    }

    private func refresh() {
        result = reader.read()
    }
}
