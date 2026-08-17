//
//  PickySessionProgressView.swift
//  Picky
//
//  Session progress dashboard for the HUD utility panel.
//

import SwiftUI

enum PickySessionProgressItem: Equatable, Identifiable {
    case entry(PickyToolHistoryEntry)
    case investigation(count: Int)

    var id: String {
        switch self {
        case let .entry(entry): entry.id
        case .investigation: "investigation-summary"
        }
    }
}

struct PickySessionProgressSummary: Equatable {
    let changedFileCount: Int
    let commandCount: Int
    let agentCount: Int
}

enum PickySessionProgressHeaderState: Equatable {
    case running(PickyToolHistoryEntry)
    case working
    case waitingForInput
    case failed
    case blocked
    case queued
    case completed
    case cancelled
}

struct PickySessionProgressHeaderPresentation: Equatable {
    let state: PickySessionProgressHeaderState

    var sectionTitleKey: String {
        switch state {
        case .completed, .cancelled: "hud.progress.recent"
        case .running, .working, .waitingForInput, .failed, .blocked, .queued: "hud.progress.current"
        }
    }

    var statusKey: String {
        switch state {
        case .running: "hud.progress.status.running"
        case .working: "hud.progress.status.working"
        case .waitingForInput: "hud.progress.status.needsInput"
        case .failed: "hud.progress.status.failed"
        case .blocked: "hud.progress.status.blocked"
        case .queued: "hud.progress.status.queued"
        case .completed: "hud.progress.status.succeeded"
        case .cancelled: "hud.progress.status.cancelled"
        }
    }

    var detailKey: String? {
        switch state {
        case .running: nil
        case .working: "hud.progress.working"
        case .waitingForInput: "hud.progress.needsInput"
        case .failed: "hud.progress.sessionFailed"
        case .blocked: "hud.progress.blocked"
        case .queued: "hud.progress.queued"
        case .completed: "hud.progress.idle"
        case .cancelled: "hud.progress.cancelled"
        }
    }

    var symbolName: String {
        switch state {
        case .running: "gearshape"
        case .working: "ellipsis.circle"
        case .waitingForInput: "hourglass"
        case .failed: "exclamationmark.triangle"
        case .blocked: "hand.raised"
        case .queued: "clock"
        case .completed: "checkmark.circle"
        case .cancelled: "minus.circle"
        }
    }

    var tone: PickyHUDStatusTone {
        switch state {
        case .running, .working: .inProgress
        case .failed, .blocked: .error
        case .completed: .completed
        case .waitingForInput, .queued, .cancelled: .other
        }
    }

    var accessibilityLabelKey: String { sectionTitleKey }
    var accessibilityValueKey: String { statusKey }
}

struct PickySessionProgressProjection: Equatable {
    static let maximumKeyItemCount = 12

    let header: PickySessionProgressHeaderPresentation
    let rawEntries: [PickyToolHistoryEntry]
    let keyItems: [PickySessionProgressItem]
    let hiddenKeyItemCount: Int
    let summary: PickySessionProgressSummary

    var rawDetailCount: Int { rawEntries.count }

    static func project(
        tools: [PickyToolActivity],
        sessionStatus: PickySessionStatus = .completed
    ) -> Self {
        let entries = Array(PickyToolHistoryRenderer.entries(from: tools).reversed())
        let keyItems = keyItems(from: entries)
        let changedFiles = Set(entries.compactMap(filePath(for:)))
        let agentIDs = Set(entries.flatMap(agentIDs(for:)))
        return Self(
            header: header(for: entries, sessionStatus: sessionStatus),
            rawEntries: entries,
            keyItems: Array(keyItems.prefix(maximumKeyItemCount)),
            hiddenKeyItemCount: max(0, keyItems.count - maximumKeyItemCount),
            summary: PickySessionProgressSummary(
                changedFileCount: changedFiles.count,
                commandCount: entries.count { $0.category == .bash },
                agentCount: agentIDs.count
            )
        )
    }

    static func isInvestigation(_ entry: PickyToolHistoryEntry) -> Bool {
        guard entry.status == .succeeded else { return false }
        if entry.category == .read { return true }

        let normalizedName = entry.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["grep", "rg", "search", "find", "glob"].contains(normalizedName) { return true }

        guard case let .bash(command, _, _) = entry.detail,
              let command
        else { return false }
        return isSafeSearchCommand(command)
    }

    private static func keyItems(from entries: [PickyToolHistoryEntry]) -> [PickySessionProgressItem] {
        let investigationCount = entries.count(where: isInvestigation)
        var didAddInvestigationSummary = false
        return entries.compactMap { entry -> PickySessionProgressItem? in
            if isInvestigation(entry) {
                guard !didAddInvestigationSummary else { return nil }
                didAddInvestigationSummary = true
                return .investigation(count: investigationCount)
            }
            guard isMeaningful(entry) else { return nil }
            return .entry(entry)
        }
    }

    private static func header(
        for entries: [PickyToolHistoryEntry],
        sessionStatus: PickySessionStatus
    ) -> PickySessionProgressHeaderPresentation {
        if let runningEntry = entries.first(where: { $0.status == .running }) {
            return .init(state: .running(runningEntry))
        }
        let state: PickySessionProgressHeaderState
        switch sessionStatus {
        case .running: state = .working
        case .waiting_for_input: state = .waitingForInput
        case .failed: state = .failed
        case .blocked: state = .blocked
        case .queued: state = .queued
        case .completed: state = .completed
        case .cancelled: state = .cancelled
        }
        return .init(state: state)
    }

    private static func isMeaningful(_ entry: PickyToolHistoryEntry) -> Bool {
        entry.status != .succeeded || entry.category == .edit || entry.category == .write || entry.category == .bash || entry.isAgentActivity
    }

    private static func isSafeSearchCommand(_ command: String) -> Bool {
        let normalized = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty,
              ![";", "&&", "||", "|", ">", "<", "$(", "`", "&", "\n", "\r"].contains(where: normalized.contains)
        else { return false }

        let tokens = normalized.split(whereSeparator: \.isWhitespace).map(String.init)
        guard let executable = tokens.first else { return false }
        let isSearchCommand = executable == "rg" || executable == "grep" || executable == "ag" || executable == "find"
            || (executable == "git" && tokens.dropFirst().first == "grep")
        guard isSearchCommand else { return false }

        if executable == "find" {
            let mutatingActions = Set(["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf"])
            guard !tokens.contains(where: mutatingActions.contains) else { return false }
        }
        return true
    }

    private static func filePath(for entry: PickyToolHistoryEntry) -> String? {
        switch entry.detail {
        case let .edit(file, _), let .write(file, _): file
        default: nil
        }
    }

    private static func agentIDs(for entry: PickyToolHistoryEntry) -> [String] {
        guard case let .subagent(_, agents, _, _) = entry.detail else { return [] }
        return agents.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}

struct PickySessionProgressView: View {
    let session: PickySessionListViewModel.SessionCard
    @State private var showsDetails = false

    var body: some View {
        let projection = PickySessionProgressProjection.project(tools: session.tools, sessionStatus: session.status)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                currentWork(projection)
                summary(projection.summary)
                if projection.keyItems.isEmpty {
                    emptyState
                } else {
                    keyProgress(projection)
                }
                detailsDisclosure(projection)
            }
            .padding(DS.Spacing.sm)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.progress.accessibilityLabel"))
    }

    private func currentWork(_ projection: PickySessionProgressProjection) -> some View {
        let header = projection.header
        let detail: String
        if case let .running(entry) = header.state {
            detail = title(for: entry)
        } else if let detailKey = header.detailKey {
            detail = L10n.t(detailKey)
        } else {
            detail = ""
        }
        return HStack(spacing: DS.Spacing.sm) {
            Image(systemName: header.symbolName)
                .font(PickyHUDTypography.supportingSemibold)
                .foregroundStyle(statusColor(for: header))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.t(header.sectionTitleKey))
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundStyle(DS.Colors.textTertiary)
                Text(detail)
                    .font(PickyHUDTypography.supportingMedium)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(L10n.t(header.statusKey))
                .font(PickyHUDTypography.metaSemibold)
                .foregroundStyle(statusColor(for: header))
        }
        .padding(DS.Spacing.sm)
        .background(DS.Colors.surface2)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L10n.t(header.accessibilityLabelKey))
        .accessibilityValue("\(L10n.t(header.accessibilityValueKey)), \(detail)")
    }

    private func summary(_ summary: PickySessionProgressSummary) -> some View {
        HStack(spacing: DS.Spacing.sm) {
            summaryLabel(L10n.t("hud.progress.summary.files", summary.changedFileCount))
            summaryLabel(L10n.t("hud.progress.summary.commands", summary.commandCount))
            summaryLabel(L10n.t("hud.progress.summary.agents", summary.agentCount))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private func summaryLabel(_ text: String) -> some View {
        Text(text)
            .font(PickyHUDTypography.meta)
            .foregroundStyle(DS.Colors.textSecondary)
    }

    private func keyProgress(_ projection: PickySessionProgressProjection) -> some View {
        VStack(alignment: .leading, spacing: DS.Spacing.xs) {
            Text(L10n.t("hud.progress.keyProgress"))
                .font(PickyHUDTypography.metaSemibold)
                .foregroundStyle(DS.Colors.textTertiary)
            ForEach(projection.keyItems) { item in
                progressRow(item)
            }
            if projection.hiddenKeyItemCount > 0 {
                Text(L10n.t("hud.progress.moreInDetails", projection.hiddenKeyItemCount))
                    .font(PickyHUDTypography.meta)
                    .foregroundStyle(DS.Colors.textTertiary)
            }
        }
    }

    @ViewBuilder
    private func progressRow(_ item: PickySessionProgressItem) -> some View {
        switch item {
        case let .investigation(count):
            Label(L10n.t("hud.progress.investigation", count), systemImage: "magnifyingglass")
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
                .padding(DS.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(DS.Colors.surface2)
                .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
        case let .entry(entry):
            HStack(spacing: DS.Spacing.sm) {
                Image(systemName: symbol(for: entry))
                    .font(PickyHUDTypography.supportingSemibold)
                    .foregroundStyle(statusColor(for: entry))
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title(for: entry))
                    .font(PickyHUDTypography.supporting)
                    .foregroundStyle(DS.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(statusText(for: entry))
                    .font(PickyHUDTypography.metaSemibold)
                    .foregroundStyle(statusColor(for: entry))
            }
            .padding(DS.Spacing.sm)
            .background(DS.Colors.surface2)
            .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous))
            .accessibilityLabel("\(title(for: entry)), \(statusText(for: entry))")
        }
    }

    private func detailsDisclosure(_ projection: PickySessionProgressProjection) -> some View {
        DisclosureGroup(isExpanded: $showsDetails) {
            LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                ForEach(projection.rawEntries) { entry in
                    PickyToolHistoryEntryView(entry: entry, cwd: session.cwd, context: .embeddedActivity)
                }
            }
            .padding(.top, DS.Spacing.sm)
        } label: {
            Text(showsDetails
                 ? L10n.t("hud.progress.details.hide")
                 : L10n.t("hud.progress.details.show", projection.rawDetailCount))
                .font(PickyHUDTypography.supportingMedium)
                .foregroundStyle(DS.Colors.accentText)
        }
        .disabled(projection.rawDetailCount == 0)
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.xs) {
            Image(systemName: "checkmark.circle")
                .font(PickyHUDTypography.title)
                .foregroundStyle(DS.Colors.textTertiary)
            Text(L10n.t("hud.progress.empty"))
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DS.Spacing.lg)
    }

    private func title(for entry: PickyToolHistoryEntry) -> String {
        switch entry.detail {
        case let .edit(file, _): return L10n.t("hud.progress.entry.edit", displayPath(file))
        case let .write(file, _): return L10n.t("hud.progress.entry.write", displayPath(file))
        case let .bash(command, title, _): return title ?? command ?? L10n.t("hud.progress.entry.command")
        case let .subagent(_, agents, task, _):
            return task ?? agents.first.map { L10n.t("hud.progress.entry.agent", $0) } ?? L10n.t("hud.progress.entry.agentUnknown")
        default: return entry.name
        }
    }

    private func displayPath(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return L10n.t("hud.progress.entry.file") }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    private func symbol(for entry: PickyToolHistoryEntry) -> String {
        if entry.isAgentActivity { return "person.2" }
        switch entry.category {
        case .edit, .write: return "doc"
        case .bash: return "terminal"
        case .read, .other: return "wrench.and.screwdriver"
        }
    }

    private func statusText(for entry: PickyToolHistoryEntry) -> String {
        switch entry.status {
        case .running: L10n.t("hud.progress.status.running")
        case .succeeded: L10n.t("hud.progress.status.succeeded")
        case .failed: L10n.t("hud.progress.status.failed")
        }
    }

    private func statusColor(for entry: PickyToolHistoryEntry) -> Color {
        switch entry.status {
        case .running: DS.Colors.info
        case .succeeded: DS.Colors.successText
        case .failed: DS.Colors.destructiveText
        }
    }

    private func statusColor(for header: PickySessionProgressHeaderPresentation) -> Color {
        switch header.state {
        case .running, .working: DS.Colors.info
        case .waitingForInput: DS.Colors.warningText
        case .failed, .blocked: DS.Colors.destructiveText
        case .completed: DS.Colors.successText
        case .queued, .cancelled: DS.Colors.textSecondary
        }
    }
}
