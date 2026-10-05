//
//  PickyHubRemoteAccessSection.swift
//  Picky
//
//  The body of the "원격 접속" hub page (`PickyHubRemotePage`). Everything here reads from
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
            entranceURL: controller.entranceURL,
            isEntranceAddressPending: controller.isEntranceAddressPending,
            isLocalOnly: remote.entrance == .localOnly
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
            // One web server, two ways in: this Mac's browser is always there,
            // and remote access only chooses the path a phone takes.
            thisMacSection
                .disabled(!remote.enabled)
                .opacity(remote.enabled ? 1 : 0.45)
            entranceSection
            PickyHubRemoteDevicesSection(controller: controller, modalHost: modalHost)
                .disabled(!remote.enabled)
                .opacity(remote.enabled ? 1 : 0.45)
            PickyHubSettingsNotice(text: "settings.remote.notice")
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

    // MARK: - This Mac

    private var thisMacSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "settings.remote.thisMac")
            PickyHubSettingsList {
                PickyHubSettingsRow(title: "settings.remote.openBrowser", detail: "settings.remote.openBrowser.detail") {
                    PickyHubButton(
                        title: "settings.remote.openBrowser",
                        role: .primary,
                        systemImage: "safari",
                        isBusy: controller.isOpeningBrowser,
                        isEnabled: controller.isRunning && controller.isHubConnected && !controller.isOpeningBrowser,
                        action: { controller.openInBrowser() }
                    )
                }
                PickyHubSettingsRow(title: "settings.remote.localOnly.address", detail: "settings.remote.localOnly.detail") {
                    PickyHubRemoteAddressLabel(address: controller.localURL)
                }
            }
        }
    }

    // MARK: - Remote access (the phone's path)

    private var entranceSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "settings.remote.remoteSection")
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
                        // "Off" first: remote access is the opt-in, this Mac is the default.
                        options: [PickyRemoteEntrance.localOnly, .tailscale, .cloudflare].map {
                            PickyNativeMenuOption(value: $0, title: L10n.t($0.titleKey))
                        }
                    )
                    .frame(width: PickyHubRemoteLayout.menuWidth)
                }
                switch remote.entrance {
                case .tailscale:
                    PickyHubRemoteTailscaleRows(controller: controller)
                case .cloudflare:
                    PickyHubRemoteCloudflareRows(settingsViewModel: settingsViewModel, controller: controller)
                case .localOnly:
                    // The address lives under "This Mac"; nothing else to set up.
                    EmptyView()
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

/// The address source picker plus the rows of whichever source is chosen.
private struct PickyHubRemoteCloudflareRows: View {
    @ObservedObject var settingsViewModel: PickySettingsViewModel
    @ObservedObject var controller: PickyRemoteAccessController

    private var mode: PickyRemoteCloudflareMode { settingsViewModel.settings.remoteAccess.cloudflareMode }

    var body: some View {
        PickyHubSettingsRow(
            title: "settings.remote.cloudflare.mode",
            detail: LocalizedStringKey(
                mode == .quick
                    ? "settings.remote.cloudflare.mode.quick.detail"
                    : "settings.remote.cloudflare.mode.custom.detail"
            )
        ) {
            PickyHubMenuPicker(
                title: L10n.t("settings.remote.cloudflare.mode"),
                selection: Binding(
                    get: { mode },
                    set: { next in
                        settingsViewModel.settings.remoteAccess.cloudflareMode = next
                        settingsViewModel.save()
                    }
                ),
                options: PickyRemoteCloudflareMode.allCases.map {
                    PickyNativeMenuOption(value: $0, title: L10n.t($0.titleKey))
                }
            )
            .frame(width: PickyHubRemoteLayout.menuWidth)
        }
        switch mode {
        case .quick:
            PickyHubRemoteQuickTunnelRow(controller: controller, isEnabled: settingsViewModel.settings.remoteAccess.enabled)
        case .custom:
            PickyHubRemoteCloudflareRow(settingsViewModel: settingsViewModel)
        }
    }
}

/// The temporary address Picky's own `cloudflared` received, or why there is
/// none. Errors keep `cloudflared`'s wording because it names the cause.
private struct PickyHubRemoteQuickTunnelRow: View {
    @ObservedObject var controller: PickyRemoteAccessController
    let isEnabled: Bool

    var body: some View {
        switch controller.quickTunnelState {
        case .notInstalled:
            PickyHubSettingsRow(
                title: "settings.remote.cloudflare.quick.address",
                detail: "settings.remote.cloudflare.quick.notInstalled"
            ) {
                PickyHubButton(
                    title: "settings.remote.tailscale.recheck",
                    role: .secondary,
                    systemImage: "arrow.clockwise",
                    action: { controller.restartQuickTunnel() }
                )
            }
        case .running(let url):
            PickyHubSettingsRow(
                title: "settings.remote.cloudflare.quick.address",
                detail: "settings.remote.cloudflare.quick.address.detail"
            ) {
                PickyHubRemoteAddressLabel(address: url)
            }
        case .starting:
            PickyHubSettingsRow(
                title: "settings.remote.cloudflare.quick.address",
                detail: "settings.remote.cloudflare.quick.starting"
            ) {
                ProgressView().controlSize(.small)
            }
        case .stopped:
            PickyHubSettingsRow(
                title: "settings.remote.cloudflare.quick.address",
                detail: LocalizedStringKey(
                    isEnabled ? "settings.remote.cloudflare.quick.starting" : "settings.remote.cloudflare.quick.off"
                )
            ) {
                EmptyView()
            }
        case .failed(let reason):
            PickyHubSettingsRow(
                title: "settings.remote.cloudflare.quick.address",
                detail: "settings.remote.cloudflare.quick.failed"
            ) {
                PickyHubButton(
                    title: "settings.remote.status.retry",
                    role: .secondary,
                    systemImage: "arrow.clockwise",
                    action: { controller.restartQuickTunnel() }
                )
            }
            PickyHubRemoteRowMessage(tone: .error, message: reason)
        }
        if controller.showsQuickTunnelAddressChange {
            PickyHubInlineStatus(
                tone: .warning,
                message: L10n.t("settings.remote.cloudflare.quick.changed"),
                actionTitle: "common.close",
                action: { controller.dismissQuickTunnelAddressChange() }
            )
            .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
            .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
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
