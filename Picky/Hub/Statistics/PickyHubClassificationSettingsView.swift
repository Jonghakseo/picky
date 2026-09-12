//
//  PickyHubClassificationSettingsView.swift
//  Picky
//

import SwiftUI

/// Privacy control for the optional model-backed work-category classifier.
/// The value shown here always comes from a daemon-confirmed snapshot.
struct PickyHubClassificationSettingsView: View {
    @ObservedObject var statisticsStore: PickyHubStatisticsStore

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
                VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                    Text("hub.settings.classification.title")
                        .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    Text("hub.settings.classification.detail")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .pickyHubSelectableText()
                }
                Spacer(minLength: PickyHubTheme.Spacing.field)
                if hasConfirmedSnapshot {
                    Toggle("hub.settings.classification.title", isOn: toggleBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .tint(PickyHubTheme.Colors.action)
                    .disabled(!hasConfirmedSnapshot || statisticsStore.isUpdatingClassification || statisticsStore.isResetting)
                    .accessibilityHint(Text("hub.settings.classification.accessibilityHint"))
                } else {
                    Text("hub.settings.classification.unknown")
                        .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                        .foregroundColor(PickyHubTheme.Colors.textSecondary)
                        .pickyHubSelectableText()
                }
            }

            Divider().overlay(PickyHubTheme.Colors.borderSoft)

            Text("hub.settings.classification.disclosure")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()

            if statisticsStore.isUpdatingClassification {
                PickyHubInlineStatus(tone: .neutral, message: L10n.t("hub.settings.classification.saving"))
            }
            if case .failed(let error) = statisticsStore.state {
                PickyHubInlineStatus(tone: .error, message: error, actionTitle: "hub.common.retry", action: { statisticsStore.refresh() })
            } else if let error = statisticsStore.classificationUpdateError {
                PickyHubInlineStatus(tone: .error, message: error)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
        .pickyHubCard(radius: PickyHubTheme.Radius.card)
        .onAppear { statisticsStore.refreshIfNeeded() }
    }

    private var hasConfirmedSnapshot: Bool {
        if case .loaded = statisticsStore.state { return true }
        return false
    }

    private var toggleBinding: Binding<Bool> {
        Binding(
            get: { statisticsStore.classificationEnabled },
            set: { enabled in
                Task { await statisticsStore.setClassificationEnabled(enabled) }
            }
        )
    }
}
