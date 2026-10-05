//
//  PickyHubRemoteAccessSection.swift
//  Picky
//
//  The "원격 접속" settings group. Everything here reads from
//  `PickyRemoteAccessController`; the only state this file owns is the text the
//  user is still typing and the speech authorization it just asked for.
//

import AppKit
import Speech
import SwiftUI

enum PickyHubRemoteLayout {
    /// Matches the native popup width the rest of the settings page uses.
    static let menuWidth: CGFloat = 180
    static let qrSide: CGFloat = 176
    static let onlineDotSide: CGFloat = 7
}

struct PickyHubRemoteAccessSection: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    let controller: PickyRemoteAccessController?
    let modalHost: PickyHubModalHost

    var body: some View {
        if let controller {
            PickyHubRemoteAccessControls(
                settingsViewModel: settingsViewModel,
                controller: controller,
                modalHost: modalHost
            )
        } else {
            PickyHubSettingsNotice(text: "settings.remote.unavailable")
        }
    }
}

private struct PickyHubRemoteAccessControls: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @ObservedObject var controller: PickyRemoteAccessController
    let modalHost: PickyHubModalHost
    @State private var speechAuthorization = SFSpeechRecognizer.authorizationStatus()
    @State private var isRequestingSpeech = false

    private var remote: PickyRemoteAccessSettings { settingsViewModel.settings.remoteAccess }

    private var status: PickyHubRemoteAccessStatus {
        PickyHubRemoteAccessStatus.resolve(
            isEnabled: remote.enabled,
            gatewayState: controller.gatewayState,
            entranceURL: controller.entranceURL
        )
    }

    private var speechPermission: PickyHubRemoteSpeechPermission {
        PickyHubRemoteSpeechPermission.resolve(
            readiness: controller.dictation,
            authorization: speechAuthorization
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubSettingsList {
                toggleRow
                keepAwakeRow
                if speechPermission != .hidden {
                    speechRow
                }
            }
            statusLine
            PickyHubSettingsNotice(text: "settings.remote.notice")
            entranceSection
            PickyHubRemoteDevicesSection(controller: controller, modalHost: modalHost)
        }
        .onAppear { speechAuthorization = SFSpeechRecognizer.authorizationStatus() }
    }

    // MARK: - Switch and status

    private var toggleRow: some View {
        PickyHubSettingsRow(title: "settings.remote.toggle", detail: "settings.remote.toggle.detail") {
            Toggle("settings.remote.toggle", isOn: Binding(
                get: { remote.enabled },
                set: { enabled in
                    settingsViewModel.settings.remoteAccess.enabled = enabled
                    settingsViewModel.save()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(PickyHubTheme.Colors.action)
        }
    }

    private var keepAwakeRow: some View {
        PickyHubSettingsRow(title: "settings.remote.keepAwake", detail: "settings.remote.keepAwake.detail") {
            Toggle("settings.remote.keepAwake", isOn: Binding(
                get: { remote.keepAwake },
                set: { keepAwake in
                    settingsViewModel.settings.remoteAccess.keepAwake = keepAwake
                    settingsViewModel.save()
                }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .tint(PickyHubTheme.Colors.action)
        }
    }

    private var speechRow: some View {
        PickyHubSettingsRow(
            title: "settings.remote.speech",
            detail: speechPermission == .askOnThisMac
                ? "settings.remote.speech.detail"
                : "settings.remote.speech.blocked"
        ) {
            if speechPermission == .askOnThisMac {
                PickyHubButton(
                    title: "settings.remote.speech.request",
                    role: .secondary,
                    systemImage: "mic",
                    isBusy: isRequestingSpeech,
                    isEnabled: !isRequestingSpeech,
                    action: requestSpeechAuthorization
                )
            } else {
                PickyHubButton(
                    title: "settings.remote.speech.openSettings",
                    role: .secondary,
                    systemImage: "gear",
                    action: openSpeechPrivacySettings
                )
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        let current = status
        if let retryTitle = current.retryTitle {
            PickyHubInlineStatus(
                tone: current.tone,
                message: current.message,
                actionTitle: retryTitle,
                action: { controller.restartGateway() }
            )
        } else {
            PickyHubInlineStatus(tone: current.tone, message: current.message)
        }
    }

    // MARK: - Entrance

    private var entranceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "settings.remote.entrance")
            PickyHubSettingsList {
                PickyHubSettingsRow(title: "settings.remote.entrance", detail: "settings.remote.entrance.detail") {
                    PickyHubMenuPicker(
                        title: L10n.t("settings.remote.entrance"),
                        selection: Binding(
                            get: { remote.entrance },
                            set: { entrance in
                                settingsViewModel.settings.remoteAccess.entrance = entrance
                                settingsViewModel.save()
                            }
                        ),
                        options: PickyRemoteEntrance.allCases.map {
                            PickyNativeMenuOption(value: $0, title: L10n.t($0.titleKey))
                        }
                    )
                    .frame(width: PickyHubRemoteLayout.menuWidth)
                }
                switch remote.entrance {
                case .tailscale:
                    PickyHubRemoteTailscaleRows(controller: controller)
                case .cloudflare:
                    PickyHubRemoteCloudflareRow(settingsViewModel: settingsViewModel)
                case .localOnly:
                    PickyHubSettingsRow(
                        title: "settings.remote.localOnly.address",
                        detail: "settings.remote.localOnly.detail"
                    ) {
                        PickyHubRemoteAddressLabel(address: controller.localURL)
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func requestSpeechAuthorization() {
        guard !isRequestingSpeech else { return }
        isRequestingSpeech = true
        Task {
            let granted = try? await PickySystemPermissionGateway.shared.requestSpeechRecognitionAuthorization()
            isRequestingSpeech = false
            speechAuthorization = granted ?? SFSpeechRecognizer.authorizationStatus()
            controller.refreshDictation()
        }
    }

    private func openSpeechPrivacySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Entrance rows

private struct PickyHubRemoteTailscaleRows: View {
    @ObservedObject var controller: PickyRemoteAccessController

    private var magicDNSName: String? {
        guard let name = controller.tailscaleStatus?.magicDNSName, !name.isEmpty else { return nil }
        return name
    }

    var body: some View {
        if controller.isTailscaleInstalled {
            PickyHubSettingsRow(title: "settings.remote.tailscale.name", detail: "settings.remote.tailscale.name.detail") {
                if let magicDNSName {
                    PickyHubRemoteAddressLabel(address: "https://\(magicDNSName)")
                } else {
                    PickyHubButton(
                        title: "settings.remote.tailscale.recheck",
                        role: .secondary,
                        systemImage: "arrow.clockwise",
                        action: { Task { await controller.refreshTailscaleStatus() } }
                    )
                }
            }
            PickyHubSettingsRow(
                title: "settings.remote.tailscale.serve",
                detail: LocalizedStringKey(
                    controller.tailscaleStatus?.isServing == true
                        ? "settings.remote.tailscale.serving"
                        : "settings.remote.tailscale.notServing"
                )
            ) {
                PickyHubButton(
                    title: controller.tailscaleStatus?.isServing == true
                        ? "settings.remote.tailscale.serve.off"
                        : "settings.remote.tailscale.serve.on",
                    role: .secondary,
                    isBusy: controller.isTailscaleBusy,
                    isEnabled: !controller.isTailscaleBusy,
                    action: {
                        let enable = controller.tailscaleStatus?.isServing != true
                        Task { await controller.setTailscaleServe(enabled: enable) }
                    }
                )
            }
        } else {
            PickyHubSettingsRow(
                title: "settings.remote.tailscale.name",
                detail: "settings.remote.tailscale.notInstalled.detail"
            ) {
                PickyHubButton(
                    title: "settings.remote.tailscale.recheck",
                    role: .secondary,
                    systemImage: "arrow.clockwise",
                    action: { Task { await controller.refreshTailscaleStatus() } }
                )
            }
        }
        if let error = controller.tailscaleError {
            // The CLI prints the admin link that enables HTTPS certificates, so
            // the raw message is more useful than a rewritten one.
            PickyHubRemoteRowMessage(tone: .error, message: error)
        }
    }
}

private struct PickyHubRemoteCloudflareRow: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @State private var draft: String = ""
    @State private var hasLoadedDraft = false
    @FocusState private var isFocused: Bool

    private var saved: String { settingsViewModel.settings.remoteAccess.cloudflareURL }

    private var normalizedDraft: String? {
        PickyRemoteAccessSettings.normalizedPublicURL(draft)
    }

    var body: some View {
        PickyHubSettingsRow(
            title: "settings.remote.cloudflare.url",
            detail: "settings.remote.cloudflare.url.detail"
        ) {
            TextField(L10n.t("settings.remote.cloudflare.url.placeholder"), text: $draft)
                .textFieldStyle(.roundedBorder)
                .focused($isFocused)
                .onSubmit(commit)
                .onChange(of: isFocused) { _, focused in
                    if !focused { commit() }
                }
        }
        .onAppear {
            guard !hasLoadedDraft else { return }
            hasLoadedDraft = true
            draft = saved
        }
        if !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, normalizedDraft == nil {
            PickyHubRemoteRowMessage(tone: .error, message: L10n.t("settings.remote.cloudflare.url.invalid"))
        } else if let normalizedDraft, normalizedDraft == saved {
            PickyHubRemoteRowMessage(tone: .success, message: L10n.t("settings.remote.cloudflare.url.saved", normalizedDraft))
        }
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            draft = ""
            guard saved != "" else { return }
            settingsViewModel.settings.remoteAccess.cloudflareURL = ""
            settingsViewModel.save()
            return
        }
        // An address Picky cannot normalize is kept in the field so the user can
        // fix it; persisting it would only publish an entrance that never works.
        guard let normalized = normalizedDraft else { return }
        draft = normalized
        guard normalized != saved else { return }
        settingsViewModel.settings.remoteAccess.cloudflareURL = normalized
        settingsViewModel.save()
    }
}

// MARK: - Small shared pieces

/// Selectable monospaced address with a copy affordance in the context menu.
struct PickyHubRemoteAddressLabel: View {
    let address: String

    var body: some View {
        Text(address)
            .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
            .monospaced()
            .foregroundColor(PickyHubTheme.Colors.textSecondary)
            .lineLimit(2)
            .truncationMode(.middle)
            .pickyHubSelectableText()
            .frame(maxWidth: .infinity, alignment: .trailing)
            .help(Text(address))
            .accessibilityLabel(Text(address))
    }
}

/// A message that belongs to the row above it, inset to the same gutter.
struct PickyHubRemoteRowMessage: View {
    let tone: PickyHubInlineStatusTone
    let message: String

    var body: some View {
        PickyHubInlineStatus(tone: tone, message: message)
            .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
            .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
            .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
    }
}
