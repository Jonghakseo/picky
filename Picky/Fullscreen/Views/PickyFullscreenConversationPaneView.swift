//
//  PickyFullscreenConversationPaneView.swift
//  Picky
//
//  Center pane for fullscreen's focused LLM chat UI.
//

import SwiftUI

struct PickyFullscreenConversationPaneView: View {
    let session: PickySessionListViewModel.SessionCard?
    @ObservedObject var viewModel: PickySessionListViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                PickyFullscreenConversationListView(session: session, viewModel: viewModel)
                    .environment(\.pickyHUDDetailWidth, Self.conversationDetailWidth)
            } else {
                noSelectionView
            }
        }
        .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "Conversation")
                    .font(.system(size: 18, weight: .semibold))
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let session {
                        statusPill(for: session.status)
                        if let runText = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(for: session)?.displayText {
                            Text(runText)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Select a Pickle to inspect the conversation.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
    }

    private var noSelectionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "sidebar.left")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
            Text("Select a Pickle")
                .font(.system(size: 16, weight: .semibold))
            Text("Choose an active Pickle from the sidebar to read its LLM conversation.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private func statusPill(for status: PickySessionStatus) -> some View {
        Text(status.fullscreenConversationDisplayText)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(status.fullscreenConversationColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.fullscreenConversationColor.opacity(0.12)))
            .overlay(Capsule().stroke(status.fullscreenConversationColor.opacity(0.28), lineWidth: 0.6))
    }

    private static let conversationDetailWidth: CGFloat = 760
}

private extension PickySessionStatus {
    var fullscreenConversationDisplayText: String {
        switch self {
        case .queued: "Queued"
        case .running: "Running"
        case .waiting_for_input: "Waiting for input"
        case .blocked: "Blocked"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    var fullscreenConversationColor: Color {
        switch self {
        case .running: .blue
        case .queued: .orange
        case .waiting_for_input: .purple
        case .blocked, .failed: .red
        case .completed: .green
        case .cancelled: .gray
        }
    }
}
