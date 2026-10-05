//
//  PickyHubRemoteDevicesSection.swift
//  Picky
//
//  Pairing a phone and managing the phones already paired. The pairing sheet is
//  a hub modal so `Esc` and the backdrop cancel the code the same way the
//  cancel button does.
//

import SwiftUI

struct PickyHubRemoteDevicesSection: View {
    @ObservedObject var controller: PickyRemoteAccessController
    let modalHost: PickyHubModalHost
    @Environment(\.locale) private var locale

    private var availability: PickyHubRemotePairingAvailability {
        PickyHubRemotePairingAvailability.resolve(
            isRunning: controller.isRunning,
            isHubConnected: controller.isHubConnected,
            entrance: controller.settings.entrance,
            publicURL: controller.publicURL
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickyHubSubsectionTitle(title: "settings.remote.devices")
            PickyHubSettingsList {
                PickyHubSettingsRow(
                    title: "settings.remote.pair",
                    detail: LocalizedStringKey(availability.detailKey)
                ) {
                    PickyHubButton(
                        title: "settings.remote.pair.action",
                        role: .primary,
                        systemImage: "qrcode",
                        isEnabled: availability.isAvailable,
                        action: presentPairingSheet
                    )
                }
                if controller.devices.isEmpty {
                    PickyHubRemoteRowMessage(
                        tone: .neutral,
                        message: L10n.t("settings.remote.devices.empty")
                    )
                } else {
                    ForEach(controller.devices) { device in
                        PickyHubRemoteDeviceRow(
                            device: device,
                            lastSeen: PickyHubRemoteDeviceFormatter.lastSeen(device.lastSeenAt, locale: locale),
                            revoke: { confirmRevoke(device) }
                        )
                    }
                }
            }
        }
    }

    // MARK: - Pairing

    private func presentPairingSheet() {
        controller.startPairing()
        modalHost.present(
            accessibilityLabel: L10n.t("settings.remote.pair.title"),
            onWillDismiss: {
                // Closing the sheet is how a user abandons a live code. Once
                // the code is spent, there is nothing to cancel; only the
                // result needs clearing so the next open starts fresh.
                if case .waiting = controller.pairing {
                    controller.cancelPairing()
                } else {
                    controller.dismissPairingResult()
                }
            }
        ) {
            PickyHubRemotePairingSheet(
                controller: controller,
                onClose: { modalHost.dismiss() }
            )
        }
    }

    private func confirmRevoke(_ device: PickyRemoteDevice) {
        modalHost.present(
            width: 430,
            accessibilityLabel: L10n.t("settings.remote.devices.revoke.title", device.name)
        ) {
            PickyHubConfirmDialog(
                title: L10n.t("settings.remote.devices.revoke.title", device.name),
                message: L10n.t("settings.remote.devices.revoke.message"),
                confirmTitle: "settings.remote.devices.revoke.confirm",
                onCancel: { modalHost.dismiss() },
                onConfirm: {
                    controller.revokeDevice(id: device.id)
                    modalHost.dismiss()
                }
            )
        }
    }
}

private struct PickyHubRemoteDeviceRow: View {
    let device: PickyRemoteDevice
    let lastSeen: String
    let revoke: () -> Void

    private var meta: String {
        let origin = L10n.t(device.isLocal ? "settings.remote.devices.local" : "settings.remote.devices.remote")
        let presence = device.online ? L10n.t("settings.remote.devices.online") : lastSeen
        let push = device.pushEnabled
            ? L10n.t("settings.remote.devices.push.on")
            : L10n.t("settings.remote.devices.push.off")
        return "\(origin) · \(presence) · \(push)"
    }

    var body: some View {
        HStack(alignment: .center, spacing: PickyHubTheme.Spacing.field) {
            Image(systemName: device.isLocal ? "laptopcomputer" : "iphone")
                .pickyFont(size: PickyHubTheme.Typography.body, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                HStack(spacing: PickyHubTheme.Spacing.related) {
                    Circle()
                        .fill(device.online ? PickyHubTheme.Colors.success : PickyHubTheme.Colors.muted)
                        .frame(
                            width: PickyHubRemoteLayout.onlineDotSide,
                            height: PickyHubRemoteLayout.onlineDotSide
                        )
                        .accessibilityHidden(true)
                    Text(device.name)
                        .pickyFont(size: PickyHubTheme.Typography.body, weight: .medium)
                        .foregroundColor(PickyHubTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(meta)
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: PickyHubTheme.Spacing.related)
            PickyHubButton(title: "settings.remote.devices.revoke", role: .danger, action: revoke)
        }
        .padding(.horizontal, PickyHubTheme.Spacing.rowHorizontal)
        .padding(.vertical, PickyHubTheme.Spacing.rowVertical)
        .overlay(alignment: .bottom) { Divider().overlay(PickyHubTheme.Colors.borderSoft) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("\(device.name), \(meta)"))
    }
}

// MARK: - Pairing sheet

private struct PickyHubRemotePairingSheet: View {
    @ObservedObject var controller: PickyRemoteAccessController
    let onClose: () -> Void

    private var address: String {
        PickyHubRemotePairingPayload.address(
            entrance: controller.settings.entrance,
            publicURL: controller.publicURL,
            localURL: controller.localURL
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.field) {
            PickyHubModalHeader(title: L10n.t("settings.remote.pair.title"), onClose: onClose)
            switch controller.pairing {
            case .idle:
                PickyHubLoadingRow(message: "settings.remote.pair.creating")
            case .waiting(let session):
                waiting(session)
            case .ended(let reason, let deviceName):
                ended(reason: reason, deviceName: deviceName)
            }
        }
        .padding(PickyHubTheme.Spacing.cardInset)
    }

    @ViewBuilder
    private func waiting(_ session: PickyRemotePairingSession) -> some View {
        HStack(alignment: .top, spacing: PickyHubTheme.Spacing.cardInset) {
            qrCode(session)
            VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
                Text("settings.remote.pair.code")
                    .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                    .foregroundColor(PickyHubTheme.Colors.textTertiary)
                Text(PickyRemotePairingSession.formatted(code: session.code))
                    .pickyFont(size: PickyHubTheme.Typography.modalTitle, weight: .semibold)
                    .monospaced()
                    .foregroundColor(PickyHubTheme.Colors.textPrimary)
                    .pickyHubSelectableText()
                countdown(session)
            }
        }
        VStack(alignment: .leading, spacing: PickyHubTheme.Spacing.related) {
            step(1, L10n.t("settings.remote.pair.step1", address))
            step(2, L10n.t("settings.remote.pair.step2"))
            step(3, L10n.t("settings.remote.pair.step3"))
        }
        PickyHubInlineStatus(tone: .neutral, message: L10n.t("settings.remote.pair.waiting"))
        HStack {
            Spacer(minLength: 0)
            PickyHubButton(title: "settings.remote.pair.cancel", role: .secondary, action: onClose)
        }
    }

    @ViewBuilder
    private func qrCode(_ session: PickyRemotePairingSession) -> some View {
        let payload = PickyHubRemotePairingPayload.resolve(
            session: session,
            entrance: controller.settings.entrance,
            publicURL: controller.publicURL,
            localURL: controller.localURL
        )
        if let payload, let image = PickyRemoteQRCode.image(for: payload, sideLength: PickyHubRemoteLayout.qrSide) {
            Image(nsImage: image)
                .interpolation(.none)
                .resizable()
                .frame(width: PickyHubRemoteLayout.qrSide, height: PickyHubRemoteLayout.qrSide)
                .background(Color.white)
                .pickyHubCard(radius: PickyHubTheme.Radius.cardCompact, fill: Color.white)
                .accessibilityLabel(Text("settings.remote.pair.qr.accessibility"))
        } else {
            PickyHubInlineStatus(tone: .warning, message: L10n.t("settings.remote.pair.qrUnavailable"))
                .frame(width: PickyHubRemoteLayout.qrSide)
        }
    }

    @ViewBuilder
    private func countdown(_ session: PickyRemotePairingSession) -> some View {
        let now = Date()
        HStack(spacing: PickyHubTheme.Spacing.related) {
            Text("settings.remote.pair.expiresIn")
                .pickyFont(size: PickyHubTheme.Typography.caption, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textTertiary)
            Text(timerInterval: now...max(session.expiresAt, now), countsDown: true)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .medium)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
        }
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: PickyHubTheme.Spacing.related) {
            Text("\(number).")
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .semibold)
                .monospacedDigit()
                .foregroundColor(PickyHubTheme.Colors.action)
            Text(text)
                .pickyFont(size: PickyHubTheme.Typography.bodySmall, weight: .regular)
                .foregroundColor(PickyHubTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .pickyHubSelectableText()
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private func ended(reason: PickyRemotePairingEndReason, deviceName: String?) -> some View {
        switch reason {
        case .paired:
            PickyHubInlineStatus(
                tone: .success,
                message: deviceName.map { L10n.t("settings.remote.pair.paired", $0) }
                    ?? L10n.t("settings.remote.pair.pairedUnnamed")
            )
            HStack {
                Spacer(minLength: 0)
                PickyHubButton(title: "common.close", action: onClose)
            }
        case .expired, .exhausted, .cancelled:
            PickyHubInlineStatus(tone: .warning, message: endedMessage(reason))
            HStack(spacing: PickyHubTheme.Spacing.related) {
                Spacer(minLength: 0)
                PickyHubButton(title: "common.close", role: .secondary, action: onClose)
                PickyHubButton(
                    title: "settings.remote.pair.retry",
                    action: { controller.startPairing() }
                )
            }
        }
    }

    private func endedMessage(_ reason: PickyRemotePairingEndReason) -> String {
        switch reason {
        case .paired: L10n.t("settings.remote.pair.pairedUnnamed")
        case .expired: L10n.t("settings.remote.pair.expired")
        case .exhausted: L10n.t("settings.remote.pair.exhausted")
        case .cancelled: L10n.t("settings.remote.pair.cancelled")
        }
    }
}
