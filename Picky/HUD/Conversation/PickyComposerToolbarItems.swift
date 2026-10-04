//
//  PickyComposerToolbarItems.swift
//  Picky
//
//  Value-only pieces of the composer action row. They read no composer state,
//  so they live outside PickyConversationComposerView.
//

import SwiftUI

/// Square glyph shared by the composer's toolbar buttons.
struct PickyComposerToolbarIcon: View {
    let systemName: String
    let color: Color

    var body: some View {
        Image(systemName: systemName)
            .pickyFont(size: 10.5, weight: .semibold)
            .foregroundColor(color)
            .frame(
                width: PickyComposerToolbarMetrics.controlSize,
                height: PickyComposerToolbarMetrics.controlSize
            )
            .contentShape(Rectangle())
    }
}

/// Replaces the notify/terminal actions when the draft is in bash-execution
/// mode. Keyboard shortcuts remain active while the horizontal badge keeps
/// the editor's one-line minimum independent from action chrome.
struct PickyComposerBashModeBadge: View {
    let mode: PickyComposerBashMode

    var body: some View {
        HStack(spacing: DS.Spacing.xs) {
            Image(systemName: "terminal.fill")
                .pickyFont(size: 11, weight: .bold)
            Text(mode == .private ? "PRIVATE" : "BASH")
                .font(PickyHUDTypography.badgeMonospacedBold)
                .fixedSize()
        }
        .foregroundColor(PickyComposerLabelPolicy.bashAccentColor(for: mode))
        .padding(.horizontal, DS.Spacing.space2)
        .frame(height: PickyComposerToolbarMetrics.controlSize)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .fill(DS.Colors.surface2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.control, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .help(mode == .private
            ? L10n.t("hud.composer.bash.private.help")
            : L10n.t("hud.composer.bash.shared.help"))
        .accessibilityLabel(mode == .private ? L10n.t("hud.composer.bash.private.accessibility") : L10n.t("hud.composer.bash.accessibility"))
    }
}

/// Toggles the Pickle's utility panel; shows its Command shortcut hint on demand.
struct PickyComposerUtilityPanelButton: View {
    let isOpen: Bool
    let isShortcutHintVisible: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PickyComposerToolbarIcon(
                systemName: "terminal.fill",
                color: isOpen ? DS.Colors.accentText : DS.Colors.textSecondary
            )
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: isOpen))
        .overlay(alignment: .topTrailing) {
            PickyShortcutKeyBadge(label: "E")
                .fixedSize()
                .offset(x: 9, y: -7)
                .opacity(isShortcutHintVisible ? 1 : 0)
                .scaleEffect(isShortcutHintVisible ? 1 : 0.88, anchor: .center)
                .animation(.easeOut(duration: 0.12), value: isShortcutHintVisible)
                .allowsHitTesting(false)
        }
        .help(L10n.t("hud.utilityPanel.toggle.help"))
        .accessibilityLabel(L10n.t("hud.utilityPanel.accessibilityLabel"))
        .accessibilityValue(L10n.t(isOpen ? "hud.utilityPanel.state.open" : "hud.utilityPanel.state.closed"))
    }
}
