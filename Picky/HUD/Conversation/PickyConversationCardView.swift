//
//  PickyConversationCardView.swift
//  Picky
//
//  Core conversation-style side-agent card container.
//

import SwiftUI

struct PickyConversationCardView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    let session: PickySessionListViewModel.SessionCard

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            PickyConversationHeaderView(viewModel: viewModel, session: session)
            PickyConversationContextLineView(session: session)
            PickyConversationListView(session: session, viewModel: viewModel)
            PickyConversationComposerView(session: session, viewModel: viewModel)
        }
        .frame(width: PickyHUDDockLayout.detailContentWidth, alignment: .topLeading)
        .padding(.horizontal, PickyHUDDockLayout.detailHorizontalPadding)
        .padding(.vertical, 12)
        .frame(width: PickyHUDDockLayout.detailWidth)
        .frame(minHeight: 320, maxHeight: 1080, alignment: .top)
        .background(cardBackground)
        .background(reportKeyboardShortcut)
        .contentShape(Rectangle())
        .onHover(perform: updateVoiceFollowUpHover)
    }

    func updateVoiceFollowUpHover(_ hovering: Bool) {
        if hovering {
            viewModel.beginHoveredVoiceFollowUp(sessionID: session.id)
        } else {
            viewModel.endHoveredVoiceFollowUp(sessionID: session.id)
        }
    }

    /// Hidden button that binds ⌘R at card/window scope. Menu keyboard shortcuts are
    /// only reliable while the menu is open; this keeps "Open report" available while
    /// the HUD card itself is focused.
    private var reportKeyboardShortcut: some View {
        Button("Open report") {
            Task { try? await viewModel.openReport(sessionID: session.id) }
        }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(!session.canOpenMarkdownReport)
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(DS.Colors.surface1.opacity(0.95))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(statusColor.opacity(0.58), lineWidth: 1)
            )
            .shadow(color: .black.opacity(PickyHUDExpansion.cardShadowOpacity), radius: PickyHUDExpansion.cardShadowRadius, y: PickyHUDExpansion.cardShadowYOffset)
    }

    private var statusColor: Color {
        switch session.status {
        case .running:
            return DS.Colors.info
        case .completed:
            return DS.Colors.success
        case .waiting_for_input:
            return DS.Colors.warning
        case .failed:
            return DS.Colors.destructiveText
        case .blocked:
            return DS.Colors.warningText
        case .queued, .cancelled:
            return DS.Colors.textTertiary
        }
    }
}
