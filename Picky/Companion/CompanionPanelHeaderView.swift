//
//  CompanionPanelHeaderView.swift
//  Picky
//
//  Header rendering for the companion panel.
//

import SwiftUI

struct CompanionPanelHeaderView: View {
    @ObservedObject var companionManager: CompanionManager

    var body: some View {
        HStack(spacing: 8) {
            Image("PickyHeaderLogo")
                .resizable()
                .scaledToFit()
                .frame(width: 61, height: 16, alignment: .leading)
                .accessibilityLabel("Picky")

            Spacer()

            // Plain glyph close button. The pre-minimal design wrapped this in a tinted
            // circle which read as a chip; here the icon stands alone and the hover/press
            // states come from the surrounding `.buttonStyle(.plain)` + opacity feedback.
            Button(action: {
                NotificationCenter.default.post(name: .pickyDismissPanel, object: nil)
            }) {
                Image(systemName: "xmark")
                    .pickyFont(size: 11, weight: .semibold)
                    .foregroundColor(DS.Colors.textTertiary)
                    .frame(width: 20, height: 20, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .pointerCursor()
            .accessibilityLabel("Dismiss panel")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

}
