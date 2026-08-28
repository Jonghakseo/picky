//
//  PickyHUDUtilityPanel.swift
//  Picky
//
//  Terminal utility panel attached below a Pickle conversation card.
//

import SwiftUI

/// Pure state and layout policy for the Pickle utility panel.
enum PickyHUDUtilityPanelPolicy {
    static let heightStorageKey = "pickyHUD.utilityPanel.height"
    static let defaultHeight: CGFloat = 240
    static let minimumHeight: CGFloat = 120
    static let maximumHeightFraction: CGFloat = 0.6
    static let resizeGripHeight: CGFloat = 12
    static let minimumConversationCardHeight: CGFloat = 320

    static func openSessionIDsAfterToggling(
        sessionID: String,
        openSessionIDs: Set<String>
    ) -> Set<String> {
        var next = openSessionIDs
        if next.contains(sessionID) {
            next.remove(sessionID)
        } else {
            next.insert(sessionID)
        }
        return next
    }

    static func clampedHeight(_ height: CGFloat, availableCardHeight: CGFloat) -> CGFloat {
        let maximumHeight = max(minimumHeight, availableCardHeight * maximumHeightFraction)
        return min(max(height, minimumHeight), maximumHeight)
    }

    static func conversationCardMaxHeight(
        availableCardHeight: CGFloat,
        utilityPanelHeight: CGFloat
    ) -> CGFloat {
        max(
            minimumConversationCardHeight,
            availableCardHeight - utilityPanelHeight - resizeGripHeight
        )
    }
}

/// Terminal surface attached below a Pickle conversation card.
struct PickySessionUtilityPanelView: View {
    let sessionStore: PickySessionStore
    let commands: any PickySessionCommands
    let height: CGFloat

    var body: some View {
        PickySessionExtendedTerminalView(
            sessionStore: sessionStore,
            commands: commands,
            height: height,
            showsPanelChrome: false,
            isFocusEligible: true
        )
        .frame(height: height, alignment: .top)
        .background(panelBackground)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L10n.t("hud.utilityPanel.accessibilityLabel"))
    }

    private var panelBackground: some View {
        RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
            .fill(DS.Colors.surface1)
            .overlay(
                RoundedRectangle(cornerRadius: DS.CornerRadius.panel, style: .continuous)
                    .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
            )
    }
}

struct PickyHUDUtilityPanelResizeGrip: View {
    var onDragChanged: (CGFloat) -> Void
    var onDragEnded: () -> Void

    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(isHovered ? DS.Colors.borderStrong : DS.Colors.borderSubtle)
                .frame(width: 32, height: 3)
        }
        .frame(maxWidth: .infinity)
        .frame(height: PickyHUDUtilityPanelPolicy.resizeGripHeight)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { onDragChanged($0.translation.height) }
                .onEnded { _ in onDragEnded() }
        )
        .accessibilityHidden(true)
    }
}
