//
//  PickyFullscreenWorkspaceView.swift
//  Picky
//
//  Fullscreen workspace shell: sidebar, focused conversation, composer, and
//  read-only work info panel.
//

import SwiftUI

struct PickyFullscreenWorkspaceView: View {
    @ObservedObject var viewModel: PickySessionListViewModel
    @ObservedObject var stateStore: PickyFullscreenStateStore

    private var selectedSession: PickySessionListViewModel.SessionCard? {
        guard let selectedSessionID = stateStore.selectedSessionID else { return nil }
        return viewModel.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        HStack(spacing: 0) {
            PickyFullscreenSidebarView(
                sessions: viewModel.sessions,
                selectedSessionID: $stateStore.selectedSessionID
            )

            Divider()

            PickyFullscreenConversationPaneView(
                session: selectedSession,
                viewModel: viewModel
            )

            Divider()

            PickyFullscreenWorkInfoPanelView(
                session: selectedSession,
                isVisible: $stateStore.isWorkInfoPanelVisible
            )
            .transaction { transaction in
                transaction.animation = nil
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reconcileSelectedSession)
        .onChange(of: viewModel.sessions.map(\.id)) { _, _ in reconcileSelectedSession() }
        .onChange(of: viewModel.selectedSessionID) { _, _ in reconcileSelectedSession() }
    }

    private func reconcileSelectedSession() {
        let resolvedID = PickyFullscreenSessionSelection.resolvedSessionID(
            requestedSessionID: nil,
            storedSelectedSessionID: stateStore.selectedSessionID,
            viewModelSelectedSessionID: viewModel.selectedSessionID,
            candidates: PickyFullscreenSessionSelection.candidates(from: viewModel.sessions)
        )
        if stateStore.selectedSessionID != resolvedID {
            stateStore.selectedSessionID = resolvedID
        }
    }
}
