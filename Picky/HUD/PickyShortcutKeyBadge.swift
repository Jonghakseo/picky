//
//  PickyShortcutKeyBadge.swift
//  Picky
//
//  Shared visual-only shortcut hint shown while the Command modifier is held.
//

import SwiftUI

/// Floating shortcut hint shared by HUD controls. The corresponding control
/// provides the accessible label and help text; this decorative badge is hidden
/// from VoiceOver.
struct PickyShortcutKeyBadge: View {
    let label: String
    let symbols: [String]

    init(label: String, symbols: [String] = ["command"]) {
        self.label = label
        self.symbols = symbols
    }

    var body: some View {
        HStack(spacing: 1.5) {
            ForEach(symbols, id: \.self) { symbol in
                Image(systemName: symbol)
                    .font(PickyHUDTypography.badgeIconBold)
            }
            Text(label)
                .font(PickyHUDTypography.badgeBoldRounded)
                .monospacedDigit()
        }
        .foregroundColor(DS.Colors.textPrimary)
        .padding(.horizontal, 4.5)
        .frame(height: 15)
        .background(PickyHUDMaterialFill(shape: Capsule(style: .continuous), fallback: DS.Colors.surface1))
        .overlay(Capsule(style: .continuous).fill(DS.Colors.surface1.opacity(0.70)))
        .overlay(Capsule(style: .continuous).strokeBorder(DS.Colors.borderSubtle.opacity(0.72), lineWidth: 0.7))
        .shadow(color: Color.black.opacity(0.18), radius: 4, x: 0, y: 1.5)
        .accessibilityHidden(true)
    }
}

