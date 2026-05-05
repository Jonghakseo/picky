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
