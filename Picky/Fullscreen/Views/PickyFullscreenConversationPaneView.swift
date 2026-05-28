//
//  PickyFullscreenConversationPaneView.swift
//  Picky
//
//  Center pane for fullscreen's focused LLM chat UI.
//

import AppKit
import SwiftUI

struct PickyFullscreenConversationPaneView: View {
    let session: PickySessionListViewModel.SessionCard?
    @ObservedObject var viewModel: PickySessionListViewModel
    @State private var droppedFilePathsBySessionID: [String: [String]] = [:]
    @State private var isFileDropTargeted = false
    @State private var extendedTerminalOpenSessionIDs: Set<String> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let session {
                GeometryReader { proxy in
                    conversationContent(for: session)
                        .environment(\.pickyHUDDetailWidth, Self.responsiveConversationDetailWidth(forColumnWidth: proxy.size.width))
                        .onDrop(
                            of: PickyConversationFileDrop.acceptedTypeIdentifiers,
                            isTargeted: $isFileDropTargeted,
                            perform: { handleFileDrop($0, sessionID: session.id) }
                        )
                }
            } else {
                noSelectionView
            }
        }
        .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity, maxHeight: .infinity)
        .layoutPriority(1)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Conversation")
    }

    private func conversationContent(for session: PickySessionListViewModel.SessionCard) -> some View {
        VStack(spacing: 0) {
            PickyFullscreenConversationListView(session: session, viewModel: viewModel)
                .padding(.trailing, Self.conversationDividerClearance)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if isExtendedTerminalOpen(sessionID: session.id) {
                Divider()
                PickySessionExtendedTerminalView(session: session, viewModel: viewModel)
                    .transition(.opacity)
            }

            Divider()
            PickyConversationComposerView(
                session: session,
                viewModel: viewModel,
                droppedFilePaths: droppedFilePathsBinding(for: session.id),
                isFileDropTargeted: isFileDropTargeted,
                isExtendedTerminalOpen: isExtendedTerminalOpen(sessionID: session.id),
                onToggleExtendedTerminal: { toggleExtendedTerminal(sessionID: session.id) }
            )
            .id(session.id)
            .padding(.horizontal, 24)
            .padding(.vertical, 14)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func droppedFilePathsBinding(for sessionID: String) -> Binding<[String]> {
        Binding(
            get: { droppedFilePathsBySessionID[sessionID, default: []] },
            set: { paths in
                if paths.isEmpty {
                    droppedFilePathsBySessionID.removeValue(forKey: sessionID)
                } else {
                    droppedFilePathsBySessionID[sessionID] = paths
                }
            }
        )
    }

    private func handleFileDrop(_ providers: [NSItemProvider], sessionID: String) -> Bool {
        let fileProviders = providers.filter(PickyConversationFileDrop.acceptsDrop)
        guard !fileProviders.isEmpty else { return false }

        Task {
            let paths = await PickyConversationFileDrop.filePaths(from: fileProviders)
            guard !paths.isEmpty else { return }
            await MainActor.run {
                droppedFilePathsBySessionID[sessionID, default: []].append(contentsOf: paths)
            }
        }
        return true
    }

    private func isExtendedTerminalOpen(sessionID: String) -> Bool {
        extendedTerminalOpenSessionIDs.contains(sessionID)
            && !(viewModel.isInlineTerminalMode(sessionID: sessionID))
    }

    private func toggleExtendedTerminal(sessionID: String) {
        if extendedTerminalOpenSessionIDs.contains(sessionID) {
            extendedTerminalOpenSessionIDs.remove(sessionID)
        } else {
            extendedTerminalOpenSessionIDs.insert(sessionID)
            viewModel.markSessionRead(sessionID: sessionID)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session?.title ?? "Conversation")
                    .pickyFont(size: 18, weight: .semibold)
                    .lineLimit(1)
                HStack(spacing: 8) {
                    if let session {
                        statusPill(for: session.status)
                        if let runText = PickyFullscreenAssistantRunResolver.effectiveAssistantRun(for: session)?.displayText {
                            Text(runText)
                                .pickyFont(size: 12, weight: .medium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    } else {
                        Text("Select a Pickle to inspect the conversation.")
                            .pickyFont(size: 12)
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
                .pickyFont(size: 30, weight: .medium)
                .foregroundStyle(.secondary)
            Text("Select a Pickle")
                .pickyFont(size: 16, weight: .semibold)
            Text("Choose an active Pickle from the sidebar to read its LLM conversation.")
                .pickyFont(size: 13)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Select a Pickle")
        .accessibilityHint("Choose an active Pickle from the sidebar to read its LLM conversation")
    }

    private func statusPill(for status: PickySessionStatus) -> some View {
        Text(status.fullscreenConversationDisplayText)
            .pickyFont(size: 11, weight: .semibold)
            .foregroundStyle(status.fullscreenConversationColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(status.fullscreenConversationColor.opacity(0.12)))
            .overlay(Capsule().stroke(status.fullscreenConversationColor.opacity(0.28), lineWidth: 0.6))
            .accessibilityLabel("Status")
            .accessibilityValue(status.fullscreenConversationDisplayText)
    }

    static func responsiveConversationDetailWidth(forColumnWidth columnWidth: CGFloat) -> CGFloat {
        min(conversationDetailWidthMax, max(0, columnWidth - conversationDividerClearance))
    }

    static let conversationDividerClearance: CGFloat = 24
    private static let conversationDetailWidthMax: CGFloat = 760
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
