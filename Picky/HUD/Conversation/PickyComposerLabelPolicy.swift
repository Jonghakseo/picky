//
//  PickyComposerLabelPolicy.swift
//  Picky
//
//  Placeholder, send-tooltip, and notify-toggle copy for the conversation
//  composer, plus the bash-mode accent it shares with the composer chrome.
//  Localization is injectable so the rules stay testable without global
//  locale state.
//

import SwiftUI

enum PickyComposerLabelPolicy {
    static func placeholder(
        isCompacting: Bool,
        isFileDropTargeted: Bool,
        status: PickySessionStatus,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> String {
        if isCompacting { return localizer("hud.composer.placeholder.compacting") }
        if isFileDropTargeted { return localizer("hud.composer.placeholder.drop") }
        switch status {
        case .running, .queued, .waiting_for_input:
            return localizer("hud.composer.placeholder.steer")
        case .completed, .blocked:
            return localizer("hud.composer.placeholder.followUp")
        case .cancelled:
            return localizer("hud.composer.placeholder.resume")
        case .failed:
            return localizer("hud.composer.placeholder.recovery")
        }
    }

    static func sendHelpText(
        isCompacting: Bool,
        hasDefaultSubmitKind: Bool,
        hasDraftText: Bool,
        bashMode: PickyComposerBashMode,
        activeSubmitKind: PickyConversationComposerSubmitKind?,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> String {
        if isCompacting { return localizer("hud.composer.send.compacting") }
        guard hasDefaultSubmitKind else { return localizer("hud.composer.send.unavailable") }
        guard hasDraftText else { return localizer("hud.composer.send.empty") }

        switch bashMode {
        case .visible:
            return localizer("hud.composer.send.bashVisible")
        case .private:
            return localizer("hud.composer.send.bashPrivate")
        case .none:
            switch activeSubmitKind {
            case .steer:
                return localizer("hud.composer.send.steer")
            case .followUp:
                return localizer("hud.composer.send.followUp")
            case nil:
                return localizer("hud.composer.send.unavailable")
            }
        }
    }

    static func bashAccentColor(for mode: PickyComposerBashMode) -> Color {
        switch mode {
        case .visible: return DS.Colors.successText
        case .private: return DS.Colors.warningText
        case .none: return DS.Colors.borderSubtle
        }
    }

    static func notifyMainOnCompletionHelpText(
        enabled: Bool,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> String {
        localizer(enabled ? "hud.composer.notifyMain.on.help" : "hud.composer.notifyMain.off.help")
    }

    static func notifyMacOSOnCompletionIconName(enabled: Bool) -> String {
        enabled ? "bell.fill" : "bell.slash"
    }

    static func notifyMacOSOnCompletionHelpText(
        enabled: Bool,
        localizer: (String) -> String = { L10n.t($0) }
    ) -> String {
        localizer(enabled ? "hud.composer.notifyMacOS.on.help" : "hud.composer.notifyMacOS.off.help")
    }
}
