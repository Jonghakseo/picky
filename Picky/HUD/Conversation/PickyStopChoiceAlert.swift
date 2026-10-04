//
//  PickyStopChoiceAlert.swift
//  Picky
//
//  Native alert asking what a Pickle stop should end when background tasks are running.
//

import SwiftUI

extension View {
    /// Uses `.alert` rather than `confirmationDialog`, which dims the transparent HUD window.
    func pickyStopChoiceAlert(
        _ request: Binding<PickyStopChoiceRequest?>,
        onStop: @escaping (_ sessionID: String, _ scope: PickyAbortScope) -> Void
    ) -> some View {
        alert(
            Text(L10n.t("hud.stopChoice.title")),
            isPresented: Binding(
                get: { request.wrappedValue != nil },
                set: { if !$0 { request.wrappedValue = nil } }
            ),
            presenting: request.wrappedValue
        ) { pending in
            if pending.choice == .responseOrAll {
                Button("hud.stopChoice.stopResponse") { onStop(pending.sessionID, .response) }
                Button("hud.stopChoice.stopAll", role: .destructive) { onStop(pending.sessionID, .all) }
            } else {
                Button("hud.stopChoice.stopBackground", role: .destructive) { onStop(pending.sessionID, .all) }
            }
            Button("hud.stopChoice.cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.choice == .responseOrAll ? "hud.stopChoice.message" : "hud.stopChoice.backgroundOnly.message")
        }
    }
}
