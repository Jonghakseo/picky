//
//  PickySessionActivityView.swift
//  Picky
//
//  Compact, session-scoped tool activity for the HUD utility panel.
//

import SwiftUI

struct PickySessionActivityView: View {
    let session: PickySessionListViewModel.SessionCard
    @State private var selectedFilter: PickyToolHistoryActivityFilter = .all

    private var entries: [PickyToolHistoryEntry] {
        PickyToolHistoryRenderer.entries(from: session.tools).reversed()
    }

    private var filteredEntries: [PickyToolHistoryEntry] {
        PickyToolHistoryFilterPolicy.activityEntries(from: entries, filter: selectedFilter)
    }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            Divider().overlay(DS.Colors.borderSubtle)
            if filteredEntries.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Spacing.sm) {
                        ForEach(filteredEntries) { entry in
                            PickyToolHistoryEntryView(
                                entry: entry,
                                cwd: session.cwd,
                                context: .embeddedActivity
                            )
                        }
                    }
                    .padding(DS.Spacing.sm)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.activity.accessibilityLabel"))
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.xs) {
                ForEach(PickyToolHistoryActivityFilter.allCases) { filter in
                    filterButton(filter)
                }
            }
            .padding(.horizontal, DS.Spacing.sm)
            .padding(.vertical, DS.Spacing.xs)
        }
    }

    private func filterButton(_ filter: PickyToolHistoryActivityFilter) -> some View {
        let isSelected = selectedFilter == filter
        return Button {
            selectedFilter = filter
        } label: {
            Text(filterTitle(filter))
                .font(PickyHUDTypography.metaSemibold)
                .foregroundStyle(isSelected ? DS.Colors.accentText : DS.Colors.textSecondary)
                .padding(.horizontal, DS.Spacing.sm)
                .padding(.vertical, 3)
                .background(Capsule().fill(isSelected ? DS.Colors.accentSubtle : Color.clear))
        }
        .buttonStyle(PickyHUDCompactChipButtonStyle())
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(filterTitle(filter))
    }

    private var emptyState: some View {
        VStack(spacing: DS.Spacing.sm) {
            Image(systemName: "wrench.and.screwdriver")
                .font(PickyHUDTypography.title)
                .foregroundStyle(DS.Colors.textTertiary)
            Text(L10n.t("hud.activity.empty"))
                .font(PickyHUDTypography.supporting)
                .foregroundStyle(DS.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.lg)
    }

    private func filterTitle(_ filter: PickyToolHistoryActivityFilter) -> String {
        switch filter {
        case .all: L10n.t("hud.activity.filter.all")
        case .files: L10n.t("hud.activity.filter.files")
        case .commands: L10n.t("hud.activity.filter.commands")
        case .agents: L10n.t("hud.activity.filter.agents")
        case .failures: L10n.t("hud.activity.filter.failures")
        }
    }
}
