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
            // Animated status dot. With the minimal aesthetic, the dot itself is the
            // "Active / Listening / Setup" signal; we no longer print the matching label
            // beside it because the green = idle / blue = active mapping is enough at this
            // size and the redundant text added visual noise without adding information.
            Circle()
                .fill(statusDotColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusDotColor.opacity(0.6), radius: 3)
                .accessibilityLabel(statusAccessibilityLabel)

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
                    .font(.system(size: 11, weight: .semibold))
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

    private var statusDotColor: Color {
        if !companionManager.isOverlayVisible {
            return DS.Colors.textTertiary
        }
        switch companionManager.voiceState {
        case .idle:
            return DS.Colors.success
        case .listening:
            return DS.Colors.blue400
        case .processing, .responding:
            return DS.Colors.blue400
        }
    }

    private var statusAccessibilityLabel: String {
        if !companionManager.allPermissionsGranted {
            return "Picky setup required"
        }
        if !companionManager.isOverlayVisible {
            return "Picky ready"
        }
        switch companionManager.voiceState {
        case .idle:
            return "Picky active"
        case .listening:
            return "Picky listening"
        case .processing:
            return "Picky processing"
        case .responding:
            return "Picky responding"
        }
    }

}
