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
            composerPlaceholder
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: PickyHUDDockLayout.detailWidth)
        .background(cardBackground)
    }

    private var composerPlaceholder: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(DS.Colors.surface2.opacity(0.35))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(DS.Colors.borderSubtle.opacity(0.45), lineWidth: 0.8)
            )
            .frame(height: 34)
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
