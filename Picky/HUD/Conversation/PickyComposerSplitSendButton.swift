//
//  PickyComposerSplitSendButton.swift
//  Picky
//
//  Slack-style split send control: the left half sends now, the chevron opens
//  the "보낼 시점" menu. Design: build/render-gallery/steer-followup
//  /9-send-menu, 10-send-menu-no-plugin.
//

import SwiftUI

struct PickyComposerSplitSendButton: View {
    let iconName: String
    let accessibilityLabel: String
    let helpText: String
    let isEnabled: Bool
    /// Accent for ordinary sends, bash accent while the draft is a command.
    let tint: Color
    let isMenuOpen: Bool
    /// Separate from `isEnabled`: send still works while a scheduled message is
    /// being edited, but choosing a send time there would create a new message.
    var isMenuEnabled: Bool = true
    let onSend: () -> Void
    let onToggleMenu: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onSend) {
                Image(systemName: iconName)
                    .id(iconName)
                    .pickyFont(size: 11, weight: .semibold)
                    // Set per label: macOS plain buttons do not inherit the
                    // container's foreground color for their content.
                    .foregroundStyle(Self.contentColor)
                    .frame(width: Self.sendWidth, height: PickyComposerToolbarMetrics.controlSize)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(helpText)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint(helpText)

            Rectangle()
                .fill(Color.white.opacity(0.35))
                .frame(width: 1, height: Self.dividerHeight)
                .accessibilityHidden(true)

            Button(action: onToggleMenu) {
                Image(systemName: "chevron.down")
                    .pickyFont(size: 9, weight: .bold)
                    .foregroundStyle(Self.contentColor)
                    .opacity(isEnabled && !isMenuEnabled ? Self.disabledChevronOpacity : 1)
                    .frame(width: Self.chevronWidth, height: PickyComposerToolbarMetrics.controlSize)
                    .contentShape(Rectangle())
                    .background(isMenuOpen ? Color.black.opacity(Self.openMenuOverlayOpacity) : Color.clear)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled || !isMenuEnabled)
            .help(L10n.t("hud.composer.sendTiming.help"))
            .accessibilityLabel(L10n.t("hud.composer.sendTiming.accessibilityLabel"))
        }
        .background(isEnabled ? tint : DS.Colors.surface3)
        .clipShape(RoundedRectangle(cornerRadius: DS.CornerRadius.small, style: .continuous))
        .opacity(isEnabled ? 1 : 0.6)
        .hoverAffordance()
    }

    /// The filled control is always Action Blue or the bash accent, both dark
    /// enough for white glyphs in light and dark appearance.
    private static let contentColor = Color.white
    private static let openMenuOverlayOpacity: Double = 0.18
    private static let disabledChevronOpacity: Double = 0.5
    private static let sendWidth: CGFloat = 28
    private static let chevronWidth: CGFloat = 20
    private static let dividerHeight: CGFloat = 14
}

/// "보낼 시점" popover content. Rows stay visible but disabled when the
/// delayed-action plugin is missing, with an inline install affordance.
struct PickySendTimingMenuView: View {
    let options: [PickySendTimingOption]
    let isPluginInstalled: Bool
    let isInstallingPlugin: Bool
    let installError: String?
    let onSelect: (PickySendTiming) -> Void
    let onInstallPlugin: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(L10n.t("hud.composer.sendTiming.title"))
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textTertiary)
                .padding(.horizontal, DS.Spacing.space3)
                .padding(.top, DS.Spacing.space2)
                .padding(.bottom, DS.Spacing.space1)
            ForEach(Array(options.enumerated()), id: \.element.id) { index, option in
                if index == 1 {
                    Divider().padding(.vertical, DS.Spacing.space1)
                }
                row(option)
            }
            if !isPluginInstalled {
                installRow
            }
            Spacer().frame(height: DS.Spacing.space2)
        }
        .frame(width: Self.width, alignment: .leading)
    }

    private func row(_ option: PickySendTimingOption) -> some View {
        Button { onSelect(option.timing) } label: {
            HStack(spacing: DS.Spacing.space2) {
                Text(option.title)
                    .font(PickyHUDTypography.bodyCompact)
                    .foregroundColor(option.isEnabled ? DS.Colors.textPrimary : DS.Colors.textTertiary)
                Spacer(minLength: DS.Spacing.space2)
                if let detail = option.detail {
                    Text(detail)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                }
                if let shortcut = option.shortcut {
                    Text(shortcut)
                        .font(PickyHUDTypography.status)
                        .foregroundColor(DS.Colors.textTertiary)
                }
            }
            .padding(.horizontal, DS.Spacing.space2)
            .padding(.vertical, Self.rowVerticalPadding)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!option.isEnabled)
        .hoverAffordance()
        .padding(.horizontal, DS.Spacing.space1)
        .opacity(option.isEnabled ? 1 : 0.55)
        .help(option.disabledReason ?? "")
        .accessibilityLabel(option.title)
        .accessibilityValue(option.disabledReason ?? option.detail ?? "")
    }

    @ViewBuilder
    private var installRow: some View {
        HStack(spacing: DS.Spacing.space1) {
            Text(L10n.t("hud.composer.sendTiming.pluginRequired"))
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.textTertiary)
            Button(L10n.t(isInstallingPlugin ? "hud.composer.sendTiming.installing" : "hud.composer.sendTiming.install")) {
                onInstallPlugin()
            }
            .buttonStyle(.plain)
            .font(PickyHUDTypography.statusSemibold)
            .foregroundColor(DS.Colors.accentText)
            .disabled(isInstallingPlugin)
            .hoverAffordance()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DS.Spacing.space3)
        .padding(.top, DS.Spacing.space1)
        .fixedSize(horizontal: false, vertical: true)

        if let installError {
            Text(installError)
                .font(PickyHUDTypography.status)
                .foregroundColor(DS.Colors.destructiveText)
                .padding(.horizontal, DS.Spacing.space3)
                .padding(.top, DS.Spacing.space1)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    static let width: CGFloat = 250
    private static let rowVerticalPadding: CGFloat = 5
}
