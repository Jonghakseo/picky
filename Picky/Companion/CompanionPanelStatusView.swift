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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if companionManager.allPermissionsGranted {
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
            } else {
                CompanionPanelPermissionsCopyView(companionManager: companionManager)
                    .padding(.bottom, 14)
                CompanionPanelPermissionsView(companionManager: companionManager)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            Text("What Picky captures")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            VStack(alignment: .leading, spacing: 7) {
                contextLine(icon: "display", text: "Screenshots only when you use the hotkey")
                contextLine(icon: "text.cursor", text: "Selected text and browser context when available")
                contextLine(icon: "terminal", text: "Default workspace from Settings")
            }
        }
    }

    private var primaryStatusTitle: String {
        switch companionManager.voiceState {
        case .idle:
            return "Ready when you are"
        case .listening:
            return "Listening…"
        case .processing:
            return "Preparing context…"
        case .responding:
            return "Answering…"
        }
    }

    private var primaryStatusSubtitle: String {
        switch companionManager.voiceState {
        case .idle:
            return "Hold the shortcut, speak naturally, then release."
        case .listening:
            return "Keep holding Control+Option while you speak."
        case .processing:
            return "Picky is collecting just enough context for Pi."
        case .responding:
            return "You can interrupt by starting a new voice input."
        }
    }

    private func contextLine(icon: String, text: String) -> some View {
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
            Text("Updates")
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "app.badge")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text("\(buildLabel) · \(channelLabel) build")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updaterController.isAvailable {
                Picker("Channel", selection: channelBinding) {
                    ForEach(PickyUpdateChannel.allCases) { channel in
                        Text(channel.displayName).tag(channel)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Toggle("Check automatically every 4 hours", isOn: automaticChecksBinding)
                    .toggleStyle(.switch)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundColor(DS.Colors.textSecondary)

                HStack(spacing: 8) {
                    Button("Check Now") {
                        updaterController.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updaterController.canCheckForUpdates)

                    if let last = updaterController.lastUpdateCheckDate {
                        Text("Last checked \(Self.lastCheckFormatter.string(from: last))")
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundColor(DS.Colors.textTertiary)
                    }
                }
            } else {
                Text("Auto-update is disabled for alpha builds. Reinstall the latest DMG to upgrade.")
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

