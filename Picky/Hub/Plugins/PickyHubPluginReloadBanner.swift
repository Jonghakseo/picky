//
//  PickyHubPluginReloadBanner.swift
//  Picky
//
//  Plugin changes apply automatically, so this view stays empty unless the
//  apply failed and the user needs to retry.
//

import SwiftUI

struct PickyHubPluginReloadBanner: View {
    @ObservedObject var controller: PickyPluginReloadController
    let onRetry: () -> Void

    var body: some View {
        if controller.needsAttention, let error = controller.lastError {
            PickyHubInlineStatus(
                tone: .error,
                message: L10n.t("hub.plugins.apply.failed", error),
                actionTitle: "hub.plugins.reload.retry",
                action: onRetry
            )
        }
    }
}
