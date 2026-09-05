//
//  PickyCompletionNotificationControlsView.swift
//  Picky
//
//  Independent successful-completion controls for one Pickle.
//

import SwiftUI

struct PickyCompletionNotificationControlsView: View {
    let notifyMainOnCompletion: Bool
    let notifyMacOSOnCompletion: Bool
    let isCommandShortcutHintVisible: Bool
    let onToggleMain: () -> Void
    let onToggleMacOS: () -> Void

    var body: some View {
        Button(action: onToggleMain) {
            Image("PickyStatusBarIcon")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundColor(notifyMainOnCompletion ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: 11, height: 11)
                .frame(width: PickyComposerToolbarMetrics.controlSize, height: PickyComposerToolbarMetrics.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: notifyMainOnCompletion))
        .help(PickyComposerLabelPolicy.notifyMainOnCompletionHelpText(enabled: notifyMainOnCompletion))
        .accessibilityLabel(L10n.t("hud.composer.notifyMain.accessibilityLabel"))
        .accessibilityValue(notifyMainOnCompletion ? "On" : "Off")

        Button(action: onToggleMacOS) {
            Image(systemName: PickyComposerLabelPolicy.notifyMacOSOnCompletionIconName(enabled: notifyMacOSOnCompletion))
                .pickyFont(size: 10.5, weight: .semibold)
                .foregroundColor(notifyMacOSOnCompletion ? DS.Colors.accentText : DS.Colors.textTertiary)
                .frame(width: PickyComposerToolbarMetrics.controlSize, height: PickyComposerToolbarMetrics.controlSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(PickyComposerToolbarGhostButtonStyle(isActive: notifyMacOSOnCompletion))
        .overlay(alignment: .topTrailing) {
            PickyShortcutKeyBadge(label: "N")
                .fixedSize()
                .offset(x: 9, y: -7)
                .opacity(isCommandShortcutHintVisible ? 1 : 0)
                .scaleEffect(isCommandShortcutHintVisible ? 1 : 0.88, anchor: .center)
                .animation(.easeOut(duration: 0.12), value: isCommandShortcutHintVisible)
                .allowsHitTesting(false)
        }
        .help(PickyComposerLabelPolicy.notifyMacOSOnCompletionHelpText(enabled: notifyMacOSOnCompletion))
        .accessibilityLabel(L10n.t("hud.composer.notifyMacOS.accessibilityLabel"))
        .accessibilityValue(notifyMacOSOnCompletion ? "On" : "Off")
    }
}
