//
//  PickyRunningComposerBorder.swift
//  Picky
//
//  Live-Pickle border cue for the conversation composer.
//

import SwiftUI

/// Static tinted border used as the "this Pickle is live" signal on the
/// composer of a running Pickle. The running state is already conveyed by the
/// header status dot and the card status border; this is a steady peripheral
/// cue exactly where the user next acts, without decorative motion.
struct PickyRunningComposerBorder: View {
    var body: some View {
        let _ = PickyPerf.event("running_composer_border_body")
        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
            .strokeBorder(DS.Colors.info.opacity(0.7), lineWidth: 1.0)
            .accessibilityHidden(true)
    }
}
