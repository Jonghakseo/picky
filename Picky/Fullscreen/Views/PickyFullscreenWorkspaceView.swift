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

    var body: some View {
        HStack(spacing: 0) {
            placeholderColumn(
                title: "Pickles",
                subtitle: "\(viewModel.sessions.count) active sessions",
                minWidth: 220,
                idealWidth: 260
            )

            Divider()

            placeholderColumn(
                title: "Conversation",
                subtitle: selectedSessionDescription,
                minWidth: 480,
                idealWidth: 720
            )
            .frame(maxWidth: .infinity)

            if stateStore.isWorkInfoPanelVisible {
                Divider()

                placeholderColumn(
                    title: "작업 정보",
                    subtitle: "Session details will appear here.",
                    minWidth: 260,
                    idealWidth: 300
                )
            }
        }
        .frame(minWidth: 1040, minHeight: 680)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var selectedSessionDescription: String {
        guard let selectedSessionID = stateStore.selectedSessionID else {
            return "Select a Pickle to inspect the conversation."
        }
        return "Selected session: \(selectedSessionID)"
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
