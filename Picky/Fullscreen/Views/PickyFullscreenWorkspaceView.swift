//
//  PickyFullscreenWorkspaceView.swift
//  Picky
//
//  Placeholder shell for the fullscreen workspace. Later phases replace each
//  column with the real sidebar, conversation, composer, and work info panel.
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

            if stateStore.isWorkInfoPanelVisible {
                Divider()

                placeholderColumn(
                    title: "작업 정보",
                    subtitle: selectedSessionWorkInfoDescription,
                    minWidth: 260,
                    idealWidth: 300
                )
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: reconcileSelectedSession)
        .onChange(of: viewModel.sessions.map(\.id)) { _, _ in reconcileSelectedSession() }
        .onChange(of: viewModel.selectedSessionID) { _, _ in reconcileSelectedSession() }
    }

    private var selectedSessionWorkInfoDescription: String {
        guard let selectedSession else {
            return "Session details will appear here."
        }
        return "\(selectedSession.status.rawValue) · updated \(selectedSession.elapsedSinceUpdate()) ago"
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

    private func placeholderColumn(
        title: String,
        subtitle: String,
        minWidth: CGFloat,
        idealWidth: CGFloat
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.primary)
            Text(subtitle)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(20)
        .frame(minWidth: minWidth, idealWidth: idealWidth, maxHeight: .infinity, alignment: .topLeading)
    }
}
