//
//  CompanionPanelStatusView.swift
//  Picky
//
//  Calm status content for the menu bar panel.
//

import SwiftUI

/// Inner navigation for the Status tab. Mirrors `CompanionPanelSettingsRoute`
/// so the Feedback and Messages pages render as Status sub-pages rather than
/// panel-level overlays. Switching tabs then back preserves the route,
/// matching Settings sub-page behavior.
enum CompanionPanelStatusRoute: Hashable {
    case index
    case feedback
    case messages
}

struct CompanionPanelStatusView: View {
    @ObservedObject var companionManager: CompanionManager
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @EnvironmentObject private var updaterController: PickyUpdaterController
    @Binding var route: CompanionPanelStatusRoute

    /// Cached `ShellCommandInstaller.currentStatus()` so the stale banner can
    /// render without recomputing on every body call. Refreshed on appear and
    /// whenever Settings posts `.pickyShellCommandStatusDidChange` after the
    /// user finishes (un)installing the wrapper.
    @State private var shellCommandStatus: ShellCommandInstaller.InstallStatus = .notInstalled

    var body: some View {
        Group {
            switch route {
            case .index: indexContent
            case .feedback: feedbackContent
            case .messages: messagesContent
            }
        }
        .animation(.easeOut(duration: 0.16), value: route)
        .onAppear { refreshShellCommandStatus() }
        .onReceive(NotificationCenter.default.publisher(for: .pickyShellCommandStatusDidChange)) { _ in
            refreshShellCommandStatus()
        }
    }

    private var indexContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            staleShellCommandBanner
            if companionManager.allPrerequisitesMet {
                readyRow
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                contextSection
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                messagesRow
                Divider()
                    .background(DS.Colors.borderSubtle.opacity(0.4))
                    .padding(.vertical, 14)
                CompanionPanelUpdateSection(
                    settingsViewModel: settingsViewModel,
                    updaterController: updaterController
                )
            } else {
                // Feedback affordance during onboarding lives in the footer
                // bug glyph; the prerequisites surface no longer competes
                // with it for attention here.
                CompanionPanelPrerequisitesCopyView(companionManager: companionManager)
                    .padding(.bottom, 14)
                CompanionPanelPrerequisitesView(companionManager: companionManager)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Feedback sub-page. Mirrors the Settings sub-page layout — back chevron
    /// pointing at the tab name, section header, then the form. Tab bar above
    /// keeps highlighting Status because route navigation never moves the tab.
    private var feedbackContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            backChevron
                .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 9) {
                Text("settings.section.feedback.title")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(DS.Colors.textSecondary)
                    .textCase(.uppercase)
                    .tracking(0.4)
                Text("settings.section.feedback.subtitle")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)

                CompanionPanelFeedbackView(viewModel: settingsViewModel)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Messages sub-page. Hosts the existing main-agent chat view inside the
    /// Status tab so the second tab can be dedicated to Pi extensions. The
    /// back chevron above the chat header lets the user return to the Status
    /// index without leaving the tab.
    private var messagesContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            backChevron
                .padding(.bottom, 8)

            CompanionPanelMessagesView(companionManager: companionManager)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Shared back-chevron used by every Status sub-page. Pops the route
    /// back to `.index` with the same spring animation Settings uses.
    private var backChevron: some View {
        Button(action: popToIndex) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left")
                    .pickyFont(size: 11, weight: .semibold)
                Text("tab.status")
                    .pickyFont(size: 11.5, weight: .medium)
            }
            .foregroundColor(DS.Colors.textTertiary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func popToIndex() {
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            route = .index
        }
    }

    /// Non-blocking inline notice that appears only when the installed picky
    /// wrapper points at a different Picky.app than the one currently running.
    /// The user can ignore it; tapping "Reinstall" opens the same NSAlert as
    /// the Settings button so they can re-point or remove the wrapper.
    @ViewBuilder
    private var staleShellCommandBanner: some View {
        if case .installedStale = shellCommandStatus {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(DS.Colors.warningText)
                    .frame(width: 14, alignment: .center)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("status.shellCommand.stale.title")
                        .pickyFont(size: 12, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("status.shellCommand.stale.subtitle")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("status.shellCommand.stale.reinstall") {
                    ShellCommandMenuController.shared.showInstallerAlert()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                    .fill(DS.Colors.warning.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.warning.opacity(0.45), lineWidth: 0.6)
                    )
            )
            .padding(.bottom, 14)
        }
    }

    private func refreshShellCommandStatus() {
        shellCommandStatus = ShellCommandInstaller.currentStatus()
    }

    /// Chevron entry that drills into the Status tab's messages sub-page.
    /// Mirrors the Settings index row style (title + subtitle + chevron).
    /// Replaces the legacy second top-level tab — chat with Picky now lives
    /// inside Status so the second tab can host curated extensions.
    private var messagesRow: some View {
        Button(action: { withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) { route = .messages } }) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("status.messages.title")
                        .pickyFont(size: 12.5, weight: .semibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text("status.messages.subtitle")
                        .pickyFont(size: 10.5, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .pickyFont(size: 10, weight: .semibold)
                    .foregroundColor(DS.Colors.textTertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Ready when you are" / "Listening..." line. Inline mic glyph + title/subtitle
    /// stack, no card chrome. Shortcut hint moves into the subtitle text so we don't
    /// need a second row of pills (Control+Option / Local-first) crowding the view.
    private var readyRow: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: "mic.fill")
                .pickyFont(size: 14, weight: .semibold)
                .foregroundColor(DS.Colors.successText)
                .frame(width: 18, alignment: .center)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                Text(primaryStatusTitle)
                    .pickyFont(size: 13.5, weight: .semibold)
                    .foregroundColor(DS.Colors.textPrimary)
                Text(primaryStatusSubtitle)
                    .pickyFont(size: 11.5, weight: .medium)
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
                .pickyFont(size: 11, weight: .semibold)
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
                .pickyFont(size: 10.5, weight: .medium)
                .foregroundColor(DS.Colors.textTertiary)
                .frame(width: 14, alignment: .center)
            Text(text)
                .pickyFont(size: 11.5, weight: .medium)
                .foregroundColor(DS.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Auto-update controls inside the Status tab. Renders the current build,
/// channel name, automatic-checks toggle, and a manual "Check Now" button in
/// a compact two-row layout: the build identity is the heading-adjacent
/// inline line, and a single button row carries Check Now + last-checked.
/// Alpha builds (sideloaded testers) see a one-line notice instead of the
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
        VStack(alignment: .leading, spacing: 6) {
            Text("status.updates.heading")
                .pickyFont(size: 11, weight: .semibold)
                .foregroundColor(DS.Colors.textSecondary)
                .textCase(.uppercase)
                .tracking(0.4)

            HStack(alignment: .firstTextBaseline, spacing: 9) {
                Image(systemName: "app.badge")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 14, alignment: .center)
                Text(L10n.t("status.updates.buildLine", buildLabel, channelLabel))
                    .pickyFont(size: 11.5, weight: .medium)
                    .foregroundColor(DS.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if updaterController.isAvailable {
                // Toggle + manual check share one row. The auto-check label
                // sits on the right of the switch so the row reads as
                // "[Check Now]  [✓ auto]" instead of stacking three lines.
                HStack(spacing: 10) {
                    Button("status.updates.checkNow") {
                        updaterController.checkForUpdates()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!updaterController.canCheckForUpdates)

                    Toggle("status.updates.autoCheck", isOn: automaticChecksBinding)
                        .toggleStyle(.switch)
                        .tint(DS.Colors.accent)
                        .pickyFont(size: 11, weight: .medium)
                        .foregroundColor(DS.Colors.textSecondary)
                        .controlSize(.mini)
                        .fixedSize()

                    Spacer(minLength: 0)
                }
                .padding(.top, 2)

                if let last = updaterController.lastUpdateCheckDate {
                    Text(L10n.t("status.updates.lastChecked", Self.lastCheckFormatter.string(from: last)))
                        .pickyFont(size: 10, weight: .medium)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            } else {
                Text("status.updates.alphaNotice")
                    .pickyFont(size: 10.5, weight: .medium)
                    .foregroundColor(DS.Colors.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

