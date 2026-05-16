//
//  CompanionPanelStatusView.swift
//  Picky
//
//  Calm status content for the menu bar panel.
//

import SwiftUI

struct CompanionPanelStatusView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @EnvironmentObject private var updaterController: PickyUpdaterController
    var onShowFeedback: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if companionManager.allPrerequisitesMet {
                readyRow
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                contextSection
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                CompanionPanelUpdateSection(
                    settingsViewModel: settingsViewModel,
                    updaterController: updaterController
                )
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                CompanionPanelExtensionsSection()
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                feedbackRow
            } else {
                CompanionPanelPrerequisitesCopyView(companionManager: companionManager)
                    .padding(.bottom, 14)
                CompanionPanelPrerequisitesView(companionManager: companionManager)
                // Keep the feedback affordance reachable during setup/onboarding.
                // Users hitting permission edge cases or a confusing Pi install
                // step are exactly the people we want to hear from, and the tab
                // bar is hidden in this state so there's no alternate route.
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                feedbackRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Chevron entry that deep-links into the Settings tab's feedback page.
    /// Mirrors the Settings index row style (title + subtitle + chevron).
    private var feedbackRow: some View {
        Button(action: onShowFeedback) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("status.feedback.title")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("status.feedback.subtitle")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }

    /// "Ready when you are" / "Listening..." line. Inline mic glyph + title/subtitle
    /// stack, no card chrome. Shortcut hint moves into the subtitle text so we don't
    /// need a second row of pills (Control+Option / Local-first) crowding the view.
    private var readyRow: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(DS.Colors.success)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryStatusTitle)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                Text(primaryStatusSubtitle)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
    }

    /// "What Picky captures" — section label + bulleted list, no card. Each line uses
    /// a single SF Symbol glyph at the same width so labels align cleanly.
    private var contextSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("status.capturedHeading")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 7) {
                contextLine(icon: "display", text: "status.captures.screenshots")
                contextLine(icon: "text.cursor", text: "status.captures.text")
                contextLine(icon: "terminal", text: "status.captures.workspace")
            }
        }
    }

    private var primaryStatusTitle: LocalizedStringKey {
        switch companionManager.voiceState {
        case .idle:
            return "status.voice.idle.title"
        case .listening:
            return "status.voice.listening.title"
        case .processing:
            return "status.voice.processing.title"
        case .responding:
            return "status.voice.responding.title"
        }
    }

    private var primaryStatusSubtitle: LocalizedStringKey {
        switch companionManager.voiceState {
        case .idle:
            return "status.voice.idle.subtitle"
        case .listening:
            return "status.voice.listening.subtitle"
        case .processing:
            return "status.voice.processing.subtitle"
        case .responding:
            return "status.voice.responding.subtitle"
        }
    }

    private func contextLine(icon: String, text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Auto-update controls inside the Status tab. Renders the current build,
/// channel picker, automatic-checks toggle, and a manual "Check Now" button.
/// Alpha builds (sideloaded testers) see a static notice instead of the
/// controls because Sparkle is not running. See docs/auto-update.md.
private struct CompanionPanelUpdateSection: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @ObservedObject var updaterController: PickyUpdaterController

    private var buildLabel: String {
        let version = AppBundleConfiguration.stringValue(forKey: "CFBundleShortVersionString") ?? "dev"
        let build = AppBundleConfiguration.stringValue(forKey: "CFBundleVersion") ?? "0"
        return "\(version) (\(build))"
    }

    private var channelLabel: String {
        let raw = AppBundleConfiguration.releaseChannel
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    private static let lastCheckFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("status.updates.heading")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "app.badge")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text(L10n.t("status.updates.buildLine", buildLabel, channelLabel))
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updaterController.isAvailable {
                Picker("status.updates.channelLabel", selection: channelBinding) {
                    ForEach(PickyUpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Toggle("status.updates.autoCheck", isOn: automaticChecksBinding)
                    .toggleStyle(.switch)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 8) {
                    Button("status.updates.checkNow") {
                        updaterController.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updaterController.canCheckForUpdates)

                    if let last = updaterController.lastUpdateCheckDate {
                        Text(L10n.t("status.updates.lastChecked", Self.lastCheckFormatter.string(from: last)))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            } else {
                Text("status.updates.alphaNotice")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var channelBinding: Binding<PickyUpdateChannel> {
        Binding(
            get: { settingsViewModel.settings.updateChannel },
            set: { newValue in
                settingsViewModel.settings.updateChannel = newValue
                _ = settingsViewModel.save()
            }
        )
    }

    private var automaticChecksBinding: Binding<Bool> {
        Binding(
            get: { settingsViewModel.settings.updatesAutomaticChecksEnabled },
            set: { newValue in
                settingsViewModel.settings.updatesAutomaticChecksEnabled = newValue
                _ = settingsViewModel.save()
            }
        )
    }
}

