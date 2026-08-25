//
//  PickySessionChangesView.swift
//  Picky
//
//  Inline git-diff browser for the Pickle utility panel.
//

import SwiftUI

struct PickySessionChangesView: View {
    let sessionID: String
    /// Commands are deliberately unobserved; only this session's diff store
    /// redraws when an on-demand diff response arrives.
    let viewModel: any PickySessionCommands
    @ObservedObject private var diffStore: PickySessionDiffStore
    let isVisible: Bool

    @State private var expandedFilePaths = Set<String>()

    init(sessionID: String, viewModel: any PickySessionCommands, isVisible: Bool) {
        self.sessionID = sessionID
        self.viewModel = viewModel
        _diffStore = ObservedObject(wrappedValue: viewModel.sessionDiffStore(for: sessionID))
        self.isVisible = isVisible
    }

    private var state: PickySessionDiffState { diffStore.state }

    var body: some View {
        VStack(spacing: 0) {
            viewSwitcher
            Divider()
                .overlay(DS.Colors.borderSubtle)
            content
        }
        .onAppear { updateVisibility() }
        .onChange(of: isVisible) { _ in updateVisibility() }
        .onDisappear { viewModel.setSessionDiffVisible(false, sessionID: sessionID) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.changes.accessibilityLabel"))
    }

    private var viewSwitcher: some View {
        HStack(spacing: DS.Spacing.xs) {
            diffViewButton(.unstaged)
            diffViewButton(.staged)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.sm)
        .padding(.vertical, DS.Spacing.xs)
    }

    private func diffViewButton(_ view: PickySessionDiffView) -> some View {
        let isSelected = state.view == view
        return Button {
            viewModel.selectSessionDiffView(view, sessionID: sessionID)
        } label: {
            Text(L10n.t(view == .unstaged ? "hud.changes.view.unstaged" : "hud.changes.view.staged"))
                .font(PickyHUDTypography.supportingMedium)
                .foregroundColor(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .background(
                    Capsule(style: .continuous)
                        .fill(isSelected ? DS.Colors.accentSubtle : .clear)
                )
        }
        .buttonStyle(.plain)
        .hoverAffordance()
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var content: some View {
        if state.isLoading {
            ProgressView(L10n.t("hud.changes.loading"))
                .controlSize(.small)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(DS.Colors.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !state.isGitRepo {
            emptyState("hud.changes.notGitRepository")
        } else if state.files.isEmpty {
            if let errorMessage = state.errorMessage {
                errorState(errorMessage)
            } else {
                emptyState("hud.changes.empty")
            }
        } else {
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if let errorMessage = state.errorMessage {
                        errorLine(errorMessage)
                    }
                    ForEach(state.files) { file in
                        PickySessionDiffFileRow(
                            file: file,
                            isExpanded: expandedFilePaths.contains(file.id),
                            onToggle: { toggleExpansion(for: file.id) }
                        )
                        Divider()
                            .overlay(DS.Colors.borderSubtle.opacity(0.65))
                    }
                    if state.filesTruncated {
                        Text(L10n.t("hud.changes.filesTruncated"))
                            .font(PickyHUDTypography.meta)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(DS.Spacing.sm)
                    }
                }
                .padding(.vertical, DS.Spacing.xs)
            }
        }
    }

    private func emptyState(_ key: String) -> some View {
        Text(L10n.t(key))
            .font(PickyHUDTypography.supporting)
            .foregroundColor(DS.Colors.textSecondary)
            .multilineTextAlignment(.center)
            .padding(DS.Spacing.lg)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: DS.Spacing.sm) {
            errorLine(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.lg)
    }

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle")
            .font(PickyHUDTypography.status)
            .foregroundColor(DS.Colors.destructiveText)
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityLabel(L10n.t("hud.changes.error", message))
    }

    private func toggleExpansion(for path: String) {
        if expandedFilePaths.contains(path) {
            expandedFilePaths.remove(path)
        } else {
            expandedFilePaths.insert(path)
        }
    }

    private func updateVisibility() {
        viewModel.setSessionDiffVisible(isVisible, sessionID: sessionID)
    }
}

private struct PickySessionDiffFileRow: View {
    let file: PickySessionDiffFile
    let isExpanded: Bool
    let onToggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: DS.Spacing.sm) {
                    Text(PickySessionDiffPresentation.statusLetter(for: file.status))
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundColor(statusColor)
                        .frame(width: 12, alignment: .leading)

                    Text(file.path)
                        .font(PickyHUDTypography.statusMonospacedMedium)
                        .foregroundColor(DS.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Spacer(minLength: 0)

                    diffCount("+\(file.additions)", color: DS.Colors.successText)
                    diffCount("−\(file.deletions)", color: DS.Colors.destructiveText)

                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .pickyFont(size: 8, weight: .semibold)
                        .foregroundColor(DS.Colors.textTertiary)
                        .frame(width: 10)
                }
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, DS.Spacing.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .hoverAffordance()
            .accessibilityLabel(file.path)
            .accessibilityValue(L10n.t("hud.changes.fileSummary", PickySessionDiffPresentation.statusLetter(for: file.status), file.additions, file.deletions))
            .accessibilityHint(L10n.t(isExpanded ? "hud.changes.collapseDiff" : "hud.changes.expandDiff"))

            if isExpanded {
                PickySessionDiffExpandedLinesView(file: file)
                    .transition(.opacity)
            }
        }
    }

    private var statusColor: Color {
        switch PickySessionDiffPresentation.statusTone(for: file.status) {
        case .added: DS.Colors.successText
        case .modified: DS.Colors.warningText
        case .deleted: DS.Colors.destructiveText
        case .renamed: DS.Colors.info
        case .untracked: DS.Colors.info
        }
    }

    private func diffCount(_ text: String, color: Color) -> some View {
        Text(text)
            .font(PickyHUDTypography.metaMonospacedMedium)
            .foregroundColor(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}

private struct PickySessionDiffExpandedLinesView: View {
    let file: PickySessionDiffFile

    private var diff: String { file.diff }

    @State private var lines: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if lines.isEmpty, !diff.isEmpty {
                ProgressView()
                    .controlSize(.mini)
                    .frame(maxWidth: .infinity)
                    .padding(DS.Spacing.sm)
            } else {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.isEmpty ? " " : line)
                            .font(PickyHUDTypography.minimumMonospaced)
                            .foregroundColor(lineColor(for: line))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, DS.Spacing.sm)
                            .padding(.vertical, 1)
                            .background(lineBackground(for: line))
                    }
                }
                if PickySessionDiffPresentation.shouldShowTruncationFootnote(for: file) {
                    Text(L10n.t("hud.changes.diffTruncated"))
                        .font(PickyHUDTypography.meta)
                        .foregroundColor(DS.Colors.textSecondary)
                        .padding(DS.Spacing.sm)
                }
            }
        }
        .padding(.vertical, DS.Spacing.xs)
        .background(DS.Colors.surface2)
        .task(id: diff) {
            lines = PickySessionDiffPresentation.renderedLines(for: diff)
        }
    }

    private func lineColor(for line: String) -> Color {
        switch PickySessionDiffPresentation.lineKind(for: line) {
        case .addition: DS.Colors.successText
        case .deletion: DS.Colors.destructiveText
        case .hunk: DS.Colors.textSecondary
        case .context: DS.Colors.textPrimary
        }
    }

    private func lineBackground(for line: String) -> Color {
        switch PickySessionDiffPresentation.lineKind(for: line) {
        case .addition: DS.Colors.success.opacity(0.12)
        case .deletion: DS.Colors.destructive.opacity(0.12)
        case .hunk, .context: .clear
        }
    }
}
