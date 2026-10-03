//
//  PickyComposerSendTimingMenuHost.swift
//  Picky
//
//  Wires the "when to send" popover to the composer's scheduled-message
//  model, so the composer only passes the draft-level facts it owns.
//

import SwiftUI

struct PickyComposerSendTimingMenuHost: View {
    @ObservedObject var scheduled: PickyComposerScheduledModel
    let commands: any PickySessionCommands
    let canSendAfterCurrentReply: Bool
    let carriesScreenContext: Bool
    let onSelect: (PickySendTiming) -> Void

    var body: some View {
        PickySendTimingMenuView(
            options: scheduled.sendTimingMenu?.options ?? [],
            isPluginInstalled: scheduled.sendTimingMenu?.isPluginInstalled ?? false,
            isInstallingPlugin: scheduled.isInstallingPlugin,
            installError: scheduled.installError,
            onSelect: onSelect,
            onInstallPlugin: {
                scheduled.installPlugin(
                    canSendAfterCurrentReply: canSendAfterCurrentReply,
                    carriesScreenContext: carriesScreenContext,
                    commands: commands
                )
            },
            customTime: customSendTimeBinding,
            onCustomBack: { scheduled.closeCustomSendTime() },
            onCustomCancel: { scheduled.isSendTimingMenuPresented = false }
        )
    }

    private var customSendTimeBinding: Binding<PickyCustomSendTimeDraft>? {
        guard let draft = scheduled.customSendTime else { return nil }
        return Binding(
            get: { scheduled.customSendTime ?? draft },
            set: { scheduled.customSendTime = $0 }
        )
    }
}
