//
//  PickySettingsOAuthProviderRow.swift
//  Picky
//
//  Contents of one Settings > Connected accounts row: provider status, the
//  available sign-in methods, and the device code panel shown while a code
//  sign-in is in flight. The surrounding card chrome and the disconnect
//  confirmation stay with the settings section that owns the list.
//

import AppKit
import SwiftUI

struct PickySettingsOAuthProviderRow: View {
    @ObservedObject var controller: PickyPiOAuthLoginController
    let provider: PickyPiOAuthLoginProvider
    let supportingTextColor: Color

    @State private var didCopyCode = false
    @State private var copyFeedbackGeneration = 0

    var body: some View {
        let status = controller.status(for: provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: provider.iconName)
                    .pickyFont(size: 13, weight: .semibold)
                    .foregroundColor(DS.Colors.accentText)
                    .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: DS.Spacing.space2) {
                    Text(L10n.t(provider.titleKey))
                        .font(PickyHUDTypography.supportingSemibold)
                        .foregroundColor(DS.Colors.textPrimary)
                    Text(L10n.t(provider.subtitleKey))
                        .font(PickyHUDTypography.supporting)
                        .foregroundColor(supportingTextColor)
                        .fixedSize(horizontal: false, vertical: true)
                        .pickyHubSelectableText()
                }
                Spacer(minLength: 8)
                statusPill(status)
            }

            if case .signingIn = status, let deviceCode = controller.deviceCodes[provider] {
                deviceCodePanel(deviceCode)
            }

            if case .failed(let message) = status {
                Text(message)
                    .font(PickyHUDTypography.supporting)
                    .foregroundColor(DS.Colors.destructiveText)
                    .fixedSize(horizontal: false, vertical: true)
                    .pickyHubSelectableText()
            }

            HStack(spacing: 8) {
                Button(action: { controller.signIn(provider: provider) }) {
                    Text(primaryButtonTitle(for: status))
                        .font(PickyHUDTypography.statusSemibold)
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, DS.Spacing.space3)
                        .padding(.vertical, DS.Spacing.space2)
                        .background(
                            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                .fill(DS.Colors.accentText.opacity(0.12))
                                .overlay(
                                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                                        .stroke(DS.Colors.accentText.opacity(0.26), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
                .disabled(isBusy(status))
                .opacity(isBusy(status) ? 0.55 : 1)
                .hoverAffordance()

                if provider.supportedLoginMethods.contains(.deviceCode) {
                    Button(action: { controller.signIn(provider: provider, method: .deviceCode) }) {
                        Text("settings.oauth.signInWithCode")
                            .font(PickyHUDTypography.statusSemibold)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, DS.Spacing.space3)
                            .padding(.vertical, DS.Spacing.space2)
                    }
                    .buttonStyle(.plain)
                    .disabled(isBusy(status))
                    .opacity(isBusy(status) ? 0.55 : 1)
                    .hoverAffordance()
                }

                if case .configured = status {
                    Button(action: { controller.requestSignOut(provider: provider) }) {
                        Text("settings.oauth.disconnect")
                            .font(PickyHUDTypography.statusSemibold)
                            .foregroundColor(DS.Colors.destructiveText)
                            .padding(.horizontal, DS.Spacing.space3)
                            .padding(.vertical, DS.Spacing.space2)
                    }
                    .buttonStyle(.plain)
                    .hoverAffordance()
                }

                if case .signingIn = status {
                    Button(action: { controller.cancel(provider: provider) }) {
                        Text("settings.oauth.cancel")
                            .font(PickyHUDTypography.statusSemibold)
                            .foregroundColor(DS.Colors.textSecondary)
                            .padding(.horizontal, DS.Spacing.space3)
                            .padding(.vertical, DS.Spacing.space2)
                    }
                    .buttonStyle(.plain)
                    .hoverAffordance()
                }

                Spacer(minLength: 0)
            }
        }
    }

    private func deviceCodePanel(_ deviceCode: PickyPiOAuthDeviceCode) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("settings.oauth.deviceCode.instructions")
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .fixedSize(horizontal: false, vertical: true)

            Text(deviceCode.userCode)
                .pickyFont(size: 18, weight: .semibold, design: .monospaced)
                .foregroundColor(DS.Colors.textPrimary)
                .pickyHubSelectableText()
                .accessibilityLabel(L10n.t("settings.oauth.deviceCode.accessibility", deviceCode.userCode))

            Text(deviceCode.verificationURL.absoluteString)
                .font(PickyHUDTypography.supporting)
                .foregroundColor(supportingTextColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .pickyHubSelectableText()

            HStack(spacing: 8) {
                Button(action: { copyCode(deviceCode.userCode) }) {
                    Label(
                        didCopyCode ? "settings.oauth.deviceCode.copied" : "settings.oauth.deviceCode.copy",
                        systemImage: didCopyCode ? "checkmark" : "doc.on.doc"
                    )
                    .font(PickyHUDTypography.statusSemibold)
                    .foregroundColor(didCopyCode ? DS.Colors.successText : DS.Colors.textSecondary)
                    .padding(.horizontal, DS.Spacing.space3)
                    .padding(.vertical, DS.Spacing.space2)
                }
                .buttonStyle(.plain)
                .hoverAffordance()

                Button(action: { NSWorkspace.shared.open(deviceCode.verificationURL) }) {
                    Label("settings.oauth.deviceCode.openPage", systemImage: "arrow.up.right.square")
                        .font(PickyHUDTypography.statusSemibold)
                        .foregroundColor(DS.Colors.accentText)
                        .padding(.horizontal, DS.Spacing.space3)
                        .padding(.vertical, DS.Spacing.space2)
                }
                .buttonStyle(.plain)
                .hoverAffordance()
            }
        }
        .padding(DS.Spacing.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.accentText.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .stroke(DS.Colors.accentText.opacity(0.2), lineWidth: 0.5)
                )
        )
    }

    private func copyCode(_ userCode: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
        didCopyCode = true
        copyFeedbackGeneration &+= 1
        let feedbackGeneration = copyFeedbackGeneration
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard copyFeedbackGeneration == feedbackGeneration else { return }
            didCopyCode = false
        }
    }

    private func statusPill(_ status: PickyPiOAuthLoginStatus) -> some View {
        let display = statusDisplay(status)
        return HStack(spacing: 4) {
            Image(systemName: display.icon)
                .font(PickyHUDTypography.minimumSemibold)
            Text(display.text)
                .font(PickyHUDTypography.minimumSemibold)
                .lineLimit(1)
        }
        .foregroundColor(display.foreground)
        .padding(.horizontal, DS.Spacing.space2)
        .padding(.vertical, DS.Spacing.space1)
        .background(
            Capsule(style: .continuous)
                .fill(display.background.opacity(0.12))
        )
    }

    private func statusDisplay(
        _ status: PickyPiOAuthLoginStatus
    ) -> (text: String, icon: String, foreground: Color, background: Color) {
        switch status {
        case .unknown, .checking:
            return (L10n.t("settings.oauth.status.checking"), "clock", DS.Colors.textTertiary, DS.Colors.textTertiary)
        case .notConfigured:
            return (L10n.t("settings.oauth.status.notConfigured"), "circle", DS.Colors.textTertiary, DS.Colors.textTertiary)
        case .configured(let source):
            let sourceText = source?.isEmpty == false ? source! : L10n.t("settings.oauth.status.stored")
            return (L10n.t("settings.oauth.status.configured", sourceText), "checkmark.circle.fill", DS.Colors.successText, DS.Colors.success)
        case .signingIn:
            if controller.deviceCodes[provider] != nil {
                return (L10n.t("settings.oauth.status.waitingForCode"), "key", DS.Colors.accentText, DS.Colors.accentText)
            }
            if controller.inFlightMethods[provider] == .deviceCode {
                return (L10n.t("settings.oauth.status.preparingCode"), "key", DS.Colors.accentText, DS.Colors.accentText)
            }
            return (L10n.t("settings.oauth.status.signingIn"), "arrow.triangle.2.circlepath", DS.Colors.accentText, DS.Colors.accentText)
        case .signingOut:
            return (L10n.t("settings.oauth.status.signingOut"), "arrow.triangle.2.circlepath", DS.Colors.textSecondary, DS.Colors.textSecondary)
        case .failed:
            return (L10n.t("settings.oauth.status.failed"), "exclamationmark.triangle.fill", DS.Colors.destructiveText, DS.Colors.destructiveText)
        }
    }

    private func primaryButtonTitle(for status: PickyPiOAuthLoginStatus) -> LocalizedStringKey {
        switch status {
        case .configured:
            return "settings.oauth.reconnect"
        default:
            return "settings.oauth.signIn"
        }
    }

    private func isBusy(_ status: PickyPiOAuthLoginStatus) -> Bool {
        switch status {
        case .checking, .signingIn, .signingOut:
            return true
        default:
            return false
        }
    }
}
